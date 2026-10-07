import Foundation
import Observation

/// Tracks running and finished file transfers.
@Observable
final class TransferCenter {
    enum State: Equatable {
        case running
        case succeeded
        case failed(String)
        case cancelled
    }

    struct Job: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        var state: State = .running
        var totalBytes: Int64?
        var transferredBytes: Int64 = 0
        var bytesPerSecond: Double = 0

        var fractionCompleted: Double? {
            guard let totalBytes, totalBytes > 0 else { return nil }
            return min(1, Double(transferredBytes) / Double(totalBytes))
        }

        var secondsRemaining: Double? {
            guard let totalBytes, bytesPerSecond > 0 else { return nil }
            return Double(max(0, totalBytes - transferredBytes)) / bytesPerSecond
        }
    }

    private(set) var jobs: [Job] = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastSamples: [UUID: (date: Date, bytes: Int64)] = [:]

    var hasFinishedJobs: Bool { jobs.contains { $0.state != .running } }

    func start(title: String,
               detail: String,
               operation: @escaping @Sendable (ProgressReporter) async throws -> Void,
               completion: @escaping () -> Void) {
        let job = Job(title: title, detail: detail)
        jobs.insert(job, at: 0)
        let id = job.id

        let reporter = ProgressReporter { [weak self] transferred, total in
            Task { @MainActor [weak self] in
                self?.updateProgress(id, transferred: transferred, total: total)
            }
        }

        tasks[id] = Task {
            do {
                try await operation(reporter)
                update(id, to: .succeeded)
            } catch {
                update(id, to: Task.isCancelled || error is CancellationError
                       ? .cancelled : .failed(error.localizedDescription))
            }
            tasks[id] = nil
            lastSamples[id] = nil
            completion()
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func clearFinished() {
        jobs.removeAll { $0.state != .running }
    }

    private func update(_ id: UUID, to state: State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        if state == .succeeded, let total = jobs[index].totalBytes {
            jobs[index].transferredBytes = total
        }
    }

    private func updateProgress(_ id: UUID, transferred: Int64, total: Int64?) {
        // Ignore late samples that arrive after the job finished.
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].totalBytes = total
        jobs[index].transferredBytes = transferred

        // Smoothed transfer speed (exponential moving average).
        let now = Date()
        if let last = lastSamples[id] {
            let elapsed = now.timeIntervalSince(last.date)
            if elapsed > 0.2 {
                let instant = Double(max(0, transferred - last.bytes)) / elapsed
                let previous = jobs[index].bytesPerSecond
                jobs[index].bytesPerSecond = previous == 0 ? instant : previous * 0.7 + instant * 0.3
                lastSamples[id] = (now, transferred)
            }
        } else {
            lastSamples[id] = (now, transferred)
        }
    }
}
