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

func loadSessions(stuckSecs: Int, stuckEnabled: Bool) -> [SessionInfo] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return [] }

    let nowMs = Date().timeIntervalSince1970 * 1000
    var results: [SessionInfo] = []

    for file in files where file.hasSuffix(".json") {
        let path = sessionsDir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        let sid = dict["sessionId"] as? String ?? ""
        let status = dict["status"] as? String ?? ""
        let cwd = dict["cwd"] as? String ?? "?"
        let updatedAt = dict["updatedAt"] as? Double ?? 0
        let statusUpdatedAt = dict["statusUpdatedAt"] as? Double ?? nowMs
        let ageS = (nowMs - statusUpdatedAt) / 1000

        let dirName = URL(fileURLWithPath: cwd).lastPathComponent
        let waitingFlag = sessionsDir.appendingPathComponent("\(sid).waiting")

        let isStuck = stuckEnabled && status == "busy" && ageS > Double(stuckSecs)
        let isWaiting = status == "idle" && fm.fileExists(atPath: waitingFlag.path)

        results.append(SessionInfo(
            sessionId: sid, status: status, cwd: cwd,
            dirName: dirName.isEmpty ? cwd : dirName,
            ageSeconds: ageS, isStuck: isStuck, isWaiting: isWaiting,
            updatedAt: updatedAt
        ))
    }

    return results.sorted { $0.updatedAt > $1.updatedAt }
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
