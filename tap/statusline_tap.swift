import Foundation

// MenubarCC statusline tap.
//
// Sits in front of the user's real statusline as `tap | ( original )`. It
// copies stdin byte-for-byte to stdout so the original statusline renders
// unchanged, and on the side spools the rate-limit / context numbers Claude
// Code only ever passes to the statusline into a file MenubarCC watches.
//
// Contract: this must NEVER break the statusline. Bytes are forwarded as they
// arrive (never buffering the whole stream first), and on any error it still
// exits 0; the spool is strictly best-effort. `--capture-only` consumes stdin
// and emits nothing, for users who have no statusline of their own.

// A downstream that never reads stdin (e.g. `echo hi`) closes the pipe early;
// ignore SIGPIPE so that can't kill us mid-forward.
signal(SIGPIPE, SIG_IGN)

let captureOnly = CommandLine.arguments.contains("--capture-only")

// Only a genuine finite number, clamped to a sane percentage. Guards MenubarCC
// against values like 1e300 that would later trap Int(...) on render.
func clampPct(_ v: Any?) -> Double? {
    guard let n = v as? Double, n.isFinite else { return nil }
    return min(max(n, 0), 100)
}

// Filename-safe session id: ASCII [A-Za-z0-9._-] only, byte-bounded, never a
// path. Never trust it as a path component.
func isSafeSessionId(_ s: String) -> Bool {
    let bytes = Array(s.utf8)
    guard !bytes.isEmpty, bytes.count <= 128, s != ".", s != ".." else { return false }
    for b in bytes {
        let ok = (b >= 0x30 && b <= 0x39)   // 0-9
            || (b >= 0x41 && b <= 0x5A)      // A-Z
            || (b >= 0x61 && b <= 0x7A)      // a-z
            || b == 0x2D || b == 0x5F || b == 0x2E  // - _ .
        if !ok { return false }
    }
    return true
}

func forward(_ base: UnsafeRawPointer, _ count: Int) {
    if captureOnly { return }
    var p = base
    var remaining = count
    while remaining > 0 {
        let n = write(1, p, remaining)
        if n < 0 {
            if errno == EINTR { continue }
            break  // EPIPE or similar: downstream is gone, stop forwarding
        }
        remaining -= n
        p = p.advanced(by: n)
    }
}

// 1. Stream stdin → stdout in chunks, keeping only a capped copy to parse.
let parseCap = 1 << 20  // 1 MB — vastly more than any statusline payload
let chunkSize = 65536
var chunk = [UInt8](repeating: 0, count: chunkSize)
var parseBuffer = Data()

while true {
    let n = chunk.withUnsafeMutableBytes { read(0, $0.baseAddress, chunkSize) }
    if n < 0 {
        if errno == EINTR { continue }
        break
    }
    if n == 0 { break }  // EOF
    chunk.withUnsafeBytes { forward($0.baseAddress!, n) }
    if parseBuffer.count < parseCap {
        let take = min(n, parseCap - parseBuffer.count)
        parseBuffer.append(contentsOf: chunk[0..<take])
    }
}
close(1)

// 2. Best-effort parse + spool. Any failure just exits 0.
if let obj = try? JSONSerialization.jsonObject(with: parseBuffer) as? [String: Any],
   let sid = obj["session_id"] as? String, isSafeSessionId(sid) {
    let rl = obj["rate_limits"] as? [String: Any]
    var snap: [String: Any] = ["ts": Date().timeIntervalSince1970]
    snap["five_hour"] = clampPct((rl?["five_hour"] as? [String: Any])?["used_percentage"]) ?? NSNull()
    snap["seven_day"] = clampPct((rl?["seven_day"] as? [String: Any])?["used_percentage"]) ?? NSNull()
    snap["context"] = clampPct((obj["context_window"] as? [String: Any])?["used_percentage"]) ?? NSNull()

    if let data = try? JSONSerialization.data(withJSONObject: snap) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/statusline-usage")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let dest = dir.appendingPathComponent("\(sid).json")
        let tmp = dir.appendingPathComponent("\(sid).\(getpid()).tmp")
        if (try? data.write(to: tmp)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if rename(tmp.path, dest.path) != 0 { try? fm.removeItem(at: tmp) }
        }
    }
}

exit(0)
