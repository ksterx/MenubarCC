import Foundation

struct SessionInfo {
    let sessionId: String
    let status: String
    let cwd: String
    let dirName: String
    let ageSeconds: Double
    let isStuck: Bool
    let isWaiting: Bool
    let updatedAt: Double
    // Context-window fill (0–100), read from the session transcript. Only
    // populated when loadSessions is asked for it (menu open), since the tail
    // read is too costly to run on every background poll. nil = unknown.
    let contextPct: Double?
}

enum AnimState {
    case idle, walk, bounce, pulse
}

private let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/sessions")

private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects")

// Context-window sizes used as the denominator for the transcript-based fill
// estimate. A single request can't exceed the window, so a turn over 200K must
// be a 1M-context session; otherwise assume the standard 200K.
private let stdContextWindow = 200_000.0
private let bigContextWindow = 1_000_000.0

// A session whose owning process is gone is a zombie (Claude crashed without a
// clean SessionEnd). Age is only a fallback for sessions that carry no pid.
private let maxSessionAge: TimeInterval = 12 * 3600

func loadSessions(stuckSecs: Int, stuckEnabled: Bool,
                  includeContext: Bool = false) -> [SessionInfo] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return [] }

    let nowMs = Date().timeIntervalSince1970 * 1000
    let cutoffMs = nowMs - maxSessionAge * 1000
    var results: [SessionInfo] = []
    var referencedSids: Set<String> = []
    var parseFailed = false

    for file in files where file.hasSuffix(".json") {
        let path = sessionsDir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            parseFailed = true
            continue
        }

        let sid = dict["sessionId"] as? String ?? ""
        let status = dict["status"] as? String ?? ""
        let cwd = dict["cwd"] as? String ?? "?"
        let updatedAt = dict["updatedAt"] as? Double ?? 0
        let statusUpdatedAt = dict["statusUpdatedAt"] as? Double ?? nowMs
        let pid = dict["pid"] as? Int ?? 0
        let startedAt = dict["startedAt"] as? Double ?? 0

        if !sid.isEmpty { referencedSids.insert(sid) }

        // Drop dead/zombie sessions (Claude crashed without a clean SessionEnd).
        let alive = sessionAlive(pid: pid, startedAt: startedAt,
                                 updatedAt: updatedAt, cutoffMs: cutoffMs)
        if !alive {
            if !sid.isEmpty {
                try? fm.removeItem(at: sessionsDir.appendingPathComponent("\(sid).waiting"))
            }
            continue
        }

        let ageS = (nowMs - statusUpdatedAt) / 1000
        let dirName = URL(fileURLWithPath: cwd).lastPathComponent
        let waitingFlag = sessionsDir.appendingPathComponent("\(sid).waiting")

        let isStuck = stuckEnabled && status == "busy" && ageS > Double(stuckSecs)
        // "waiting" is Claude Code's own status (e.g. a permission prompt); the
        // .waiting flag is the hook's signal for an idle-but-awaiting turn.
        let isWaiting = status == "waiting"
            || (status == "idle" && fm.fileExists(atPath: waitingFlag.path))

        let contextPct = includeContext ? sessionContextPct(sessionId: sid, cwd: cwd) : nil

        results.append(SessionInfo(
            sessionId: sid, status: status, cwd: cwd,
            dirName: dirName.isEmpty ? cwd : dirName,
            ageSeconds: ageS, isStuck: isStuck, isWaiting: isWaiting,
            updatedAt: updatedAt, contextPct: contextPct
        ))
    }

    // Sweep orphan .waiting flags whose session JSON is gone — but only when
    // every JSON parsed cleanly, so a transient read failure can't delete a
    // live session's flag (its SID would be missing from referencedSids).
    if !parseFailed {
        for file in files where file.hasSuffix(".waiting") {
            let sid = String(file.dropLast(".waiting".count))
            if !referencedSids.contains(sid) {
                try? fm.removeItem(at: sessionsDir.appendingPathComponent(file))
            }
        }
    }

    return results.sorted { $0.updatedAt > $1.updatedAt }
}

/// A session is alive if its pid exists and — when verifiable — still refers to
/// the process that started it. Matching the kernel's process start time against
/// the recorded `startedAt` defeats pid reuse after a crash.
private func sessionAlive(pid: Int, startedAt: Double,
                          updatedAt: Double, cutoffMs: Double) -> Bool {
    guard pid > 0 else { return updatedAt > cutoffMs }
    let exists = kill(pid_t(pid), 0) == 0 || errno == EPERM
    guard exists else { return false }
    // Verify identity when we can; otherwise trust liveness (no false zombies).
    guard startedAt > 0, let procStartMs = processStartMs(pid) else { return true }
    // The CLI's fork→startedAt lag measures ~5s; 30s leaves margin for a slow
    // cold start while staying far below any realistic pid-reuse interval.
    // Erring generous here avoids hiding a live session as a false zombie.
    return abs(procStartMs - startedAt) < 30_000
}

/// Process start time (epoch ms) from the kernel, or nil if it can't be read.
private func processStartMs(_ pid: Int) -> Double? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let r = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
    guard r == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_starttime
    return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
}

func formatAge(_ secs: Double) -> String {
    let s = Int(secs)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h\((s % 3600) / 60)m"
}

// MARK: - Per-session context usage

/// Fill of the context window (0–100) for a session. Prefers the exact figure
/// Claude Code spooled from its statusline; otherwise estimates from the last
/// assistant turn in the transcript. nil if neither is available.
private func sessionContextPct(sessionId: String, cwd: String) -> Double? {
    if let exact = statuslineContextPct(sessionId: sessionId) { return exact }
    guard let url = transcriptURL(sessionId: sessionId, cwd: cwd),
          let tokens = lastContextTokens(url: url) else { return nil }
    let window = Double(tokens) > stdContextWindow ? bigContextWindow : stdContextWindow
    return min(Double(tokens) / window * 100.0, 100.0)
}

/// The `<sessionId>.jsonl` transcript. Fast path: Claude derives the project
/// directory from cwd by replacing "/" and "." with "-". If that guess misses
/// (unusual path characters), fall back to scanning the project directories.
private func transcriptURL(sessionId: String, cwd: String) -> URL? {
    guard !sessionId.isEmpty else { return nil }
    let fm = FileManager.default

    if !cwd.isEmpty {
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let guess = projectsDir
            .appendingPathComponent(encoded)
            .appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: guess.path) { return guess }
    }

    guard let dirs = try? fm.contentsOfDirectory(
        at: projectsDir, includingPropertiesForKeys: nil) else { return nil }
    for dir in dirs {
        let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

/// Sum of input + cached tokens on the transcript's last assistant turn — the
/// live context size. Transcripts run to tens of MB, so only the tail is read.
private func lastContextTokens(url: URL) -> Int? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    let size = (try? handle.seekToEnd()) ?? 0
    let window: UInt64 = 1_000_000  // 1 MB tail comfortably covers the last turn
    let start = size > window ? size - window : 0
    // Read one byte before the window (when not at the file start) so the byte
    // preceding `start` tells us whether the window opens on a line boundary.
    let readFrom = start > 0 ? start - 1 : 0
    guard (try? handle.seek(toOffset: readFrom)) != nil,
          let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

    var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
    // If the byte before the window isn't a newline, the window opened mid-line
    // and that first fragment isn't valid JSON — drop it. On an exact boundary
    // (preceding byte is a newline) the first record is whole, so keep it.
    if start > 0, data.first != 0x0A, !lines.isEmpty { lines.removeFirst() }

    for lineData in lines.reversed() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { continue }
        let input = usage["input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
        let total = input + cacheRead + cacheCreate
        return total > 0 ? total : nil
    }
    return nil
}

func determineAnimState(sessions: [SessionInfo]) -> AnimState {
    if sessions.contains(where: { $0.isWaiting }) { return .bounce }
    if sessions.contains(where: { $0.isStuck }) { return .pulse }
    if sessions.contains(where: { $0.status == "busy" && !$0.isStuck }) { return .walk }
    return .idle
}
