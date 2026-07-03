import Foundation

private let githubLatestRedirect =
    "https://github.com/ksterx/MenubarCC/releases/latest"
private let githubReleasesURL =
    "https://github.com/ksterx/MenubarCC/releases"

func currentVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
}

func parseVersion(_ v: String) -> [Int] {
    let cleaned = v.hasPrefix("v") ? String(v.dropFirst()) : v
    return cleaned.split(separator: ".").compactMap { Int($0) }
}

func compareVersions(_ a: String, _ b: String) -> Int {
    let va = parseVersion(a)
    let vb = parseVersion(b)
    let count = max(va.count, vb.count)
    for i in 0..<count {
        let ai = i < va.count ? va[i] : 0
        let bi = i < vb.count ? vb[i] : 0
        if ai < bi { return -1 }
        if ai > bi { return 1 }
    }
    return 0
}

func fetchLatestRelease(completion: @escaping ((tag: String, url: String)?) -> Void) {
    guard let url = URL(string: githubLatestRedirect) else {
        completion(nil); return
    }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.setValue("MenubarCC-update-check", forHTTPHeaderField: "User-Agent")

    URLSession.shared.dataTask(with: request) { _, response, error in
        guard error == nil,
              let finalURL = response?.url?.absoluteString,
              finalURL.contains("/releases/tag/") else {
            completion(nil); return
        }
        let parts = finalURL.components(separatedBy: "/releases/tag/")
        guard parts.count == 2 else { completion(nil); return }
        let tag = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !tag.isEmpty, !tag.contains("/") else { completion(nil); return }
        completion((tag, finalURL))
    }.resume()
}

private func dmgURL(for tag: String) -> URL? {
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    return URL(string: "\(githubReleasesURL)/download/\(tag)/MenubarCC-\(version).dmg")
}

private let swapScript = """
#!/bin/bash
PID=$1; NEW="$2"; TARGET="$3"; TMP="$4"
BACKUP="$TARGET.old-$$"
for _ in $(seq 1 300); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.2
done
if kill -0 "$PID" 2>/dev/null; then
  rm -rf "$TMP"; exit 0
fi
if mv "$TARGET" "$BACKUP" 2>/dev/null; then
  if ditto "$NEW" "$TARGET"; then
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
    rm -rf "$BACKUP"
  else
    rm -rf "$TARGET"
    mv "$BACKUP" "$TARGET" 2>/dev/null || true
  fi
fi
if [ ! -d "$TARGET" ] && [ -d "$BACKUP" ]; then
  mv "$BACKUP" "$TARGET" 2>/dev/null || true
fi
if [ -d "$TARGET" ]; then open "$TARGET"; fi
rm -rf "$TMP"
"""

func performUpdate(tag: String) -> String? {
    let bundle = Bundle.main.bundleURL
    guard bundle.pathExtension == "app" else {
        return "Updates only apply to the installed app, not when run from source."
    }
    let fm = FileManager.default
    guard fm.isWritableFile(atPath: bundle.path),
          fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
        return "No permission to replace the app at \(bundle.path). Update manually."
    }
    guard let downloadURL = dmgURL(for: tag) else {
        return "Could not construct download URL for \(tag)."
    }

    let tmp = fm.temporaryDirectory.appendingPathComponent("menubarcc-update-\(UUID().uuidString)")
    let dmgPath = tmp.appendingPathComponent("update.dmg")
    let mountPath = tmp.appendingPathComponent("mnt")
    let stagingPath = tmp.appendingPathComponent("staged")
    var handedOff = false

    defer {
        if !handedOff { try? fm.removeItem(at: tmp) }
    }

    do {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        var request = URLRequest(url: downloadURL, timeoutInterval: 120)
        request.setValue("MenubarCC-update-check", forHTTPHeaderField: "User-Agent")

        var downloadError: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: request) { tempURL, response, error in
            defer { sem.signal() }
            if let error = error { downloadError = error; return }
            guard let tempURL = tempURL,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 {
                    downloadError = NSError(domain: "MenubarCC", code: 404, userInfo: [
                        NSLocalizedDescriptionKey: "Download not found for this release."
                    ])
                } else {
                    downloadError = NSError(domain: "MenubarCC", code: code, userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \(code)"
                    ])
                }
                return
            }
            do { try fm.moveItem(at: tempURL, to: dmgPath) }
            catch { downloadError = error }
        }.resume()
        sem.wait()

        if let err = downloadError { return "Update failed: \(err.localizedDescription)" }

        try fm.createDirectory(at: mountPath, withIntermediateDirectories: true)
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", dmgPath.path, "-nobrowse", "-readonly",
                            "-mountpoint", mountPath.path]
        attach.standardOutput = FileHandle.nullDevice
        attach.standardError = FileHandle.nullDevice
        try attach.run()
        attach.waitUntilExit()
        guard attach.terminationStatus == 0 else {
            return "Failed to mount the downloaded disk image."
        }

        defer {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mountPath.path, "-quiet"]
            detach.standardOutput = FileHandle.nullDevice
            detach.standardError = FileHandle.nullDevice
            try? detach.run()
            detach.waitUntilExit()
        }

        let apps = try fm.contentsOfDirectory(atPath: mountPath.path)
            .filter { $0.hasSuffix(".app") }
        guard let appName = apps.first else {
            return "The downloaded disk image contains no app."
        }

        try fm.createDirectory(at: stagingPath, withIntermediateDirectories: true)
        let newApp = stagingPath.appendingPathComponent(appName)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [mountPath.appendingPathComponent(appName).path, newApp.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            return "Failed to copy the new app from the disk image."
        }

        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", newApp.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        let helperPath = tmp.appendingPathComponent("swap.sh")
        try swapScript.write(to: helperPath, atomically: true, encoding: .utf8)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [helperPath.path,
                            "\(ProcessInfo.processInfo.processIdentifier)",
                            newApp.path, bundle.path, tmp.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        helper.qualityOfService = .background
        try helper.run()

        handedOff = true
        return nil
    } catch {
        return "Update failed: \(error.localizedDescription)"
    }
}
