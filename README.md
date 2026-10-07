# SSH Manager

A small, native macOS app for managing SSH servers, tunnels and files. No account, no subscription, no cloud sync.

## Why

I wanted a simple place to keep my servers and credentials organized, start tunnels, and move files around quickly. The existing tools are either bloated, need an account, or require a subscription. SSH Manager is a thin layer over the `ssh` and `scp` that already ship with macOS: it does those few things and stays out of the way.

## Features

### Servers
- Save servers with a name, group, host, port, username and notes.
- Sign in with a password, a private key (with optional passphrase), or your SSH agent / default keys.
- The sidebar groups servers and has a search field. Double-click a server to connect, or right-click to connect, browse files, edit, duplicate or delete it.
- **Test** a connection, or copy the matching `ssh` command to the clipboard.

### Terminal
- Built-in terminal (powered by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) with several sessions at once, including more than one to the same server.
- Sessions keep running in the background, and you can reconnect with one click when a session ends.
- Prefer your own terminal? Sessions can open in **Terminal.app** or **iTerm2** instead (see Settings).

### Tunnels
- **Local port forwards** (`-L`) and **SOCKS5 proxies** (`-D`).
- Switch tunnels on and off, see their status at a glance, and have them start when the app opens.
- "Open in Browser" for forwarded ports. Tunnels stop cleanly when you quit the app.

### File manager
- Two panes side by side. Each pane shows **This Mac** or any saved server, so you can copy local ↔ remote and server ↔ server.
- Drag and drop between the panes, or use Copy / Move to the other pane.
- Rename, new folder, delete (local files go to the Trash), and show hidden files.
- Transfer queue with progress, speed, time remaining and cancel.

## Security

- Passwords and key passphrases are stored in the **macOS Keychain**, never in plain files.
- Server and tunnel settings live in `~/Library/Application Support/SSHManager/`.
- Connections use the system OpenSSH with its usual host-key checks, against your `~/.ssh/known_hosts`.
- After the first login, the app reuses that connection, so browsing files doesn't ask for your password again.

## Requirements

- macOS 27 or later
- Xcode 27 to build
- Remote servers need a POSIX `sh` (any normal Linux or BSD box, including BusyBox/Alpine)

## Building

1. Open `Ssh Manager.xcodeproj` in Xcode.
2. Let Swift Package Manager fetch SwiftTerm.
3. Build and run the **Ssh Manager** scheme.

The app runs outside the App Sandbox because it starts `/usr/bin/ssh` and `/usr/bin/scp` directly.
