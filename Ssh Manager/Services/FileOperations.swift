import Foundation

/// File system operations that work the same way on this Mac and on remote servers.
nonisolated enum FileOperations {

    // MARK: - Listing

    /// Lists a directory. An empty `path` means the home directory.
    @concurrent
    static func list(_ location: FileLocation, path: String) async throws -> DirectoryListing {
        switch location {
        case .local: try listLocal(path)
        case .remote(let server): try await listRemote(server, path: path)
        }
    }

    private static func listLocal(_ path: String) throws -> DirectoryListing {
        let fileManager = FileManager.default
        let directory = ((path.isEmpty ? NSHomeDirectory() : path) as NSString)
            .expandingTildeInPath
        let standardized = (directory as NSString).standardizingPath
        let names = try fileManager.contentsOfDirectory(atPath: standardized)

        let entries = names.compactMap { name -> FileEntry? in
            let fullPath = join(standardized, name)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath) else { return nil }
            let isLink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory)  // follows symlinks
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return FileEntry(
                name: name,
                path: fullPath,
                isDirectory: isDirectory.boolValue,
                isSymlink: isLink,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modified: attributes[.modificationDate] as? Date,
                permissions: permissionString(mode, isDirectory: isDirectory.boolValue, isLink: isLink)
            )
        }
        return DirectoryListing(path: standardized, entries: entries)
    }

    /// Each entry is printed as `linktype|targettype|size|mtime|perms|name`, terminated by a NUL byte.
    /// NUL is the only byte that can't occur in a file name, so a name containing a newline
    /// can't inject fake entries. GNU find is used when available, otherwise a POSIX loop
    /// over `stat -c` (BusyBox, Alpine, …).
    private static func listRemote(_ server: Server, path: String) async throws -> DirectoryListing {
        let changeDirectory = path.isEmpty ? "cd" : "cd -- \(SSH.quote(path))"
        let script = """
        \(changeDirectory) || exit 3
        printf 'SSHMGR_CWD:%s\\000' "$(pwd)"
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
          find . -mindepth 1 -maxdepth 1 -printf '%y|%Y|%s|%T@|%M|%P\\0' 2>/dev/null
        else
          for f in * .[!.]* ..?*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            if [ -L "$f" ]; then l=l; else l=-; fi
            if [ -d "$f" ]; then y=d; else y=f; fi
            printf '%s|%s|%s\\000' "$l" "$y" "$(stat -c '%s|%Y|%A|%n' -- "$f" 2>/dev/null)"
          done
        fi
        exit 0
        """
        let output = try await SSH.run(server, script: script)

        // Skip anything a noisy shell profile may have printed before our marker.
        guard let markerRange = output.range(of: "SSHMGR_CWD:") else {
            throw SSHError("Unexpected response from \(server.name).")
        }
        let records = output[markerRange.upperBound...]
            .split(separator: "\0", omittingEmptySubsequences: false)
        guard let cwdRecord = records.first, !cwdRecord.isEmpty else {
            throw SSHError("Unexpected response from \(server.name).")
        }
        let cwd = String(cwdRecord)

        let entries = records.dropFirst().compactMap { record -> FileEntry? in
            let fields = record.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6 else { return nil }
            let name = String(fields[5])
            // A listed name is always a single path component; anything else would let
            // later operations (delete, rename, transfer) reach outside this directory.
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
            return FileEntry(
                name: name,
                path: join(cwd, name),
                isDirectory: fields[1] == "d",
                isSymlink: fields[0] == "l",
                size: Int64(fields[2]) ?? 0,
                modified: Double(fields[3]).map { Date(timeIntervalSince1970: $0) },
                permissions: String(fields[4])
            )
        }
        return DirectoryListing(path: cwd, entries: entries)
    }

    // MARK: - Basic operations

    @concurrent
    static func makeDirectory(named name: String, in directory: String, at location: FileLocation) async throws {
        let path = join(directory, name)
        switch location {
        case .local:
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        case .remote(let server):
            try await SSH.run(server, script: "mkdir -p -- \(SSH.quote(path))")
        }
    }

    @concurrent
    static func rename(_ entry: FileEntry, to newName: String, at location: FileLocation) async throws {
        let target = join((entry.path as NSString).deletingLastPathComponent, newName)
        switch location {
        case .local:
            try FileManager.default.moveItem(atPath: entry.path, toPath: target)
        case .remote(let server):
            try await SSH.run(server, script: "mv -- \(SSH.quote(entry.path)) \(SSH.quote(target))")
        }
    }

    /// Local items go to the Trash; remote items are removed permanently.
    @concurrent
    static func delete(_ entries: [FileEntry], at location: FileLocation) async throws {
        try await removeItems(at: entries.map(\.path), at: location)
    }

    private static func removeItems(at paths: [String], at location: FileLocation) async throws {
        switch location {
        case .local:
            for path in paths {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
        case .remote(let server):
            try await removeRemote(paths, on: server)
        }
    }

    // MARK: - Transfers

    /// Transfers items while reporting progress.
    ///
    /// `replacing` lists names in `destinationDirectory` the user agreed to overwrite; they're removed
    /// first (local items go to the Trash), so replacing works the same way in every direction
    /// instead of scp/cp merging folders and FileManager refusing to overwrite.
    ///
    /// scp prints no progress without a TTY, so progress is measured instead: the source size is
    /// computed up front, then the destination is polled while the copy runs.
    @concurrent
    static func transfer(_ entries: [FileEntry],
                         from source: FileLocation,
                         to destination: FileLocation,
                         destinationDirectory: String,
                         move: Bool,
                         replacing: [String] = [],
                         progress: ProgressReporter) async throws {
        if !replacing.isEmpty {
            let targets = replacing.map { join(destinationDirectory, $0) }
            // Removing a folder that contains one of the sources would destroy the source too.
            if source == destination,
               entries.contains(where: { entry in targets.contains { entry.path.hasPrefix($0 + "/") } }) {
                throw SSHError("Can't replace a folder with an item that's inside it.")
            }
            try await removeItems(at: targets, at: destination)
        }

        // A move on the same machine is a rename and finishes instantly.
        if move && source == destination {
            try await transfer(entries, from: source, to: destination,
                               destinationDirectory: destinationDirectory, move: true)
            return
        }

        let total = try? await totalSize(of: entries.map(\.path), at: source)
        progress(0, of: total)

        let targets = entries.map { join(destinationDirectory, $0.name) }
        let baseline = (try? await totalSize(of: targets, at: destination)) ?? 0
        let pollInterval: Duration = destination.isLocal ? .milliseconds(500) : .seconds(1)

        let monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { break }
                if let size = try? await totalSize(of: targets, at: destination) {
                    progress(max(0, size - baseline), of: total)
                }
            }
        }
        defer { monitor.cancel() }

        try await transfer(entries, from: source, to: destination,
                           destinationDirectory: destinationDirectory, move: move)
        if let total { progress(total, of: total) }
    }

    /// Total size in bytes of the regular files under `paths` (missing paths count as 0).
    @concurrent
    static func totalSize(of paths: [String], at location: FileLocation) async throws -> Int64 {
        switch location {
        case .local:
            return paths.reduce(0) { $0 + localSize(of: $1) }
        case .remote(let server):
            guard !paths.isEmpty else { return 0 }
            let quoted = paths.map(SSH.quote).joined(separator: " ")
            let script = """
            if find / -maxdepth 0 -printf '' >/dev/null 2>&1; then
              find \(quoted) -type f -printf '%s\\n' 2>/dev/null
            else
              find \(quoted) -type f -exec stat -c %s {} + 2>/dev/null
            fi | awk '{ s += $1 } END { printf "%.0f\\n", s }'
            """
            let output = try await SSH.run(server, script: script)
            return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
    }

    private static func localSize(of path: String) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }

        guard isDirectory.boolValue else {
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path),
                                                      includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Copies or moves items into `destinationDirectory`.
    /// Server ↔ server transfers between different hosts are relayed through this Mac (`scp -3`).
    @concurrent
    static func transfer(_ entries: [FileEntry],
                         from source: FileLocation,
                         to destination: FileLocation,
                         destinationDirectory: String,
                         move: Bool) async throws {
        let paths = entries.map(\.path)
        let targetDirectory = destinationDirectory.hasSuffix("/") ? destinationDirectory : destinationDirectory + "/"

        switch (source, destination) {
        case (.local, .local):
            let fileManager = FileManager.default
            for entry in entries {
                try Task.checkCancellation()
                let target = join(destinationDirectory, entry.name)
                if move {
                    try fileManager.moveItem(atPath: entry.path, toPath: target)
                } else {
                    try fileManager.copyItem(atPath: entry.path, toPath: target)
                }
            }

        case let (.remote(from), .remote(to)) where from.id == to.id:
            let command = move ? "mv" : "cp -R"
            let sources = paths.map(SSH.quote).joined(separator: " ")
            try await SSH.run(from, script: "\(command) -- \(sources) \(SSH.quote(targetDirectory))")

        case let (.local, .remote(to)):
            try await SSH.connect(to)
            try await SSH.scp(paths + ["\(to.alias):\(targetDirectory)"], using: to)
            // Trash rather than delete the originals, so they can be recovered if the upload was incomplete.
            if move { try await removeItems(at: paths, at: .local) }

        case let (.remote(from), .local):
            try await SSH.connect(from)
            try await SSH.scp(paths.map { "\(from.alias):\($0)" } + [targetDirectory], using: from)
            if move { try await removeRemote(paths, on: from) }

        case let (.remote(from), .remote(to)):
            // Authenticate both ends first; scp then reuses the multiplexed connections.
            try await SSH.connect(from)
            try await SSH.connect(to)
            try await SSH.scp(["-3"] + paths.map { "\(from.alias):\($0)" } + ["\(to.alias):\(targetDirectory)"],
                              using: to)
            if move { try await removeRemote(paths, on: from) }
        }
    }

    // MARK: - Helpers

    private static func removeRemote(_ paths: [String], on server: Server) async throws {
        guard !paths.isEmpty else { return }
        try await SSH.run(server, script: "rm -rf -- " + paths.map(SSH.quote).joined(separator: " "))
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    static func permissionString(_ mode: Int, isDirectory: Bool, isLink: Bool) -> String {
        let symbols: [Character] = ["r", "w", "x"]
        var result = isLink ? "l" : (isDirectory ? "d" : "-")
        for bit in stride(from: 8, through: 0, by: -1) {
            result.append(mode & (1 << bit) != 0 ? symbols[(8 - bit) % 3] : "-")
        }
        return result
    }
}
