import AppKit
import ServiceManagement

/// Menu bar UI: status, per-direction toggles, latency, reconnect, open-at-login.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let bridge: Bridge
    private let adb: AdbWatcher
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var menuOpen = false

    init(bridge: Bridge, adb: AdbWatcher) {
        self.bridge = bridge
        self.adb = adb
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuild()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private var connected: Bool {
        let s = bridge.stats
        return s.micConnected || s.speakerConnected
    }

    private func tick() {
        let symbol = connected ? "waveform.circle.fill" : "waveform.circle"
        if item.button?.image?.accessibilityDescription != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            image?.isTemplate = true
            item.button?.image = image
        }
        item.button?.toolTip = connected ? "USB Audio Bridge: connected" : "USB Audio Bridge: waiting for tablet"
        if menuOpen { rebuild() }
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; rebuild() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func rebuild() {
        let s = bridge.stats
        let devices = adb.devices
        menu.removeAllItems()

        let title = NSMenuItem(title: "USB Audio Bridge", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "USB Audio Bridge",
                                                   attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        title.isEnabled = false
        menu.addItem(title)

        if adb.adbPath == nil {
            menu.addItem(info("⚠︎ adb not found (brew install --cask android-platform-tools)"))
        } else if devices.isEmpty {
            menu.addItem(info("○ Waiting for the tablet on USB…"))
        } else {
            for d in devices {
                let state = connected ? "connected" : (d.ready ? "starting app…" : "setting up…")
                menu.addItem(info("● \(d.model) — \(state)"))
                if let note = d.note { menu.addItem(info("   ⚠︎ \(note)")) }
            }
        }
        if let error = s.audioError { menu.addItem(info("⚠︎ \(error)")) }

        menu.addItem(.separator())
        menu.addItem(info("Mic  tablet → \(Bridge.deviceName):  \(describe(s.micConnected, bridge.micEnabled, s.micLevelDb))"))
        menu.addItem(info("Speaker  \(Bridge.deviceName) → tablet:  \(describe(s.speakerConnected, bridge.speakerEnabled, s.speakerLevelDb))"))
        if let rtt = s.rttMs, connected {
            menu.addItem(info(String(format: "Latency  round trip %.1f ms · mic buffer %.0f ms", rtt, s.micBufferMs)))
        }

        menu.addItem(.separator())
        menu.addItem(toggle("Tablet Microphone", bridge.micEnabled, #selector(toggleMic)))
        menu.addItem(toggle("Tablet Speaker", bridge.speakerEnabled, #selector(toggleSpeaker)))
        let reconnect = NSMenuItem(title: "Reconnect Tablet", action: #selector(reconnectTablet), keyEquivalent: "r")
        reconnect.target = self
        menu.addItem(reconnect)
        menu.addItem(toggle("Open at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        let log = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func describe(_ connected: Bool, _ enabled: Bool, _ db: Float) -> String {
        if !enabled { return "off" }
        if !connected { return "waiting" }
        return db <= -89 ? "streaming · silent" : String(format: "streaming · %.0f dB", db)
    }

    private func info(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        return i
    }

    @objc private func toggleMic() { bridge.micEnabled.toggle(); rebuild() }
    @objc private func toggleSpeaker() { bridge.speakerEnabled.toggle(); rebuild() }
    @objc private func reconnectTablet() { adb.reconnect() }
    @objc private func showLog() { NSWorkspace.shared.open(Log.url) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.info("open at login: \(error)")
        }
        rebuild()
    }

    /// Debug aid for screenshots (`--show-menu`): shows the menu near the top-right corner for a few
    /// seconds, even when a menu bar manager hides the status item, then closes it.
    func showForSnapshot(seconds: Double) {
        guard let screen = NSScreen.main else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [menu] in menu.cancelTracking() }
        menuOpen = true
        rebuild()
        let origin = NSPoint(x: screen.visibleFrame.maxX - 460, y: screen.visibleFrame.maxY - 8)
        menu.popUp(positioning: nil, at: origin, in: nil)
        menuOpen = false
    }
}
