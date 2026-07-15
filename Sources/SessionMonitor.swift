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
}

enum AnimState {
    case idle, walk, bounce, pulse
}

private let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/sessions")

// A session whose owning process is gone is a zombie (Claude crashed without a
// clean SessionEnd). Age is only a fallback for sessions that carry no pid.
private let maxSessionAge: TimeInterval = 12 * 3600

func loadSessions(stuckSecs: Int, stuckEnabled: Bool) -> [SessionInfo] {
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

        results.append(SessionInfo(
            sessionId: sid, status: status, cwd: cwd,
            dirName: dirName.isEmpty ? cwd : dirName,
            ageSeconds: ageS, isStuck: isStuck, isWaiting: isWaiting,
            updatedAt: updatedAt
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

func determineAnimState(sessions: [SessionInfo]) -> AnimState {
    if sessions.contains(where: { $0.isWaiting }) { return .bounce }
    if sessions.contains(where: { $0.isStuck }) { return .pulse }
    if sessions.contains(where: { $0.status == "busy" && !$0.isStuck }) { return .walk }
    return .idle
}
