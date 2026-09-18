//  SidecarReconnect — a menu bar app that gets a wedged Sidecar session back.
//
//  Lives next to the Screen Mirroring icon in the menu bar. Click it to see
//  whether the iPad is connected and to force a reconnect; it also watches for
//  wake and restores the connection on its own.

import AppKit
import ServiceManagement
import UserNotifications

// MARK: - Menu bar icon

/// SF Symbol names move between releases, so try a few and fall back to text
/// rather than showing an empty menu bar slot.
private func symbol(_ names: [String], description: String) -> NSImage? {
    for name in names {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
            image.isTemplate = true   // so it follows light/dark menu bars
            return image
        }
    }
    return nil
}

private enum Icon {
    static let connected = symbol(
        ["rectangle.on.rectangle.fill", "rectangle.on.rectangle", "display"],
        description: "Sidecar connected")
    static let disconnected = symbol(
        ["rectangle.on.rectangle.slash", "rectangle.on.rectangle", "display"],
        description: "Sidecar disconnected")
    static let working = symbol(
        ["arrow.triangle.2.circlepath", "rectangle.on.rectangle"],
        description: "Reconnecting")
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var pollTimer: Timer?
    private var pulseTimer: Timer?

    /// What the ladder is currently doing, shown at the top of the menu.
    private var currentStep: String?
    /// Only restore a connection the user actually had — don't barge in when
    /// they disconnected on purpose before closing the lid.
    private var wasConnectedBeforeSleep = false
    private var lastAutoRun = Date.distantPast

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Sidecar Reconnect"
        menu.delegate = self
        menu.autoenablesItems = false   // we decide what's enabled, not the responder chain
        statusItem.menu = menu

        registerWakeObservers()
        requestNotificationPermission()

        // A light poll keeps the icon honest when the connection changes
        // behind our back — someone unplugging the cable, say.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
        // A failed or finished Android session should show in the menu bar
        // straight away, not at the next 20s poll.
        AndroidDisplay.shared.onStateChange = { [weak self] state in
            self?.refreshIcon()
            if case .failed(let why) = state { self?.notify(why) }
        }

        AndroidDisplay.shared.restoreIfWasSharing()

        refreshIcon()
        Log.write("SidecarReconnect started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pulseTimer?.invalidate()
    }

    // MARK: Wake handling

    private func registerWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep(_:)),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake(_:)),
                           name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake(_:)),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @objc private func willSleep(_ note: Notification) {
        let connected = Sidecar.connectedDevice()
        wasConnectedBeforeSleep = connected != nil
        Log.write("sleeping (Sidecar was \(wasConnectedBeforeSleep ? "connected" : "idle"))")

        // Close the session ourselves instead of letting sleep cut it off. An
        // iPad found hung the next morning had been left mid-session — the relay
        // logged "Terminated with Active Sessions" — and nothing on the Mac can
        // clear that afterwards, so it's worth spending a moment here.
        //
        // macOS gives us only a short window before it suspends us, and this
        // blocks the main thread, so the timeout is deliberately tight: better
        // to skip the tidy-up than to hold up sleep.
        guard Prefs.disconnectBeforeSleep, let device = connected else { return }
        do {
            try Sidecar.disconnect(device, timeout: 4)
            Log.write("closed the session cleanly before sleeping")
        } catch {
            Log.write("couldn't close the session before sleeping: \(error.localizedDescription)")
        }
    }

    @objc private func didWake(_ note: Notification) {
        guard Prefs.autoReconnectOnWake else { return }
        guard wasConnectedBeforeSleep else {
            Log.write("woke, but Sidecar was idle before sleep — leaving it alone")
            return
        }
        // Wake and screens-wake usually both fire; don't run the ladder twice.
        guard Date().timeIntervalSince(lastAutoRun) > 60 else { return }
        lastAutoRun = Date()

        let delay = Prefs.wakeDelay
        Log.write("woke — waiting \(Int(delay))s for USB and Bluetooth to settle")
        setWorking(true, step: "waiting for the Mac to settle")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            if Sidecar.connectedDevice() != nil {
                Log.write("reconnected on its own, nothing to do")
                self.setWorking(false)
                return
            }
            self.reconnect(reason: "after wake", announceSuccess: true)
        }
    }

    // MARK: Running the ladder

    private func reconnect(reason: String, announceSuccess: Bool) {
        setWorking(true, step: "starting")
        Recovery.shared.run(reason: reason) { [weak self] step in
            self?.setWorking(true, step: step)
        } completion: { [weak self] outcome in
            guard let self = self else { return }
            self.setWorking(false)
            self.refreshIcon()
            switch outcome {
            case .alreadyConnected:
                if announceSuccess == false { self.notify("Already connected.") }
            case .connected:
                if announceSuccess { self.notify(outcome.summary) }
            case .failed:
                self.notify(outcome.summary)
            case .deviceUnresponsive:
                // Always worth saying, even on an automatic run: this is the one
                // outcome where the user has to do something we can't do for them.
                self.notify(outcome.summary)
            }
        }
    }

    // MARK: Icon state

    private func setWorking(_ working: Bool, step: String? = nil) {
        currentStep = working ? step : nil
        guard let button = statusItem.button else { return }

        if working {
            button.image = Icon.working
            if pulseTimer == nil {
                pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak button] _ in
                    guard let button = button else { return }
                    button.alphaValue = button.alphaValue > 0.7 ? 0.35 : 1.0
                }
            }
        } else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            button.alphaValue = 1.0
            refreshIcon()
        }
    }

    private func refreshIcon() {
        guard let button = statusItem.button, currentStep == nil else { return }
        let connected = Sidecar.connectedDevice()
        button.image = connected != nil ? Icon.connected : Icon.disconnected
        // Never leave the slot blank if every symbol lookup failed.
        if button.image == nil { button.title = connected != nil ? "▣" : "▢" }
        button.toolTip = connected.map { "Sidecar: connected to \($0.name)" }
            ?? "Sidecar: not connected"
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        // Header: what's going on right now.
        let devices = Sidecar.devices()
        let connected = devices.first { $0.connected == true }
        let header: String
        if let step = currentStep {
            header = "Reconnecting — \(step)"
        } else if let connected = connected {
            header = "Connected — \(connected.name)"
        } else if devices.isEmpty {
            header = "No iPad visible"
        } else if devices.contains(where: { $0.connected == nil }) {
            // Be honest when macOS gave us no way to tell.
            header = "\(devices[0].name) — state unknown"
        } else {
            header = "Not connected — \(devices[0].name) available"
        }
        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())

        let busy = Recovery.shared.isRunning
        add(menu, "Reconnect Now", #selector(reconnectNow), key: "r", enabled: !busy)
        add(menu, "Bounce Connection", #selector(bounceNow), enabled: !busy && connected != nil)
        add(menu, "Disconnect", #selector(disconnectNow), enabled: !busy && connected != nil)

        if devices.count > 1 {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "iPad", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let autoItem = NSMenuItem(title: "Whichever is available",
                                      action: #selector(pickDevice(_:)), keyEquivalent: "")
            autoItem.target = self
            autoItem.representedObject = ""
            autoItem.state = Prefs.device.isEmpty ? .on : .off
            submenu.addItem(autoItem)
            submenu.addItem(.separator())
            for device in devices {
                let deviceItem = NSMenuItem(title: device.name,
                                            action: #selector(pickDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = device.name
                deviceItem.state = Prefs.device == device.name ? .on : .off
                submenu.addItem(deviceItem)
            }
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Android tablet. A separate engine entirely — macOS gives us nothing
        // here, so the app creates the display and streams it itself.
        let android = AndroidDisplay.shared
        let androidStatus = NSMenuItem(title: android.state.summary, action: nil, keyEquivalent: "")
        androidStatus.isEnabled = false
        menu.addItem(androidStatus)

        // The address and one-time code to type into the tablet. Shown only
        // while we're waiting for one — it disappears the moment it connects.
        if let pairing = android.pairing {
            // A tablet that's paired before comes back on its own token — tell
            // the user to hit Reconnect rather than retyping a code.
            if let known = android.knownDevices.first {
                let hint = NSMenuItem(
                    title: "  \(known) is paired — tap Reconnect on the tablet",
                    action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
            let title = android.knownDevices.isEmpty
                ? pairing.instruction
                : "Pair another tablet: \(pairing.instruction)"
            let item = NSMenuItem(title: title,
                                  action: #selector(copyPairingDetails), keyEquivalent: "")
            item.target = self
            item.toolTip = "Click to copy. Enter these in the Side Screen app on your tablet."
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
            menu.addItem(item)
        }
        add(menu, android.isRunning ? "Stop Sharing to Android Tablet"
                                    : "Share Screen to Android Tablet…",
            #selector(toggleAndroidDisplay))

        // Live throughput, so "it feels laggy" can be checked against numbers.
        if let t = android.throughput {
            let item = NSMenuItem(title: String(format: "  %.0f fps · %.1f Mbps", t.fps, t.mbps),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let quality = NSMenu()
        quality.autoenablesItems = false
        for rate in [24, 30, 45, 60] {
            let item = NSMenuItem(title: "\(rate) fps", action: #selector(pickFrameRate(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = rate
            item.state = Prefs.androidFrameRate == rate ? .on : .off
            quality.addItem(item)
        }
        quality.addItem(.separator())
        for mbps in [8, 12, 20, 30] {
            let item = NSMenuItem(title: "\(mbps) Mbps", action: #selector(pickBitrate(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mbps
            item.state = Prefs.androidBitrate == mbps ? .on : .off
            quality.addItem(item)
        }
        // Sizes are the *logical* desktop. The tablet's panel is fixed, so a
        // smaller desktop simply means everything on it is drawn bigger — which
        // is what "the text is too small" actually needs, not a lower bitrate.
        let sizes = NSMenu()
        sizes.autoenablesItems = false
        let presets: [(String, Int, Int)] = [
            ("1920 × 1200  (smallest text)", 1920, 1200),
            ("1680 × 1050", 1680, 1050),
            ("1440 × 900", 1440, 900),
            ("1280 × 800  (bigger text)", 1280, 800),
            ("1024 × 640  (biggest text)", 1024, 640),
        ]
        for (label, w, h) in presets {
            let item = NSMenuItem(title: label, action: #selector(pickResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [w, h]
            item.state = (Prefs.androidWidth == w && Prefs.androidHeight == h) ? .on : .off
            sizes.addItem(item)
        }
        sizes.addItem(.separator())
        let crisp = NSMenuItem(title: "Sharper text (Retina)",
                               action: #selector(toggleAndroidHiDPI), keyEquivalent: "")
        crisp.target = self
        crisp.state = Prefs.androidHiDPI ? .on : .off
        crisp.toolTip = "Renders at double the size and scales down. Sharper, "
            + "but four times the pixels for the tablet to decode."
        sizes.addItem(crisp)
        // Every screen macOS currently has — the iPad over Sidecar, an HDMI
        // monitor and the Android tablet all live in the same coordinate space,
        // so they can all be arranged from here.
        let screens = DisplayArrangement.all()
        let arrange = NSMenu()
        arrange.autoenablesItems = false
        for screen in screens {
            if screen.isMain {
                let item = NSMenuItem(title: screen.summary, action: nil, keyEquivalent: "")
                item.isEnabled = false
                arrange.addItem(item)
                continue
            }
            let sides = NSMenu()
            sides.autoenablesItems = false
            for anchor in screens where anchor.id != screen.id {
                for side in DisplayArrangement.Side.allCases {
                    let item = NSMenuItem(title: "\(side.label) \(anchor.name)",
                                          action: #selector(moveDisplay(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = [
                        "move": NSNumber(value: screen.id),
                        "anchor": NSNumber(value: anchor.id),
                        "side": side.rawValue,
                    ] as [String: Any]
                    sides.addItem(item)
                }
            }
            let item = NSMenuItem(title: screen.summary, action: nil, keyEquivalent: "")
            item.submenu = sides
            arrange.addItem(item)
        }
        if screens.count < 2 {
            let none = NSMenuItem(title: "Only one screen connected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            arrange.addItem(none)
        }
        let arrangeItem = NSMenuItem(title: "Arrange Displays", action: nil, keyEquivalent: "")
        arrangeItem.submenu = arrange
        menu.addItem(arrangeItem)

        let sizesItem = NSMenuItem(title: "Tablet Resolution", action: nil, keyEquivalent: "")
        sizesItem.submenu = sizes
        menu.addItem(sizesItem)

        let qualityItem = NSMenuItem(title: "Tablet Quality", action: nil, keyEquivalent: "")
        qualityItem.submenu = quality
        menu.addItem(qualityItem)

        menu.addItem(.separator())

        add(menu, "Reconnect Automatically After Wake",
            #selector(toggleAutoReconnect), state: Prefs.autoReconnectOnWake)

        let sleepItem = NSMenuItem(title: "Disconnect Cleanly Before Sleep",
                                   action: #selector(toggleCleanDisconnect), keyEquivalent: "")
        sleepItem.target = self
        sleepItem.state = Prefs.disconnectBeforeSleep ? .on : .off
        sleepItem.toolTip = "Closes the session before the Mac sleeps, so the iPad "
            + "isn't left holding one it can't clear."
        menu.addItem(sleepItem)

        let connectionItem = NSMenuItem(title: "Connection", action: nil, keyEquivalent: "")
        let connectionMenu = NSMenu()
            connectionMenu.autoenablesItems = false
        for transport in Transport.allCases {
            let item = NSMenuItem(title: transport.label,
                                  action: #selector(pickTransport(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = transport.rawValue
            item.state = Prefs.transport == transport ? .on : .off
            connectionMenu.addItem(item)
        }
        connectionItem.submenu = connectionMenu
        menu.addItem(connectionItem)

        let extrasItem = NSMenuItem(title: "Extra Fixes", action: nil, keyEquivalent: "")
        let extras = NSMenu()
            extras.autoenablesItems = false
        let btItem = NSMenuItem(title: "Bounce Bluetooth If Needed",
                                action: #selector(toggleBluetooth), keyEquivalent: "")
        btItem.target = self
        btItem.state = Prefs.bounceBluetooth ? .on : .off
        btItem.toolTip = "Drops Bluetooth keyboards and mice for a few seconds. Needs blueutil."
        extras.addItem(btItem)

        let uiItem = NSMenuItem(title: "Fall Back To Control Center",
                                action: #selector(toggleUIFallback), keyEquivalent: "")
        uiItem.target = self
        uiItem.state = Prefs.uiFallback ? .on : .off
        uiItem.toolTip = "Clicks through Control Center. Needs Accessibility permission."
        extras.addItem(uiItem)
        extrasItem.submenu = extras
        menu.addItem(extrasItem)

        add(menu, "Show Notifications", #selector(toggleNotify), state: Prefs.notify)
        add(menu, "Open at Login", #selector(toggleLoginItem), state: isLoginItemEnabled)

        menu.addItem(.separator())

        let activityItem = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
        let activity = NSMenu()
            activity.autoenablesItems = false
        let lines = Log.tail(15)
        if lines.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            activity.addItem(empty)
        } else {
            for line in lines.reversed() {
                let entry = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                entry.attributedTitle = NSAttributedString(
                    string: line,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)])
                activity.addItem(entry)
            }
        }
        activity.addItem(.separator())
        let openLog = NSMenuItem(title: "Open Log File…", action: #selector(openLog), keyEquivalent: "")
        openLog.target = self
        activity.addItem(openLog)
        activityItem.submenu = activity
        menu.addItem(activityItem)

        add(menu, "Copy Diagnostics", #selector(copyDiagnostics))

        menu.addItem(.separator())
        add(menu, "Quit SidecarReconnect", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     key: String = "", enabled: Bool = true, state: Bool? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        if let state = state { item.state = state ? .on : .off }
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func reconnectNow() { reconnect(reason: "menu", announceSuccess: true) }

    @objc private func bounceNow() {
        setWorking(true, step: "bouncing")
        DispatchQueue.global().async { [weak self] in
            if let device = try? Sidecar.resolve(Prefs.device.isEmpty ? nil : Prefs.device) {
                try? Sidecar.disconnect(device)
                Thread.sleep(forTimeInterval: 2)
            }
            DispatchQueue.main.async {
                self?.setWorking(false)
                self?.reconnect(reason: "menu bounce", announceSuccess: true)
            }
        }
    }

    @objc private func disconnectNow() {
        DispatchQueue.global().async { [weak self] in
            var message = "Disconnected."
            do {
                let device = try Sidecar.resolve(Prefs.device.isEmpty ? nil : Prefs.device)
                try Sidecar.disconnect(device)
                Log.write("disconnected \(device.name) from the menu")
            } catch {
                message = error.localizedDescription
                Log.write("disconnect failed: \(message)")
            }
            DispatchQueue.main.async {
                self?.refreshIcon()
                self?.notify(message)
            }
        }
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        Prefs.device = sender.representedObject as? String ?? ""
    }

    @objc private func pickTransport(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let transport = Transport(rawValue: raw) {
            Prefs.transport = transport
        }
    }

    @objc private func toggleAutoReconnect() { Prefs.autoReconnectOnWake.toggle() }
    @objc private func toggleCleanDisconnect() { Prefs.disconnectBeforeSleep.toggle() }

    /// Quality changes only take effect on a fresh session — the virtual
    /// display's refresh rate and the encoder are both fixed at start-up — so
    /// restart one that's already running rather than silently doing nothing.
    private func restartAndroidIfRunning() {
        let android = AndroidDisplay.shared
        guard android.isRunning else { return }
        android.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { android.start() }
        notify("Restarting the Android display with the new settings…")
    }

    @objc private func pickFrameRate(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Int else { return }
        Prefs.androidFrameRate = rate
        restartAndroidIfRunning()
    }

    @objc private func pickBitrate(_ sender: NSMenuItem) {
        guard let mbps = sender.representedObject as? Int else { return }
        Prefs.androidBitrate = mbps
        restartAndroidIfRunning()
    }

    @objc private func moveDisplay(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let moving = (info["move"] as? NSNumber)?.uint32Value,
              let anchor = (info["anchor"] as? NSNumber)?.uint32Value,
              let raw = info["side"] as? String,
              let side = DisplayArrangement.Side(rawValue: raw) else { return }
        DisplayArrangement.place(moving, side, of: anchor)
        // Remember it for the tablet specifically: macOS forgets a virtual
        // display's place, so we reapply it whenever the session starts.
        if moving == AndroidDisplay.shared.displayID,
           let remembered = AndroidDisplay.Arrangement(rawValue: raw) {
            Prefs.androidArrangement = remembered.rawValue
        }
    }

    @objc private func pickResolution(_ sender: NSMenuItem) {
        guard let wh = sender.representedObject as? [Int], wh.count == 2 else { return }
        Prefs.androidWidth = wh[0]
        Prefs.androidHeight = wh[1]
        restartAndroidIfRunning()
    }

    @objc private func toggleAndroidHiDPI() {
        Prefs.androidHiDPI.toggle()
        restartAndroidIfRunning()
    }

    @objc private func copyPairingDetails() {
        guard let pairing = AndroidDisplay.shared.pairing else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(pairing.address):\(pairing.port)", forType: .string)
        notify("Copied \(pairing.address):\(pairing.port) — code \(PairingCode.display(pairing.code))")
    }

    @objc private func toggleAndroidDisplay() {
        let android = AndroidDisplay.shared
        if android.isRunning {
            android.stop()
        } else {
            android.start()
            // Starting is asynchronous and the first run usually trips a
            // permission prompt, so tell the user where to watch.
            notify("Starting the Android display — open the Side Screen app on your tablet.")
        }
    }
    @objc private func toggleNotify() { Prefs.notify.toggle() }
    @objc private func toggleUIFallback() { Prefs.uiFallback.toggle() }

    @objc private func toggleBluetooth() {
        let turningOn = !Prefs.bounceBluetooth
        if turningOn, !FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/blueutil"),
           !FileManager.default.isExecutableFile(atPath: "/usr/local/bin/blueutil") {
            let alert = NSAlert()
            alert.messageText = "blueutil isn't installed"
            alert.informativeText = """
                This fix toggles Bluetooth off and on, which needs the blueutil \
                command line tool:

                    brew install blueutil

                It will also disconnect Bluetooth keyboards and mice for a few seconds.
                """
            alert.addButton(withTitle: "Enable Anyway")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Prefs.bounceBluetooth = turningOn
    }

    private var isLoginItemEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else {
            showLoginItemFallback("This needs macOS 13 or later.")
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Registration can be refused for an unsigned build; say so plainly
            // instead of silently doing nothing.
            showLoginItemFallback(error.localizedDescription)
        }
    }

    private func showLoginItemFallback(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't change the login item"
        alert.informativeText = """
            \(reason)

            You can add it by hand: System Settings › General › Login Items, \
            then add SidecarReconnect under “Open at Login”.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Log.fileURL.path) {
            try? "".write(to: Log.fileURL, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func copyDiagnostics() {
        var report = "SidecarReconnect diagnostics\n"
        report += "date: \(Date())\n"
        report += "device pref: \(Prefs.device.isEmpty ? "<auto>" : Prefs.device)\n"
        report += "transport: \(Prefs.transport.rawValue)\n"
        report += "auto-reconnect: \(Prefs.autoReconnectOnWake)\n"
        report += "bluetooth bounce: \(Prefs.bounceBluetooth), UI fallback: \(Prefs.uiFallback)\n\n"

        report += "devices:\n"
        let devices = Sidecar.devices()
        if devices.isEmpty {
            report += "  (none visible)\n"
        } else {
            for device in devices {
                let state = device.connected.map { $0 ? "connected" : "disconnected" } ?? "unknown"
                report += "  \(device.name) — \(state)\n"
            }
        }

        report += "\nlaunchd agents:\n"
        let listing = shell("/bin/launchctl", ["list"]).output
        for line in listing.split(separator: "\n") where
            line.range(of: "sidecar|airplay|AMPDeviceDiscovery|rapport",
                       options: [.regularExpression, .caseInsensitive]) != nil {
            report += "  \(line)\n"
        }

        report += "\nrecent log:\n"
        report += Log.tail(30).map { "  \($0)" }.joined(separator: "\n")
        report += "\n\nprivate API:\n" + Sidecar.dump()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        notify("Diagnostics copied to the clipboard.")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notify(_ message: String) {
        Log.write(message)
        guard Prefs.notify, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sidecar"
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()
