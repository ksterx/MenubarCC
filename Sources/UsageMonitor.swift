import Foundation

// Claude Code hands rate-limit and context percentages to the statusline
// command over stdin and never persists them. A small snippet in the user's
// statusline spools the latest values per session into ~/.claude/statusline-usage/.
// When the files are absent or stale, the usage gauges hide and context falls
// back to a transcript estimate.

struct RateLimitsSnapshot {
    let fiveHour: Double?   // 0–100
    let sevenDay: Double?   // 0–100
}

private let usageDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/statusline-usage")

// The five-hour window turns over fast and the numbers only update while a
// statusline renders, so anything older than this is treated as absent rather
// than shown stale.
private let usageMaxAge: TimeInterval = 15 * 60

// Spool files are only overwritten while a session is active; sweep ones that
// have gone cold so the directory can't grow without bound.
private let usagePruneAge: TimeInterval = 24 * 3600

private func usageSnapshot(at url: URL) -> (dict: [String: Any], age: Double)? {
    guard let data = try? Data(contentsOf: url),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    let ts = d["ts"] as? Double ?? 0
    let age = Date().timeIntervalSince1970 - ts
    guard age >= 0 else { return nil }
    return (d, age)
}

/// Account-wide rate limits from the most recently written session snapshot.
func loadRateLimits() -> RateLimitsSnapshot? {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(
        at: usageDir, includingPropertiesForKeys: nil) else { return nil }

    var newest: (dict: [String: Any], age: Double)?
    for url in files {
        // Sweep temp files abandoned by a crashed/killed writer.
        if url.pathExtension == "tmp" {
            if let mod = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(mod) > usagePruneAge {
                try? fm.removeItem(at: url)
            }
            continue
        }
        guard url.pathExtension == "json", let snap = usageSnapshot(at: url) else { continue }
        // Opportunistically drop cold files while we're already listing them.
        if snap.age > usagePruneAge { try? fm.removeItem(at: url); continue }
        if newest == nil || snap.age < newest!.age { newest = snap }
    }

    guard let d = newest?.dict, let age = newest?.age, age <= usageMaxAge else { return nil }
    let five = d["five_hour"] as? Double
    let week = d["seven_day"] as? Double
    if five == nil && week == nil { return nil }
    return RateLimitsSnapshot(fiveHour: five, sevenDay: week)
}

/// Authoritative context fill (0–100) for a session, straight from the value
/// Claude Code computed for its statusline — or nil if none is available.
///
/// Unlike rate limits, a session's context doesn't drift while it sits idle, so
/// the spooled value stays accurate even when old; an active session re-renders
/// its statusline and refreshes it. Bound only by the prune age.
func statuslineContextPct(sessionId: String) -> Double? {
    guard !sessionId.isEmpty else { return nil }
    let url = usageDir.appendingPathComponent("\(sessionId).json")
    guard let snap = usageSnapshot(at: url), snap.age <= usagePruneAge else { return nil }
    return snap.dict["context"] as? Double
}
