import Foundation

private let home = FileManager.default.homeDirectoryForCurrentUser

let appSupportDir = home
    .appendingPathComponent("Library/Application Support/com.ksterx.MenubarCC")
private let appSettingsPath = appSupportDir.appendingPathComponent("settings.json")
private let hookConfigPath = appSupportDir.appendingPathComponent("hook-config.json")
let appSoundsDir = appSupportDir.appendingPathComponent("sounds")

private let hookScriptInstall = home
    .appendingPathComponent(".claude/hooks/scripts/menubarcc_hook.py")
private let claudeSettingsPath = home
    .appendingPathComponent(".claude/settings.json")

private let hookCommandMarker = "menubarcc_hook.py"

let controlledHookEvents: [(event: String, label: String)] = [
    ("Stop", "Stop (response end)"),
    ("Notification", "Notification"),
    ("PermissionRequest", "Permission Request"),
]

private let installedHookEvents: [String] =
    controlledHookEvents.map(\.event) + ["UserPromptSubmit", "SessionEnd"]

// MARK: - JSON I/O

func readJSON(_ path: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: path),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return dict
}

func writeJSONAtomic(_ path: URL, _ dict: [String: Any]) {
    let dir = path.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(
        withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
    ) else { return }
    try? data.write(to: path, options: .atomic)
}

// MARK: - App Settings

func loadAppSettings() -> [String: Any] { readJSON(appSettingsPath) }
func saveAppSettings(_ cfg: [String: Any]) { writeJSONAtomic(appSettingsPath, cfg) }

// MARK: - Hook Config (shared with menubarcc_hook.py)

func loadHookConfig() -> [String: Any] { readJSON(hookConfigPath) }
func saveHookConfig(_ cfg: [String: Any]) { writeJSONAtomic(hookConfigPath, cfg) }

func updateHookConfig(_ changes: [String: Any]) {
    var cfg = loadHookConfig()
    for (k, v) in changes { cfg[k] = v }
    saveHookConfig(cfg)
}

func isEventEnabled(_ cfg: [String: Any], event: String) -> Bool {
    guard let perEvent = cfg["perEventEnabled"] as? [String: Any] else { return true }
    return perEvent[event] as? Bool ?? true
}

// MARK: - Sound file management

func copySoundIntoAppSupport(src: String, eventName: String) -> String? {
    let srcURL = URL(fileURLWithPath: src)
    let ext = srcURL.pathExtension
    let dest = appSoundsDir.appendingPathComponent("\(eventName).\(ext)")
    let fm = FileManager.default
    try? fm.createDirectory(at: appSoundsDir, withIntermediateDirectories: true)
    try? fm.removeItem(at: dest)
    do {
        try fm.copyItem(at: srcURL, to: dest)
        return dest.path
    } catch {
        return nil
    }
}

// MARK: - Hook Install / Uninstall

private func hookCommand() -> String {
    "python3 \"\(hookScriptInstall.path)\""
}

private func hookScriptSource() -> URL {
    if let rp = Bundle.main.resourcePath {
        return URL(fileURLWithPath: rp).appendingPathComponent("menubarcc_hook.py")
    }
    return URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("menubarcc_hook.py")
}

private func sectionHasMenubarCC(_ section: [[String: Any]]) -> Bool {
    for entry in section {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { continue }
        for hook in hooks {
            if let cmd = hook["command"] as? String, cmd.contains(hookCommandMarker) {
                return true
            }
        }
    }
    return false
}

func hooksAreInstalled() -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: hookScriptInstall.path) else { return false }
    let settings = readJSON(claudeSettingsPath)
    guard let hooks = settings["hooks"] as? [String: Any] else { return false }
    for event in installedHookEvents {
        guard let section = hooks[event] as? [[String: Any]],
              sectionHasMenubarCC(section) else {
            return false
        }
    }
    return true
}

func installHooks() -> (ok: Bool, message: String) {
    let src = hookScriptSource()
    let fm = FileManager.default
    guard fm.fileExists(atPath: src.path) else {
        return (false, "Bundled hook script not found at \(src.path)")
    }

    do {
        try fm.createDirectory(
            at: hookScriptInstall.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.removeItem(at: hookScriptInstall)
        try fm.copyItem(at: src, to: hookScriptInstall)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookScriptInstall.path
        )
    } catch {
        return (false, "Failed to copy hook script: \(error.localizedDescription)")
    }

    let backup = backupClaudeSettings()
    var settings = readJSON(claudeSettingsPath)
    var hooksRoot = settings["hooks"] as? [String: Any] ?? [:]
    let cmd = hookCommand()

    for event in installedHookEvents {
        var section = hooksRoot[event] as? [[String: Any]] ?? []
        if !sectionHasMenubarCC(section) {
            let entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": cmd,
                    "timeout": 5000,
                    "async": true,
                ] as [String: Any]]
            ]
            section.append(entry)
        }
        hooksRoot[event] = section
    }

    settings["hooks"] = hooksRoot
    writeJSONAtomic(claudeSettingsPath, settings)

    var msg = "Hooks installed."
    if let b = backup { msg += " Previous settings backed up to \(b)." }
    return (true, msg)
}

func uninstallHooks() -> (ok: Bool, message: String) {
    let backup = backupClaudeSettings()
    var settings = readJSON(claudeSettingsPath)

    if var hooksRoot = settings["hooks"] as? [String: Any] {
        for event in installedHookEvents {
            guard var section = hooksRoot[event] as? [[String: Any]] else { continue }
            section.removeAll { entry in
                guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
                return hooks.contains { ($0["command"] as? String ?? "").contains(hookCommandMarker) }
            }
            if section.isEmpty {
                hooksRoot.removeValue(forKey: event)
            } else {
                hooksRoot[event] = section
            }
        }
        settings["hooks"] = hooksRoot.isEmpty ? nil : hooksRoot
    }

    writeJSONAtomic(claudeSettingsPath, settings)
    try? FileManager.default.removeItem(at: hookScriptInstall)

    var msg = "Hooks uninstalled."
    if let b = backup { msg += " Previous settings backed up to \(b)." }
    return (true, msg)
}

private func backupClaudeSettings() -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: claudeSettingsPath.path) else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    let backupName = "settings.json.backup-\(stamp)"
    let backup = claudeSettingsPath.deletingLastPathComponent()
        .appendingPathComponent(backupName)
    do {
        try fm.copyItem(at: claudeSettingsPath, to: backup)
        return backupName
    } catch {
        return nil
    }
}
