import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - Constants

private let refreshSecs: TimeInterval = 10
private let defaultAnimFps: Double = 0.12
private let defaultStuckSecs = 600
private let firstRunPromptDelay: TimeInterval = 2.0

let speedPresets: [(label: String, interval: Double)] = [
    ("Very Slow", 0.30), ("Slow", 0.20), ("Normal", 0.12),
    ("Fast", 0.08), ("Very Fast", 0.04),
]

let stuckPresets: [(label: String, secs: Int)] = [
    ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900),
    ("30 minutes", 1800), ("60 minutes", 3600),
]

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var frames: AnimationFrames!
    private var animTimer: Timer?
    private var refreshTimer: Timer?

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

        refreshNotifStatus()
        syncInstalledHookScript()
        startEventsWatcher()

        refreshState()

        DispatchQueue.main.asyncAfter(deadline: .now() + firstRunPromptDelay) {
            [weak self] in self?.firstRunCheck()
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
        sendNotification(title: dir, subtitle: "", body: body)
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
                    body: "Stuck \u{2014} busy for \(formatAge(s.ageSeconds)) with no updates"
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

    private func sendNotification(title: String, subtitle: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        // Group notifications per project in Notification Center
        content.threadIdentifier = title
        let req = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        center.add(req)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        let ss = loadSessions(stuckSecs: stuckSecs, stuckEnabled: stuckEnabled)
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
        let responsePreview = cfg["responsePreviewEnabled"] as? Bool ?? true

        let soundsItem = NSMenuItem()
        soundsItem.view = makeSwitchView(
            title: "Sounds",
            isOn: !muted,
            target: self,
            action: #selector(soundsToggled(_:))
        )
        menu.addItem(soundsItem)

        // The switch shows the EFFECTIVE state: app setting AND OS permission.
        let bannersItem = NSMenuItem()
        bannersItem.view = makeSwitchView(
            title: "Banners",
            isOn: banners && notifAuthorized,
            target: self,
            action: #selector(bannersToggled(_:))
        )
        menu.addItem(bannersItem)

        // Preview the reply's opening in the Stop banner body. Only meaningful
        // while banners are on, but kept as an independent switch like the rest.
        let previewItem = NSMenuItem()
        previewItem.view = makeSwitchView(
            title: "Response Preview",
            isOn: responsePreview,
            target: self,
            action: #selector(responsePreviewToggled(_:))
        )
        menu.addItem(previewItem)

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
            let title = "        \(s.dirName)   \(formatAge(s.ageSeconds))"
            let item = NSMenuItem(
                title: title,
                action: #selector(openSession(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = s.cwd as NSString
            item.toolTip = s.cwd   // full path disambiguates same-named dirs
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    // Clicking a session jumps to its project per the "On Session Click"
    // setting: switch to its Orca terminal, reveal in Finder, or copy the path.
    @objc private func openSession(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String, !cwd.isEmpty else { return }
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
    }

    @objc private func responsePreviewToggled(_ sender: NSSwitch) {
        updateHookConfig(["responsePreviewEnabled": sender.state == .on])
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
        sub.addItem(buildSpeedMenu())
        sub.addItem(buildStuckMenu())
        sub.addItem(buildSessionClickMenu())
        sub.addItem(.separator())
        sub.addItem(buildLoginItemEntry())
        sub.addItem(.separator())
        sub.addItem(buildInstallMenu())

        root.submenu = sub
        return root
    }

    // MARK: - Sound submenu

    private func buildSoundMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Notification Sounds", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let cfg = loadHookConfig()
        let muted = cfg["muteAll"] as? Bool ?? false
        let soundPaths = cfg["soundPaths"] as? [String: Any] ?? [:]

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

        let volume = cfg["volume"] as? Double ?? 1.0
        let volumeItem = NSMenuItem()
        volumeItem.view = makeSliderView(
            title: "Volume",
            value: volume,
            enabled: !muted,
            target: self,
            action: #selector(volumeChanged(_:))
        )
        sub.addItem(volumeItem)
        sub.addItem(.separator())

        for (event, _) in controlledHookEvents {
            let custom = soundPaths[event] as? String
            let suffix = custom != nil ? "  (\(URL(fileURLWithPath: custom!).lastPathComponent))" : "  (Default)"
            let item = NSMenuItem(
                title: "Choose \(event) sound\u{2026}\(suffix)",
                action: #selector(chooseSound(_:)),
                keyEquivalent: ""
            )
            item.representedObject = event as NSString
            item.target = self
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

    @objc private func chooseSound(_ sender: NSMenuItem) {
        guard let event = sender.representedObject as? String else { return }
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

    @objc private func checkUpdates(_ sender: NSMenuItem) {
        fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async { self?.onUpdateResult(result) }
        }
    }

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
            showAlert(title: "MenubarCC", message: "You're up to date (v\(current)).")
            return
        }

        let alert = NSAlert()
        alert.messageText = "MenubarCC \(result.tag) is available"
        alert.informativeText =
            "You're on v\(current). Download and install it now? " +
            "MenubarCC will restart automatically."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            applyUpdate(tag: result.tag)
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
