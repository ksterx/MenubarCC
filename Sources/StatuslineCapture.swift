import Foundation

// Wires the statusline tap into Claude Code so MenubarCC can show usage limits
// and exact context for any user, without them hand-editing their statusline.
//
// The tap sits in front of the user's real statusline as a pass-through pipe:
//     ( tap 2>/dev/null || cat ) | ( original )
// so the original renders unchanged while the tap spools the numbers. Editing
// ~/.claude/settings.json is transactional: the helper is staged and
// self-tested before it replaces a working one; settings edits distinguish
// "absent" from "unreadable", require a durable backup and recovery journal
// before any change, re-read to catch a concurrent writer against the exact
// bytes just parsed, write atomically, and verify the read-back. Uninstall
// restores from the journal under the same guards.
//
// v1 touches user-level settings only; project/managed statusline overrides
// bypass it by design.

private let scHome = FileManager.default.homeDirectoryForCurrentUser
private let claudeSettings = scHome.appendingPathComponent(".claude/settings.json")

private let tapInstallDir = scHome.appendingPathComponent(".claude/menubarcc")
private let tapInstallPath = tapInstallDir.appendingPathComponent("statusline-tap")
private let journalPath = appSupportDir.appendingPathComponent("statusline-install.json")

// Present in our installed command; a coarse hint only. Ownership is proven by
// the journal plus an exact command match, never by this substring alone.
private let tapMarker = ".claude/menubarcc/statusline-tap"
private let tapShell = "$HOME/.claude/menubarcc/statusline-tap"

// MARK: - Installed command shapes

// A trailing newline before the closing ")" keeps a comment in the original
// command from swallowing the wrapper syntax.
private func wrappedCommand(original: String) -> String {
    """
    ( if [ -x "\(tapShell)" ]; then "\(tapShell)" 2>/dev/null; else /bin/cat; fi ) | (
    \(original)
    )
    """
}

private func captureOnlyCommand() -> String {
    """
    if [ -x "\(tapShell)" ]; then "\(tapShell)" --capture-only 2>/dev/null; else /bin/cat >/dev/null; fi
    """
}

// MARK: - Settings read (absent vs invalid/unreadable vs ok)

private enum SettingsRead {
    case absent                       // confirmed nonexistent
    case invalid                      // exists but unreadable or not a JSON object
    case ok([String: Any], Data)      // parsed dict + the exact bytes it came from
}

// Distinguishes a missing file from one that exists but can't be read/parsed —
// treating an I/O error as "absent" would let us overwrite real settings.
private func readClaudeSettings() -> SettingsRead {
    let target = resolvedSettingsPath()
    guard FileManager.default.fileExists(atPath: target.path) else { return .absent }
    guard let data = try? Data(contentsOf: target) else { return .invalid }
    guard let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else { return .invalid }
    return .ok(dict, data)
}

// Follow the full symlink chain (with cycle protection) so an atomic write
// replaces the real target, not a link in the chain.
private func resolvedSettingsPath() -> URL {
    let fm = FileManager.default
    var url = claudeSettings
    var seen: Set<String> = []
    for _ in 0..<40 {
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: url.path) else { break }
        let next = (dest as NSString).isAbsolutePath
            ? URL(fileURLWithPath: dest)
            : url.deletingLastPathComponent().appendingPathComponent(dest)
        let std = next.standardizedFileURL
        if seen.contains(std.path) { break }  // cycle
        seen.insert(std.path)
        url = std
    }
    return url
}

// Write via a same-directory temp + rename (atomic, keeps any symlink intact),
// preserving the original file mode. A failed chmod fails the whole write.
private func writeSettingsAtomic(_ dict: [String: Any]) -> Bool {
    let fm = FileManager.default
    let target = resolvedSettingsPath()
    guard let data = try? JSONSerialization.data(
        withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return false }
    let dir = target.deletingLastPathComponent()
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let mode = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        ?? NSNumber(value: 0o644)
    let tmp = dir.appendingPathComponent(".menubarcc-settings.\(getpid()).tmp")
    try? fm.removeItem(at: tmp)
    do {
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        if rename(tmp.path, target.path) != 0 {
            try? fm.removeItem(at: tmp)
            return false
        }
        return true
    } catch {
        try? fm.removeItem(at: tmp)
        return false
    }
}

private func backupSettings() -> String? {
    let fm = FileManager.default
    let target = resolvedSettingsPath()
    guard fm.fileExists(atPath: target.path) else { return nil }
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd-HHmmss"
    let name = "settings.json.backup-\(df.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    let dest = target.deletingLastPathComponent().appendingPathComponent(name)
    return (try? fm.copyItem(at: target, to: dest)) != nil ? name : nil
}

// MARK: - Install journal (durable recovery record)

private func writeJournalVerified(_ j: [String: Any]) -> Bool {
    writeJSONAtomic(journalPath, j)
    guard let back = readJournal(),
          back["installId"] as? String == j["installId"] as? String,
          back["state"] as? String == j["state"] as? String else { return false }
    return true
}

private func readJournal() -> [String: Any]? {
    let d = readJSON(journalPath)
    return d.isEmpty ? nil : d
}

// MARK: - Helper binary

private func bundledTap() -> URL {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let rp = Bundle.main.resourcePath {
        candidates.append(URL(fileURLWithPath: rp).deletingLastPathComponent()
            .appendingPathComponent("Helpers/statusline-tap"))
    }
    let argvDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    candidates.append(argvDir.appendingPathComponent("statusline-tap"))
    candidates.append(argvDir.deletingLastPathComponent().appendingPathComponent("Helpers/statusline-tap"))
    return candidates.first { fm.fileExists(atPath: $0.path) } ?? candidates[0]
}

/// Copy the bundled helper to a staging path, self-test THAT candidate, then
/// atomically rename it into place. The working helper is never removed before
/// its replacement proves out, so a bad update can't break the statusline.
private func installTapHelperStaged() -> Bool {
    let fm = FileManager.default
    let src = bundledTap()
    guard fm.fileExists(atPath: src.path) else { return false }
    try? fm.createDirectory(at: tapInstallDir, withIntermediateDirectories: true)
    let staging = tapInstallDir.appendingPathComponent("statusline-tap.\(getpid()).staging")
    try? fm.removeItem(at: staging)
    do {
        try fm.copyItem(at: src, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
    } catch {
        try? fm.removeItem(at: staging)
        return false
    }
    guard selfTestTap(staging) else { try? fm.removeItem(at: staging); return false }
    if rename(staging.path, tapInstallPath.path) != 0 {
        try? fm.removeItem(at: staging)
        return false
    }
    return true
}

/// Run the given helper on a sample payload and confirm it forwards stdin
/// verbatim and exits 0. Bounded by a deadline so a hung helper can't freeze
/// the caller.
private func selfTestTap(_ binary: URL) -> Bool {
    let p = Process()
    p.executableURL = binary
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = FileHandle.nullDevice
    let sid = "selftest-\(UUID().uuidString)"
    let sample = Data("{\"session_id\":\"\(sid)\",\"context_window\":{\"used_percentage\":1}}".utf8)
    do { try p.run() } catch { return false }
    inPipe.fileHandleForWriting.write(sample)
    try? inPipe.fileHandleForWriting.close()

    var out = Data()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        out = outPipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    let finished = done.wait(timeout: .now() + 3) == .success
    if !finished {
        p.terminate()
        _ = done.wait(timeout: .now() + 1)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
    p.waitUntilExit()
    try? FileManager.default.removeItem(
        at: scHome.appendingPathComponent(".claude/statusline-usage/\(sid).json"))
    return finished && p.terminationStatus == 0 && out == sample
}

private func removeHelperAndJournal() {
    let fm = FileManager.default
    try? fm.removeItem(at: tapInstallPath)
    if let contents = try? fm.contentsOfDirectory(atPath: tapInstallDir.path), contents.isEmpty {
        try? fm.removeItem(at: tapInstallDir)
    }
    try? fm.removeItem(at: journalPath)
}

private func dictEqual(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return NSDictionary(dictionary: x).isEqual(to: y)
    default: return false
    }
}

// MARK: - Public API

/// Ownership is the journal saying "installed" AND the live command matching
/// the exact command we recorded — never a bare substring match.
func usageCaptureInstalled() -> Bool {
    guard FileManager.default.fileExists(atPath: tapInstallPath.path) else { return false }
    guard let j = readJournal(), j["state"] as? String == "installed",
          let installedCmd = j["installedCommand"] as? String else { return false }
    guard case .ok(let settings, _) = readClaudeSettings(),
          let sl = settings["statusLine"] as? [String: Any],
          sl["command"] as? String == installedCmd else { return false }
    return true
}

/// Keep the installed helper current with the bundled one across app updates —
/// staged and self-tested first, so a bad build never replaces a good helper.
func syncStatuslineTap() {
    guard usageCaptureInstalled(),
          let bundled = try? Data(contentsOf: bundledTap()),
          let installed = try? Data(contentsOf: tapInstallPath),
          bundled != installed else { return }
    _ = installTapHelperStaged()
}

func installUsageCapture() -> (ok: Bool, message: String) {
    if usageCaptureInstalled() { return (true, "Usage capture is already enabled.") }

    // 1. Stage + self-test + swap in the helper. On any failure the previously
    //    working helper is left untouched.
    guard installTapHelperStaged() else {
        return (false, "The capture helper could not be installed or failed its self-test.")
    }

    // 2. Read settings; refuse invalid/unreadable, allow truly absent.
    var settings: [String: Any]
    let originalBytes: Data?
    let filePresent: Bool
    switch readClaudeSettings() {
    case .invalid:
        return (false, "~/.claude/settings.json isn't valid JSON or can't be read. Fix it first, then try again.")
    case .absent:
        settings = [:]; originalBytes = nil; filePresent = false
    case .ok(let dict, let bytes):
        settings = dict; originalBytes = bytes; filePresent = true
    }

    // 3. Inspect any existing statusLine.
    let existing = settings["statusLine"]
    let newStatusLine: [String: Any]
    let installedCommand: String
    let hadStatusLine: Bool
    var originalCommand: String?

    if let sl = existing as? [String: Any] {
        if let cmd = sl["command"] as? String, cmd.contains(tapMarker) {
            return (false, "Your statusline already looks wrapped. Disable usage capture first, then re-enable.")
        }
        guard (sl["type"] as? String) == "command", let cmd = sl["command"] as? String else {
            return (false, "Your statusline uses a form MenubarCC can't wrap safely — left unchanged.")
        }
        hadStatusLine = true
        originalCommand = cmd
        installedCommand = wrappedCommand(original: cmd)
        var s = sl
        s["command"] = installedCommand
        newStatusLine = s
    } else if existing != nil {
        return (false, "Your statusline setting has an unexpected shape — left unchanged.")
    } else {
        hadStatusLine = false
        installedCommand = captureOnlyCommand()
        newStatusLine = ["type": "command", "command": installedCommand]
    }

    // 4. A durable backup is required whenever there's a file to restore.
    var backupName: String?
    if filePresent {
        guard let b = backupSettings() else {
            return (false, "Could not back up ~/.claude/settings.json — left unchanged.")
        }
        backupName = b
    }

    // 5. Durable recovery journal BEFORE any settings change.
    let installId = UUID().uuidString
    guard writeJournalVerified([
        "schemaVersion": 1,
        "installId": installId,
        "hadStatusLine": hadStatusLine,
        "originalStatusLine": existing ?? NSNull(),
        "originalCommand": originalCommand ?? NSNull(),
        "installedStatusLine": newStatusLine,
        "installedCommand": installedCommand,
        "state": "pending",
    ]) else {
        return (false, "Could not record recovery state — left settings unchanged.")
    }

    // 6. Concurrency guard: the bytes must be exactly what we parsed in step 2.
    let now = try? Data(contentsOf: resolvedSettingsPath())
    if now != originalBytes {
        return (false, "Settings changed while enabling capture. Please try again.")
    }

    // 7. Write, then verify the read-back is exactly our command.
    settings["statusLine"] = newStatusLine
    guard writeSettingsAtomic(settings) else {
        return (false, "Could not write ~/.claude/settings.json.")
    }
    guard case .ok(let verify, _) = readClaudeSettings(),
          let vsl = verify["statusLine"] as? [String: Any],
          vsl["command"] as? String == installedCommand else {
        return (false, "The settings change could not be verified.")
    }

    // 8. Mark installed.
    _ = writeJournalVerified([
        "schemaVersion": 1,
        "installId": installId,
        "hadStatusLine": hadStatusLine,
        "originalStatusLine": existing ?? NSNull(),
        "originalCommand": originalCommand ?? NSNull(),
        "installedStatusLine": newStatusLine,
        "installedCommand": installedCommand,
        "state": "installed",
    ])

    var msg = "Usage capture enabled — the menu will show 5-hour and weekly limits. " +
        "Sessions already open may need a restart to pick it up."
    if let b = backupName { msg += " Settings backed up to \(b)." }
    return (true, msg)
}

func uninstallUsageCapture() -> (ok: Bool, message: String) {
    switch readClaudeSettings() {
    case .invalid:
        return (false, "~/.claude/settings.json isn't valid JSON or can't be read — left unchanged.")
    case .absent:
        removeHelperAndJournal()
        return (true, "Usage capture disabled.")
    case .ok(var settings, let originalBytes):
        let journal = readJournal()
        let sl = settings["statusLine"] as? [String: Any]
        let currentCmd = sl?["command"] as? String
        let installedCmd = journal?["installedCommand"] as? String
        let isOurs = installedCmd != nil && currentCmd == installedCmd

        // Command carries our marker but isn't our exact recorded command — it
        // was edited after enabling. Don't guess; leave everything as the user
        // has it (the tap's /bin/cat fallback keeps the statusline working).
        if !isOurs, currentCmd?.contains(tapMarker) == true {
            return (false, "Your statusline changed since it was enabled — MenubarCC left it as-is. "
                + "Edit ~/.claude/settings.json to remove the wrapper if you want it gone.")
        }

        if isOurs {
            if (journal?["hadStatusLine"] as? Bool) == true {
                // Restore the original command in place, preserving any other
                // statusLine fields the user changed since.
                if let orig = journal?["originalCommand"] as? String, var s = sl {
                    s["command"] = orig
                    settings["statusLine"] = s
                } else {
                    settings["statusLine"] = journal?["originalStatusLine"]
                }
            } else {
                // Originally no statusLine. Remove it only if it still matches
                // exactly what we installed; otherwise the user added fields —
                // drop just our command and keep the rest.
                if dictEqual(sl, journal?["installedStatusLine"] as? [String: Any]) {
                    settings.removeValue(forKey: "statusLine")
                } else if var s = sl {
                    s.removeValue(forKey: "command")
                    if s.isEmpty { settings.removeValue(forKey: "statusLine") }
                    else { settings["statusLine"] = s }
                }
            }

            _ = backupSettings()
            // Concurrency guard against a write since our read.
            let now = try? Data(contentsOf: resolvedSettingsPath())
            if now != originalBytes {
                return (false, "Settings changed while disabling capture. Please try again.")
            }
            guard writeSettingsAtomic(settings) else {
                return (false, "Could not write ~/.claude/settings.json.")
            }
            // Verify our command is gone before removing recovery data.
            guard case .ok(let verify, _) = readClaudeSettings() else {
                return (false, "The settings change could not be verified.")
            }
            let vcmd = (verify["statusLine"] as? [String: Any])?["command"] as? String
            if vcmd == installedCmd {
                return (false, "The settings change could not be verified.")
            }
        }

        removeHelperAndJournal()
        let msg = isOurs
            ? "Usage capture disabled and your statusline restored."
            : "Usage capture disabled. Your current statusline was left unchanged."
        return (true, msg)
    }
}
