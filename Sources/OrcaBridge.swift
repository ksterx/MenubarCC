import Cocoa

// Orca IDE integration: clicking a session can bring its Orca terminal tab to
// the foreground. Optional — everything is resolved at runtime so non-Orca
// users are unaffected (the app falls back to Finder/clipboard per the
// "On Session Click" setting).

private let orcaBundleId = "com.stablyai.orca"
// The CLI ships inside the app bundle; the /usr/local/bin shim is optional and
// not present on every machine, so we locate the app itself as the primary path.
private let orcaCLIRelPath = "Contents/Resources/bin/orca"

private let orcaSymlinkPaths = [
    "/usr/local/bin/orca",
    "/opt/homebrew/bin/orca",
]

func orcaBinaryPath() -> String? {
    let fm = FileManager.default

    // 1. The CLI shim, if the user happens to have installed it.
    if let p = orcaSymlinkPaths.first(where: { fm.isExecutableFile(atPath: $0) }) {
        return p
    }
    // 2. Ask LaunchServices where Orca.app lives, then use its bundled CLI —
    //    works wherever Orca is installed, with or without the shim.
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: orcaBundleId) {
        let cli = appURL.appendingPathComponent(orcaCLIRelPath).path
        if fm.isExecutableFile(atPath: cli) { return cli }
    }
    // 3. Standard install locations as a last resort.
    let home = fm.homeDirectoryForCurrentUser.path
    for base in ["/Applications/Orca.app", "\(home)/Applications/Orca.app"] {
        let cli = "\(base)/\(orcaCLIRelPath)"
        if fm.isExecutableFile(atPath: cli) { return cli }
    }
    return nil
}

func orcaAvailable() -> Bool { orcaBinaryPath() != nil }

/// Bring the Orca terminal whose worktree owns `cwd` to the foreground.
/// Returns false when Orca isn't available or no terminal matches, so the
/// caller can fall back. Runs `orca` subprocesses — call off the main thread.
func orcaSwitchToTerminal(forCwd cwd: String) -> Bool {
    guard orcaAvailable(), let handle = orcaTerminalHandle(forCwd: cwd) else {
        return false
    }
    // If the handle went stale or Orca exited since the list, switch fails —
    // return false so the caller can fall back instead of activating nothing.
    guard runOrca(["terminal", "switch", "--terminal", handle]) != nil else {
        return false
    }
    activateOrca()
    return true
}

/// Runs `orca` and returns its stdout, or nil if it fails to launch or exits
/// non-zero.
private func runOrca(_ args: [String]) -> Data? {
    guard let bin = orcaBinaryPath() else { return nil }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: bin)
    proc.arguments = args
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    return data
}

private func orcaTerminalHandle(forCwd cwd: String) -> String? {
    guard let data = runOrca(["terminal", "list", "--json"]),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = root["result"] as? [String: Any],
          let terminals = result["terminals"] as? [[String: Any]] else {
        return nil
    }

    let target = URL(fileURLWithPath: cwd).standardizedFileURL.path
    var best: (handle: String, depth: Int, lastOutput: Double)?

    for t in terminals {
        guard let handle = t["handle"] as? String,
              let wt = t["worktreePath"] as? String, !wt.isEmpty else { continue }
        let wtPath = URL(fileURLWithPath: wt).standardizedFileURL.path
        // The session's cwd must be the worktree root or live inside it.
        guard target == wtPath || target.hasPrefix(wtPath + "/") else { continue }
        let last = t["lastOutputAt"] as? Double ?? 0
        // Prefer the deepest matching worktree, then the most recently active.
        if best == nil || wtPath.count > best!.depth
            || (wtPath.count == best!.depth && last > best!.lastOutput) {
            best = (handle, wtPath.count, last)
        }
    }
    return best?.handle
}

/// `terminal switch` selects the tab; make sure Orca's window comes forward too.
private func activateOrca() {
    guard let app = orcaAppURL() else { return }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    DispatchQueue.main.async {
        NSWorkspace.shared.openApplication(at: app, configuration: cfg, completionHandler: nil)
    }
}

private func orcaAppURL() -> URL? {
    // Ask LaunchServices directly — robust regardless of where Orca is installed.
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: orcaBundleId) {
        return url
    }
    // Fallback: derive the .app from the CLI path (resolving the shim symlink).
    guard let bin = orcaBinaryPath() else { return nil }
    let fm = FileManager.default
    var resolvedPath = bin
    if let dest = try? fm.destinationOfSymbolicLink(atPath: bin) {
        resolvedPath = dest.hasPrefix("/")
            ? dest
            : URL(fileURLWithPath: bin).deletingLastPathComponent()
                .appendingPathComponent(dest).standardizedFileURL.path
    }
    var url = URL(fileURLWithPath: resolvedPath)
    while url.pathExtension != "app" && url.path != "/" {
        url = url.deletingLastPathComponent()
    }
    return url.pathExtension == "app" ? url : nil
}
