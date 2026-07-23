import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - Constants

private let refreshSecs: TimeInterval = 10
private let defaultAnimFps: Double = 0.12
private let defaultStuckSecs = 600
private let firstRunPromptDelay: TimeInterval = 2.0
private let updateCheckDelay: TimeInterval = 8.0
private let updateCheckInterval: TimeInterval = 24 * 3600

let speedPresets: [(label: String, interval: Double)] = [
    ("Very Slow", 0.30), ("Slow", 0.20), ("Normal", 0.12),
    ("Fast", 0.08), ("Very Fast", 0.04),
]

let stuckPresets: [(label: String, secs: Int)] = [
    ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900),
    ("30 minutes", 1800), ("60 minutes", 3600),
]

// Mirrors DEFAULT_SOUNDS in menubarcc_hook.py so previews match what plays.
private let defaultSoundPaths: [String: String] = [
    "Stop":              "/System/Library/Sounds/Glass.aiff",
    "Notification":      "/System/Library/Sounds/Tink.aiff",
    "PermissionRequest": "/System/Library/Sounds/Funk.aiff",
]

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var frames: AnimationFrames!
    private var animTimer: Timer?
    private var refreshTimer: Timer?
    private var updateTimer: Timer?
    // A newer release found by a background check, surfaced at the top of the menu.
    private var availableUpdate: String?
    // The most recent sound preview, so a new one can cut off the last.
    private var previewProcess: Process?

    private var animState: AnimState = .idle
    private var animIdx = 0
    private var animFps: Double = defaultAnimFps
    private var stuckEnabled = true
    private var stuckSecs = defaultStuckSecs
    private var knownStuck: Set<String> = []
    private var eventsWatcher: DispatchSourceFileSystemObject?

    // Cached OS notification permission — menu building is synchronous,
    // so the async settings query updates these and re-renders on change.
    private var notifStatus: UNAuthorizationStatus = .notDetermined
    private var notifAuthorized = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let iconPath = resourcePath("menubarcc-icon.png")
        guard let source = NSImage(contentsOf: iconPath) else {
            NSLog("[MenubarCC] Cannot load icon from %@", iconPath.path)
            NSApp.terminate(nil)
            return
        }

        frames = generateFrames(from: source)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = frames.staticFrame
        statusItem.button?.imagePosition = .imageOnly

        // The menu is populated lazily in menuNeedsUpdate(_:) so its session
        // list is always current when opened, not up to refreshSecs stale.
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        let settings = loadAppSettings()
        animFps = settings["animFps"] as? Double ?? defaultAnimFps
        stuckEnabled = settings["stuckEnabled"] as? Bool ?? true
        stuckSecs = settings["stuckSecs"] as? Int ?? defaultStuckSecs

        animTimer = Timer.scheduledTimer(withTimeInterval: animFps, repeats: true) {
            [weak self] _ in self?.animate()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshSecs, repeats: true) {
            [weak self] _ in self?.refreshState()
        }

        UNUserNotificationCenter.current().delegate = self
        refreshNotifStatus()
        syncInstalledHookScript()
        // Off the main thread: replacing a changed helper self-tests it, which
        // must never block app launch.
        DispatchQueue.global(qos: .utility).async { syncStatuslineTap() }
        startEventsWatcher()

        refreshState()

        DispatchQueue.main.asyncAfter(deadline: .now() + firstRunPromptDelay) {
            [weak self] in self?.firstRunCheck()
        }

        // Update checks: shortly after launch, then once a day. Both only look;
        // downloading and restarting still require the user's confirmation.
        DispatchQueue.main.asyncAfter(deadline: .now() + updateCheckDelay) {
            [weak self] in self?.backgroundUpdateCheck()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateCheckInterval, repeats: true) {
            [weak self] _ in self?.backgroundUpdateCheck()
        }
    }

    // MARK: - Notification permission

    private func refreshNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            let authorized = s.authorizationStatus == .authorized
                && s.alertSetting == .enabled
            DispatchQueue.main.async {
                guard let self = self else { return }
                if authorized != self.notifAuthorized
                    || s.authorizationStatus != self.notifStatus {
                    self.notifStatus = s.authorizationStatus
                    self.notifAuthorized = authorized
                    self.refreshState()
                }
            }
        }
    }

    /// Route the user to whatever unblocks banners: the system prompt when
    /// it can still be shown, System Settings once it can't.
    private func ensureNotificationPermission() {
        if notifStatus == .notDetermined {
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.refreshNotifStatus() }
                }
        } else {
            let bid = Bundle.main.bundleIdentifier ?? "com.ksterx.clawd"
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bid)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func fixNotifPermission(_ sender: NSMenuItem) {
        ensureNotificationPermission()
    }

    // MARK: - Banner events (spooled by menubarcc_hook.py)

    private func startEventsWatcher() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appEventsDir, withIntermediateDirectories: true)
        // Drop events spooled while the app wasn't running
        if let stale = try? fm.contentsOfDirectory(atPath: appEventsDir.path) {
            for f in stale {
                try? fm.removeItem(at: appEventsDir.appendingPathComponent(f))
            }
        }
        let fd = open(appEventsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        src.setEventHandler { [weak self] in self?.drainBannerEvents() }
        src.setCancelHandler { close(fd) }
        src.resume()
        eventsWatcher = src
    }

    private func drainBannerEvents() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: appEventsDir.path) else { return }
        for f in files.sorted() where f.hasSuffix(".json") {
            let url = appEventsDir.appendingPathComponent(f)
            let data = try? Data(contentsOf: url)
            try? fm.removeItem(at: url)
            guard let data = data,
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            showBanner(for: d)
        }
        // A hook just wrote the .waiting flag before spooling this banner —
        // react now so Clawd starts bouncing instead of waiting for the poll.
        refreshState()
    }

    // The banner headline is the session's project directory — the OS
    // already labels the banner with the app name, so repeating
    // "Claude Code" there would just be noise.
    private func showBanner(for event: [String: Any]) {
        let kind = event["event"] as? String ?? ""
        let cwd = event["cwd"] as? String ?? ""
        let dir = cwd.isEmpty ? "Claude Code" : URL(fileURLWithPath: cwd).lastPathComponent
        let message = event["message"] as? String ?? ""

        let body: String
        switch kind {
        case "Stop":
            body = message.isEmpty ? "Finished \u{2014} waiting for your input" : message
        case "PermissionRequest":
            body = message.isEmpty ? "Waiting for your approval" : message
        default:
            body = message.isEmpty ? "Notification" : message
        }
        sendNotification(title: dir, subtitle: "", body: body, cwd: cwd)
    }

    // MARK: - Resource path

    private func resourcePath(_ filename: String) -> URL {
        if let rp = Bundle.main.resourcePath {
            return URL(fileURLWithPath: rp).appendingPathComponent(filename)
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent(filename)
    }

    // MARK: - Animation

    private func animate() {
        let seq: [NSImage]
        switch animState {
        case .walk:   seq = frames.walk
        case .bounce: seq = frames.bounce
        case .pulse:  seq = frames.pulse
        case .idle:   return
        }
        animIdx = (animIdx + 1) % seq.count
        statusItem.button?.image = seq[animIdx]
    }

    // MARK: - Refresh

    /// Update everything that must stay live even while the menu is closed:
    /// the crab animation, the menu-bar tooltip, and stuck notifications.
    /// The menu itself is (re)built lazily in menuNeedsUpdate(_:).
    private func refreshState() {
        let ss = loadSessions(stuckSecs: stuckSecs, stuckEnabled: stuckEnabled)
        let stuck   = ss.filter { $0.isStuck }
        let busy    = ss.filter { $0.status == "busy" && !$0.isStuck }
        let waiting = ss.filter { $0.isWaiting }
        let idle    = ss.filter { $0.status == "idle" && !$0.isWaiting }

        let newState = determineAnimState(sessions: ss)
        if newState != animState {
            animState = newState
            animIdx = 0
        }
        if newState == .idle {
            statusItem.button?.image = frames.staticFrame
        }

        updateTooltip(stuck: stuck, busy: busy, waiting: waiting, idle: idle)

        // Stuck notifications (gated by the Banners toggle)
        let bannersOn = loadHookConfig()["bannersEnabled"] as? Bool ?? true
        for s in stuck where !knownStuck.contains(s.sessionId) {
            if bannersOn {
                sendNotification(
                    title: s.dirName,
                    subtitle: "",
                    body: "Stuck \u{2014} busy for \(formatAge(s.ageSeconds)) with no updates",
                    cwd: s.cwd
                )
            }
        }
        knownStuck = Set(stuck.map(\.sessionId))
    }

    // Glance-able summary on hover, most-actionable category first.
    private func updateTooltip(
        stuck: [SessionInfo], busy: [SessionInfo],
        waiting: [SessionInfo], idle: [SessionInfo]
    ) {
        var parts: [String] = []
        if !waiting.isEmpty { parts.append("\(waiting.count) waiting") }
        if !stuck.isEmpty   { parts.append("\(stuck.count) stuck") }
        if !busy.isEmpty    { parts.append("\(busy.count) active") }
        if !idle.isEmpty    { parts.append("\(idle.count) idle") }
        statusItem.button?.toolTip =
            parts.isEmpty ? "MenubarCC \u{2014} no sessions" : parts.joined(separator: " \u{00B7} ")
    }

    private func sendNotification(title: String, subtitle: String, body: String, cwd: String = "") {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        // Group notifications per project in Notification Center
        content.threadIdentifier = title
        // Carry the project path so tapping the banner can reopen the session.
        if !cwd.isEmpty { content.userInfo = ["cwd": cwd] }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        center.add(req)
    }

    // Tapping a banner jumps to the session it came from, using the same
    // "On Session Click" behavior as a menu row.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let cwd = response.notification.request.content.userInfo["cwd"] as? String {
            DispatchQueue.main.async { [weak self] in self?.openProject(cwd: cwd) }
        }
        completionHandler()
    }

    // Still show the banner if MenubarCC happens to be the active app (e.g. its
    // menu is open). Sound is left to the hook, so don't request it here.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let ss = loadSessions(stuckSecs: stuckSecs, stuckEnabled: stuckEnabled,
                              includeContext: true)
        let stuck   = ss.filter { $0.isStuck }
        let busy    = ss.filter { $0.status == "busy" && !$0.isStuck }
        let waiting = ss.filter { $0.isWaiting }
        let idle    = ss.filter { $0.status == "idle" && !$0.isWaiting }
        populateMenu(menu, sessions: ss, stuck: stuck, busy: busy, waiting: waiting, idle: idle)
    }

    // autoenablesItems is false on this menu (set once at creation) so the
    // custom switch rows keep their accent tint instead of rendering dimmed.
    private func populateMenu(
        _ menu: NSMenu,
        sessions: [SessionInfo],
        stuck: [SessionInfo], busy: [SessionInfo],
        waiting: [SessionInfo], idle: [SessionInfo]
    ) {
        menu.removeAllItems()

        // Top notices: an available update, and one-tap nudges to turn on
        // features a user may not have discovered.
        addNoticesSection(menu)

        // Account-wide usage limits, when a fresh statusline snapshot exists.
        if let rl = loadRateLimits() {
            addUsageSection(menu, rl)
            menu.addItem(.separator())
        }

        if sessions.isEmpty {
            let item = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        } else {
            addSection(menu, label: "\u{26A0}   STUCK   \u{00B7}  \(stuck.count)", sessions: stuck)
            addSection(menu, label: "\u{23F5}   ACTIVE  \u{00B7}  \(busy.count)", sessions: busy)
            addSection(menu, label: "\u{23F8}  WAITING  \u{00B7}  \(waiting.count)", sessions: waiting)
            addSection(menu, label: "\u{00B7}   IDLE    \u{00B7}  \(idle.count)", sessions: idle)
        }

        // Sound / banner toggles — independent controls
        let cfg = loadHookConfig()
        let muted = cfg["muteAll"] as? Bool ?? false
        let banners = cfg["bannersEnabled"] as? Bool ?? true

        let soundsItem = NSMenuItem()
        soundsItem.view = makeSwitchView(
            title: "Sounds",
            isOn: !muted,
            target: self,
            action: #selector(soundsToggled(_:))
        )
        menu.addItem(soundsItem)

        // Volume lives right under Sounds while sounds are on — there's nothing
        // to set while muted, so it collapses away.
        if !muted {
            let volume = cfg["volume"] as? Double ?? 1.0
            let volumeItem = NSMenuItem()
            volumeItem.view = makeSliderView(
                title: "Volume",
                value: volume,
                enabled: true,
                target: self,
                action: #selector(volumeChanged(_:))
            )
            menu.addItem(volumeItem)
        }

        // The switch shows the EFFECTIVE state: app setting AND OS permission.
        let bannersItem = NSMenuItem()
        bannersItem.view = makeSwitchView(
            title: "Banners",
            isOn: banners && notifAuthorized,
            target: self,
            action: #selector(bannersToggled(_:))
        )
        menu.addItem(bannersItem)

        // Only surface the permission problem when it actually blocks banners.
        if banners && !notifAuthorized {
            let warn = NSMenuItem(
                title: "",
                action: #selector(fixNotifPermission(_:)),
                keyEquivalent: ""
            )
            warn.attributedTitle = NSAttributedString(
                string: "\u{26A0} Enable notifications in System Settings\u{2026}",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.systemOrange,
                ]
            )
            warn.target = self
            menu.addItem(warn)
        }

        // Advanced Settings
        menu.addItem(buildAdvancedMenu())
        menu.addItem(.separator())

        let updateItem = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(checkUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        let quitItem = NSMenuItem(
            title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // NSSwitch draws its accent tint only while the app is active; an
    // accessory app's status menu opens without activation, leaving the
    // switch gray even when ON. Activate for the menu's lifetime only.
    func menuWillOpen(_ menu: NSMenu) {
        NSApp.activate(ignoringOtherApps: true)
        refreshNotifStatus()   // pick up permission changes made in Settings
    }

    func menuDidClose(_ menu: NSMenu) {
        NSApp.deactivate()
    }

    private func addSection(_ menu: NSMenu, label: String, sessions: [SessionInfo]) {
        guard !sessions.isEmpty else { return }

        let header = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        menu.addItem(header)

        for s in sessions {
            let item = NSMenuItem()
            item.view = makeSessionRowView(s)
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    // Fixed-column row so name / age / context line up across sessions and the
    // context reaches the same right edge (246) as the gauges above.
    private func makeSessionRowView(_ s: SessionInfo) -> NSView {
        let width: CGFloat = 260, height: CGFloat = 22
        let row = MenuRowView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.toolTip = s.cwd   // full path disambiguates same-named dirs
        row.onClick = { [weak self] in self?.openProject(cwd: s.cwd) }

        let name = NSTextField(labelWithString: s.dirName)
        name.frame = NSRect(x: 28, y: 3, width: 94, height: 16)
        name.font = NSFont.menuFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        name.cell?.truncatesLastVisibleLine = true
        row.addSubview(name)

        let age = NSTextField(labelWithString: formatAge(s.ageSeconds))
        age.frame = NSRect(x: 124, y: 4, width: 46, height: 14)
        age.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        age.textColor = .tertiaryLabelColor
        age.alignment = .right
        row.addSubview(age)

        if let pct = s.contextPct {
            let color = gaugeColor(pct)
            let trackW: CGFloat = 34
            let track = NSView(frame: NSRect(x: 176, y: 8, width: trackW, height: 6))
            track.wantsLayer = true
            track.layer?.backgroundColor =
                NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
            track.layer?.cornerRadius = 3
            let clamped = CGFloat(min(max(pct, 0), 100) / 100)
            let fill = NSView(frame: NSRect(
                x: 0, y: 0, width: clamped > 0 ? max(4, trackW * clamped) : 0, height: 6))
            fill.wantsLayer = true
            fill.layer?.backgroundColor = color.cgColor
            fill.layer?.cornerRadius = 3
            track.addSubview(fill)
            row.addSubview(track)

            let pctField = NSTextField(labelWithString: "\(Int(pct.rounded()))%")
            pctField.frame = NSRect(x: 212, y: 4, width: 34, height: 14)
            pctField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            pctField.textColor = color
            pctField.alignment = .right
            row.addSubview(pctField)
        }
        return row
    }

    // MARK: - Top notices (update + feature nudges)

    private func addNoticesSection(_ menu: NSMenu) {
        var added = false

        func notice(_ text: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem()
            item.view = makeNoticeRow(text, action: action)
            menu.addItem(item)
            added = true
        }

        if let tag = availableUpdate {
            notice("\u{2191}  Update to \(tag)\u{2026}") { [weak self] in self?.confirmAndApply(tag: tag) }
        }
        if !hooksAreInstalled() {
            notice("\u{25C7}  Enable sounds & waiting alerts\u{2026}") {
                [weak self] in self?.installHookAction(NSMenuItem())
            }
        }
        if !usageCaptureInstalled() {
            notice("\u{25C7}  Show usage limits in the menu\u{2026}") {
                [weak self] in self?.enableUsageCaptureAction(NSMenuItem())
            }
        }

        if added { menu.addItem(.separator()) }
    }

    // A full-width accent row so long notice text can't widen the whole menu.
    private func makeNoticeRow(_ text: String, action: @escaping () -> Void) -> NSView {
        let width: CGFloat = 260, height: CGFloat = 24
        let row = MenuRowView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.onClick = action
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 18, y: 4, width: width - 32, height: 16)
        label.font = NSFont.menuFont(ofSize: 13)
        label.textColor = .controlAccentColor
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        row.addSubview(label)
        return row
    }

    // MARK: - Usage gauges

    private func gaugeColor(_ pct: Double) -> NSColor {
        if pct < 50 { return .systemGreen }
        if pct < 80 { return .systemOrange }
        return .systemRed
    }

    private func addUsageSection(_ menu: NSMenu, _ rl: RateLimitsSnapshot) {
        let header = NSMenuItem(title: "USAGE", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "USAGE",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        menu.addItem(header)

        var rings: [(pct: Double, caption: String)] = []
        if let five = rl.fiveHour { rings.append((five, "5-hour")) }
        if let week = rl.sevenDay { rings.append((week, "Weekly")) }
        guard !rings.isEmpty else { return }

        let item = NSMenuItem()
        item.view = makeUsageRingsView(rings)
        menu.addItem(item)
    }

    // The limits as side-by-side progress rings: percentage centered inside,
    // caption beneath, colored green/amber/red by fill.
    private func makeUsageRingsView(_ rings: [(pct: Double, caption: String)]) -> NSView {
        let width: CGFloat = 260, height: CGFloat = 96
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let diameter: CGFloat = 66
        let ringY: CGFloat = 26

        // Evenly space each ring's center across the width.
        for (i, ring) in rings.enumerated() {
            let cx = width * (CGFloat(i) + 0.5) / CGFloat(rings.count)
            let color = gaugeColor(ring.pct)

            let ringView = RingView(frame: NSRect(x: cx - diameter / 2, y: ringY,
                                                  width: diameter, height: diameter))
            ringView.pct = ring.pct
            ringView.color = color
            ringView.lineWidth = 6
            container.addSubview(ringView)

            let pctLabel = NSTextField(labelWithString: "\(Int(ring.pct.rounded()))%")
            pctLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            pctLabel.textColor = color
            pctLabel.alignment = .center
            pctLabel.frame = NSRect(x: cx - 34, y: ringY + diameter / 2 - 11, width: 68, height: 22)
            container.addSubview(pctLabel)

            let cap = NSTextField(labelWithString: ring.caption)
            cap.font = .systemFont(ofSize: 11)
            cap.textColor = .secondaryLabelColor
            cap.alignment = .center
            cap.frame = NSRect(x: cx - 45, y: 6, width: 90, height: 14)
            container.addSubview(cap)
        }
        return container
    }

    // Shared by a session-row click and a banner tap: jump to the project per
    // the "On Session Click" setting — Orca terminal, Finder, or copy the path.
    private func openProject(cwd: String) {
        guard !cwd.isEmpty else { return }
        let action = loadAppSettings()["sessionClickAction"] as? String
            ?? (orcaAvailable() ? "orca" : "finder")

        switch action {
        case "copy":
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cwd, forType: .string)
        case "orca":
            // Runs `orca` subprocesses — do the work off the main thread and
            // fall back to Finder if no matching terminal is found.
            DispatchQueue.global(qos: .userInitiated).async {
                if !orcaSwitchToTerminal(forCwd: cwd) {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
                    }
                }
            }
        default: // "finder"
            NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
        }
    }

    // MARK: - Switch view (Tailscale-style toggle)

    private func makeSwitchView(
        title: String, isOn: Bool,
        target: AnyObject, action: Selector
    ) -> NSView {
        let width: CGFloat = 260, height: CGFloat = 32
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let titleField = NSTextField(labelWithString: title)
        titleField.frame = NSRect(x: 14, y: 8, width: 180, height: 16)
        titleField.font = NSFont.menuFont(ofSize: 13)
        view.addSubview(titleField)

        let sw = NSSwitch()
        sw.frame = NSRect(x: width - 56, y: 5, width: 40, height: 22)
        sw.state = isOn ? .on : .off
        sw.target = target
        sw.action = action
        view.addSubview(sw)

        return view
    }

    // MARK: - Slider view (volume)

    private func makeSliderView(
        title: String, value: Double, enabled: Bool,
        target: AnyObject, action: Selector
    ) -> NSView {
        let width: CGFloat = 260, height: CGFloat = 40
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let titleField = NSTextField(labelWithString: title)
        titleField.frame = NSRect(x: 14, y: 20, width: 180, height: 16)
        titleField.font = NSFont.menuFont(ofSize: 13)
        titleField.textColor = enabled ? .labelColor : .disabledControlTextColor
        view.addSubview(titleField)

        let slider = NSSlider(frame: NSRect(x: 14, y: 2, width: width - 28, height: 20))
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value
        slider.isEnabled = enabled
        slider.target = target
        slider.action = action
        // Coalesce to one config write on mouse-up rather than one per drag tick —
        // there's no live audio preview, so continuous updates buy nothing.
        slider.isContinuous = false
        view.addSubview(slider)

        return view
    }

    @objc private func soundsToggled(_ sender: NSSwitch) {
        updateHookConfig(["muteAll": sender.state != .on])
        refreshState()
        // Rebuild the still-open menu so the volume row shows/hides immediately.
        // Async so it runs after this switch's own event finishes.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let menu = self.statusItem.menu else { return }
            self.menuNeedsUpdate(menu)
        }
    }

    // Preview the reply's opening in the Stop banner body. Defaults on.
    private func buildResponsePreviewItem() -> NSMenuItem {
        let on = loadHookConfig()["responsePreviewEnabled"] as? Bool ?? true
        let item = NSMenuItem(
            title: "Response Preview",
            action: #selector(toggleResponsePreview(_:)),
            keyEquivalent: ""
        )
        item.state = on ? .on : .off
        item.target = self
        return item
    }

    @objc private func toggleResponsePreview(_ sender: NSMenuItem) {
        let current = loadHookConfig()["responsePreviewEnabled"] as? Bool ?? true
        updateHookConfig(["responsePreviewEnabled": !current])
        refreshState()
    }

    @objc private func bannersToggled(_ sender: NSSwitch) {
        let wantOn = sender.state == .on
        updateHookConfig(["bannersEnabled": wantOn])
        // Flipping ON records the intent; if the OS side is missing,
        // immediately walk the user through granting it.
        if wantOn && !notifAuthorized {
            ensureNotificationPermission()
        }
        refreshState()
    }

    // MARK: - Advanced Settings

    private func buildAdvancedMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Advanced Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        sub.addItem(buildSoundMenu())
        sub.addItem(buildResponsePreviewItem())
        sub.addItem(buildSpeedMenu())
        sub.addItem(buildStuckMenu())
        sub.addItem(buildSessionClickMenu())
        sub.addItem(.separator())
        sub.addItem(buildLoginItemEntry())
        sub.addItem(buildAutoUpdateItem())
        sub.addItem(.separator())
        sub.addItem(buildInstallMenu())
        sub.addItem(buildUsageCaptureMenu())

        root.submenu = sub
        return root
    }

    private func buildAutoUpdateItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Automatically Check for Updates",
            action: #selector(toggleAutoUpdate(_:)),
            keyEquivalent: ""
        )
        item.state = autoUpdateEnabled() ? .on : .off
        item.target = self
        return item
    }

    @objc private func toggleAutoUpdate(_ sender: NSMenuItem) {
        var settings = loadAppSettings()
        let now = !(settings["autoCheckUpdates"] as? Bool ?? true)
        settings["autoCheckUpdates"] = now
        saveAppSettings(settings)
        // Turning it on gets an immediate check so the menu can react promptly.
        if now { backgroundUpdateCheck() }
    }

    // MARK: - Sound submenu

    private func buildSoundMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Notification Sounds", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cfg = loadHookConfig()
        let muted = cfg["muteAll"] as? Bool ?? false

        for (event, label) in controlledHookEvents {
            let enabled = isEventEnabled(cfg, event: event)
            let item = NSMenuItem(title: label, action: #selector(toggleEvent(_:)), keyEquivalent: "")
            item.state = enabled ? .on : .off
            item.representedObject = event as NSString
            item.target = self
            if muted { item.action = nil }
            sub.addItem(item)
        }
        sub.addItem(.separator())

        for (event, _) in controlledHookEvents {
            let item = NSMenuItem()
            item.view = makeSoundRow(event: event, cfg: cfg)
            sub.addItem(item)
        }
        sub.addItem(.separator())

        let reset = NSMenuItem(
            title: "Reset All Custom Sounds",
            action: #selector(resetAllSounds(_:)),
            keyEquivalent: ""
        )
        reset.target = self
        sub.addItem(reset)

        root.submenu = sub
        return root
    }

    // One row per event: a play icon that auditions the current sound (menu
    // stays open) sharing the line with "Choose … sound…" (opens the picker).
    private func makeSoundRow(event: String, cfg: [String: Any]) -> NSView {
        let width: CGFloat = 330, height: CGFloat = 22
        let row = MenuRowView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let hasSound = resolveSoundPath(event: event, cfg: cfg) != nil

        let iconZone = NSRect(x: 8, y: 0, width: 28, height: height)
        if hasSound {
            row.hotZone = iconZone
            row.hotAction = { [weak self] in self?.previewEventSound(event) }
        }
        row.onClick = { [weak self] in self?.chooseSoundForEvent(event) }

        let icon = NSTextField(labelWithString: "\u{25B6}\u{FE0E}")
        icon.frame = NSRect(x: 14, y: 3, width: 16, height: 16)
        icon.font = NSFont.menuFont(ofSize: 12)
        icon.textColor = hasSound ? .controlAccentColor : .disabledControlTextColor
        row.addSubview(icon)

        let custom = (cfg["soundPaths"] as? [String: Any])?[event] as? String
        let name = custom != nil ? URL(fileURLWithPath: custom!).lastPathComponent : "Default"
        let text = NSTextField(labelWithString: "Choose \(event) sound\u{2026}  (\(name))")
        text.frame = NSRect(x: 38, y: 3, width: width - 48, height: 16)
        text.font = NSFont.menuFont(ofSize: 13)
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        row.addSubview(text)
        return row
    }

    // Resolve the sound the hook would play for this event: custom if set and
    // present, else the system default. Mirrors _resolve_sound_path in the hook.
    private func resolveSoundPath(event: String, cfg: [String: Any]) -> String? {
        let fm = FileManager.default
        if let custom = (cfg["soundPaths"] as? [String: Any])?[event] as? String, !custom.isEmpty {
            let p = (custom as NSString).expandingTildeInPath
            if fm.fileExists(atPath: p) { return p }
        }
        if let def = defaultSoundPaths[event], fm.fileExists(atPath: def) { return def }
        return nil
    }

    private func previewEventSound(_ event: String) {
        let cfg = loadHookConfig()
        guard let path = resolveSoundPath(event: event, cfg: cfg) else { return }
        let volume = cfg["volume"] as? Double ?? 1.0
        previewProcess?.terminate()   // cut off any preview still playing
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        p.arguments = ["-v", String(max(0, min(1, volume))), path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        previewProcess = p
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        updateHookConfig(["volume": sender.doubleValue])
    }

    @objc private func toggleEvent(_ sender: NSMenuItem) {
        guard let event = sender.representedObject as? String else { return }
        var cfg = loadHookConfig()
        var perEvent = cfg["perEventEnabled"] as? [String: Any] ?? [:]
        let current = perEvent[event] as? Bool ?? true
        perEvent[event] = !current
        cfg["perEventEnabled"] = perEvent
        saveHookConfig(cfg)
        refreshState()
    }

    private func chooseSoundForEvent(_ event: String) {
        guard let path = promptSoundFile() else { return }
        if let stored = copySoundIntoAppSupport(src: path, eventName: event) {
            var cfg = loadHookConfig()
            var sp = cfg["soundPaths"] as? [String: Any] ?? [:]
            sp[event] = stored
            cfg["soundPaths"] = sp
            saveHookConfig(cfg)
            refreshState()
        }
    }

    @objc private func resetAllSounds(_ sender: NSMenuItem) {
        var cfg = loadHookConfig()
        cfg["soundPaths"] = [String: Any]()
        saveHookConfig(cfg)
        try? FileManager.default.removeItem(at: appSoundsDir)
        refreshState()
    }

    private func promptSoundFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a sound file"
        panel.allowedContentTypes = [
            .audio, .init(filenameExtension: "aiff")!, .init(filenameExtension: "mp3")!,
            .init(filenameExtension: "wav")!, .init(filenameExtension: "m4a")!,
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let result = panel.runModal()
        return result == .OK ? panel.url?.path : nil
    }

    // MARK: - Speed submenu

    private func buildSpeedMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Animation Speed", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        for (label, interval) in speedPresets {
            let item = NSMenuItem(title: label, action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.representedObject = interval as NSNumber
            item.target = self
            item.state = abs(animFps - interval) < 0.001 ? .on : .off
            sub.addItem(item)
        }

        root.submenu = sub
        return root
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? Double else { return }
        animFps = interval
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: animFps, repeats: true) {
            [weak self] _ in self?.animate()
        }
        var settings = loadAppSettings()
        settings["animFps"] = animFps
        saveAppSettings(settings)
        refreshState()
    }

    // MARK: - Stuck Detection submenu

    private func buildStuckMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Stuck Detection", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let toggle = NSMenuItem(
            title: stuckEnabled ? "On" : "Off",
            action: #selector(toggleStuck(_:)),
            keyEquivalent: ""
        )
        toggle.state = stuckEnabled ? .on : .off
        toggle.target = self
        sub.addItem(toggle)
        sub.addItem(.separator())

        for (label, secs) in stuckPresets {
            let item = NSMenuItem(title: label, action: #selector(setStuckSecs(_:)), keyEquivalent: "")
            item.representedObject = secs as NSNumber
            item.target = self
            item.state = stuckSecs == secs ? .on : .off
            if !stuckEnabled { item.action = nil }
            sub.addItem(item)
        }

        root.submenu = sub
        return root
    }

    @objc private func toggleStuck(_ sender: NSMenuItem) {
        stuckEnabled = !stuckEnabled
        var settings = loadAppSettings()
        settings["stuckEnabled"] = stuckEnabled
        saveAppSettings(settings)
        refreshState()
    }

    @objc private func setStuckSecs(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        stuckSecs = secs
        var settings = loadAppSettings()
        settings["stuckSecs"] = stuckSecs
        saveAppSettings(settings)
        refreshState()
    }

    // MARK: - Session Click Action

    private func buildSessionClickMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "On Session Click", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let orcaOK = orcaAvailable()
        let current = loadAppSettings()["sessionClickAction"] as? String
            ?? (orcaOK ? "orca" : "finder")

        let options: [(id: String, label: String)] = [
            ("orca", orcaOK ? "Switch to Orca Terminal"
                            : "Switch to Orca Terminal  (not found)"),
            ("finder", "Reveal in Finder"),
            ("copy", "Copy Path"),
        ]
        for opt in options {
            let item = NSMenuItem(
                title: opt.label,
                action: #selector(setSessionClickAction(_:)),
                keyEquivalent: ""
            )
            item.representedObject = opt.id as NSString
            item.target = self
            item.state = current == opt.id ? .on : .off
            // Can't switch to an Orca terminal without Orca — disable that row.
            if opt.id == "orca" && !orcaOK { item.action = nil }
            sub.addItem(item)
        }

        root.submenu = sub
        return root
    }

    @objc private func setSessionClickAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var settings = loadAppSettings()
        settings["sessionClickAction"] = id
        saveAppSettings(settings)
    }

    // MARK: - Login Item

    private func buildLoginItemEntry() -> NSMenuItem {
        let enabled = loginItemEnabled()
        let item = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        item.state = enabled ? .on : .off
        item.target = self
        if !loginItemAvailable() { item.action = nil }
        return item
    }

    private func loginItemAvailable() -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        if #available(macOS 13.0, *) { return true }
        return false
    }

    private func loginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                showAlert(title: "MenubarCC", message: "Login item: \(error.localizedDescription)")
            }
            refreshState()
        }
    }

    // MARK: - Install / Uninstall Hook

    private func buildInstallMenu() -> NSMenuItem {
        let installed = hooksAreInstalled()
        let root = NSMenuItem(
            title: installed ? "Hook Management" : "Install Hook",
            action: nil,
            keyEquivalent: ""
        )
        let sub = NSMenu()

        if installed {
            let uninstall = NSMenuItem(
                title: "Uninstall Hook",
                action: #selector(uninstallHookAction(_:)),
                keyEquivalent: ""
            )
            uninstall.target = self
            sub.addItem(uninstall)
        } else {
            let install = NSMenuItem(
                title: "Install Hook",
                action: #selector(installHookAction(_:)),
                keyEquivalent: ""
            )
            install.target = self
            sub.addItem(install)
        }

        root.submenu = sub
        return root
    }

    @objc private func installHookAction(_ sender: NSMenuItem) {
        let (ok, msg) = installHooks()
        showAlert(title: "MenubarCC", message: msg)
        if ok { refreshState() }
    }

    @objc private func uninstallHookAction(_ sender: NSMenuItem) {
        let (ok, msg) = uninstallHooks()
        showAlert(title: "MenubarCC", message: msg)
        if ok { refreshState() }
    }

    // MARK: - Usage Capture (statusline tap for limit gauges)

    private func buildUsageCaptureMenu() -> NSMenuItem {
        let installed = usageCaptureInstalled()
        let root = NSMenuItem(title: "Usage Capture", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let toggle = NSMenuItem(
            title: installed ? "Disable Usage Capture" : "Enable Usage Capture\u{2026}",
            action: installed ? #selector(disableUsageCaptureAction(_:))
                              : #selector(enableUsageCaptureAction(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        sub.addItem(toggle)
        sub.addItem(.separator())

        let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        note.isEnabled = false
        note.attributedTitle = NSAttributedString(
            string: "Shows 5-hour and weekly limits in the menu by\n"
                + "reading them from your statusline. Global sessions\n"
                + "only; open sessions may need a restart.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        sub.addItem(note)

        root.submenu = sub
        return root
    }

    @objc private func enableUsageCaptureAction(_ sender: NSMenuItem) {
        let (ok, msg) = installUsageCapture()
        showAlert(title: "MenubarCC", message: msg)
        if ok { refreshState() }
    }

    @objc private func disableUsageCaptureAction(_ sender: NSMenuItem) {
        let (ok, msg) = uninstallUsageCapture()
        showAlert(title: "MenubarCC", message: msg)
        if ok { refreshState() }
    }

    // MARK: - First-run prompt

    private func firstRunCheck() {
        var cfg = loadAppSettings()
        if cfg["installPromptShown"] as? Bool == true { return }
        if hooksAreInstalled() { return }

        cfg["installPromptShown"] = true
        saveAppSettings(cfg)

        let alert = NSAlert()
        alert.messageText = "Welcome to MenubarCC"
        alert.informativeText =
            "MenubarCC can install a small hook into Claude Code so the menu bar " +
            "can control notification sounds and show when Claude is waiting for " +
            "your input. You can also do this later from Advanced Settings."
        alert.addButton(withTitle: "Install Hook")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            let (_, msg) = installHooks()
            showAlert(title: "MenubarCC", message: msg)
            refreshState()
        }

        // Ask for notification permission while the user is still engaged
        // with the onboarding dialogs — a cold-launch prompt gets missed.
        if notifStatus == .notDetermined {
            ensureNotificationPermission()
        }
    }

    // MARK: - Update check

    func autoUpdateEnabled() -> Bool {
        loadAppSettings()["autoCheckUpdates"] as? Bool ?? true
    }

    // Silent look for a newer release; if found, remember it so the menu shows
    // "Update to …". Never prompts or downloads on its own.
    private func backgroundUpdateCheck() {
        guard autoUpdateEnabled() else { return }
        fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, let tag = result?.tag, !tag.isEmpty else { return }
                // The menu is rebuilt on open, so recording the tag is enough for
                // its "Update to …" item to appear next time it's opened.
                self.availableUpdate = compareVersions(tag, "v\(currentVersion())") > 0 ? tag : nil
            }
        }
    }

    @objc private func checkUpdates(_ sender: NSMenuItem) {
        fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async { self?.onUpdateResult(result) }
        }
    }

    // The manual "Check for Updates…" path: reports every outcome out loud.
    private func onUpdateResult(_ result: (tag: String, url: String)?) {
        let current = currentVersion()
        guard let result = result else {
            showAlert(title: "MenubarCC",
                      message: "Could not reach GitHub. Check your network connection.")
            return
        }
        guard !result.tag.isEmpty else {
            showAlert(title: "MenubarCC",
                      message: "GitHub returned no release info. Try again later.")
            return
        }
        if compareVersions(result.tag, "v\(current)") <= 0 {
            availableUpdate = nil
            showAlert(title: "MenubarCC", message: "You're up to date (v\(current)).")
            return
        }
        availableUpdate = result.tag
        confirmAndApply(tag: result.tag)
    }


    private func confirmAndApply(tag: String) {
        let alert = NSAlert()
        alert.messageText = "MenubarCC \(tag) is available"
        alert.informativeText =
            "You're on v\(currentVersion()). Download and install it now? " +
            "MenubarCC will restart automatically."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            applyUpdate(tag: tag)
        }
    }

    private func applyUpdate(tag: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = performUpdate(tag: tag)
            DispatchQueue.main.async {
                if let err = err {
                    self?.showAlert(title: "MenubarCC", message: err)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Quit

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
