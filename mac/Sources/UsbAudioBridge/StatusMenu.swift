import AppKit
import ServiceManagement

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Menu bar UI: status, per-direction toggles, latency, reconnect, open-at-login.
///
/// The menu is built once and its rows are updated in place twice a second while it is open; it is
/// rebuilt only when rows appear or disappear (a tablet attaches, a warning shows up). Rebuilding on
/// every tick dropped the highlight under the pointer, and live numbers in the proportional menu font
/// made the menu change width as they changed length, so numbers use tabular digits padded to a fixed
/// width.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let bridge: Bridge
    private let adb: AdbWatcher
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var menuOpen = false
    private var rowKeys: [String] = []

    private struct Row {
        enum Kind { case title, info, separator, toggle(Bool, Selector), action(Selector, String), quit }
        let key: String
        let kind: Kind
        let text: String
    }

    init(bridge: Bridge, adb: AdbWatcher) {
        self.bridge = bridge
        self.adb = adb
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
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
        item.button?.toolTip = L(connected ? "USB Audio Bridge: connected" : "USB Audio Bridge: waiting for the tablet")
        if menuOpen { refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; refresh() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func rows() -> [Row] {
        let s = bridge.stats
        let devices = adb.devices
        var rows: [Row] = [Row(key: "title", kind: .title, text: L("USB Audio Bridge"))]

        if adb.adbPath == nil {
            rows.append(Row(key: "adb-missing", kind: .info, text: "⚠︎ " + L("adb not found (brew install --cask android-platform-tools)")))
        } else if devices.isEmpty {
            rows.append(Row(key: "waiting", kind: .info, text: "○ " + L("Waiting for the tablet on USB…")))
        } else {
            for d in devices {
                let state = L(connected ? "connected" : (d.ready ? "starting the app…" : "setting up…"))
                rows.append(Row(key: "device-\(d.serial)", kind: .info, text: "● \(d.model) — \(state)"))
                if let note = d.note { rows.append(Row(key: "note-\(d.serial)", kind: .info, text: "   ⚠︎ " + L(note))) }
            }
        }
        if let error = s.audioError { rows.append(Row(key: "audio-error", kind: .info, text: "⚠︎ \(error)")) }

        rows.append(Row(key: "sep-status", kind: .separator, text: ""))
        rows.append(Row(key: "mic", kind: .info, text: String(format: L("Microphone (tablet → %@): %@"), Bridge.deviceName,
                                                               describe(s.micConnected, bridge.micEnabled, s.micLevelDb))))
        rows.append(Row(key: "speaker", kind: .info, text: String(format: L("Speaker (%@ → tablet): %@"), Bridge.deviceName,
                                                                   describe(s.speakerConnected, bridge.speakerEnabled, s.speakerLevelDb))))
        if let rtt = s.rttMs, connected {
            rows.append(Row(key: "latency", kind: .info, text: String(format: L("Round trip %@ ms · mic buffer %@ ms"),
                                                                       fixed(String(format: "%.1f", rtt), 4), fixed(String(format: "%.0f", s.micBufferMs), 2))))
        }
        let mode = L(["on": "always", "off": "never"][EchoGate.mode] ?? "automatic")
        rows.append(Row(key: "echo", kind: .info, text: String(format: L(s.echoCancelling ? "Echo cancellation: on (%@)" : "Echo cancellation: off (%@)"), mode)))

        rows.append(Row(key: "sep-controls", kind: .separator, text: ""))
        rows.append(Row(key: "toggle-mic", kind: .toggle(bridge.micEnabled, #selector(toggleMic)), text: L("Tablet Microphone")))
        rows.append(Row(key: "toggle-speaker", kind: .toggle(bridge.speakerEnabled, #selector(toggleSpeaker)), text: L("Tablet Speaker")))
        rows.append(Row(key: "reconnect", kind: .action(#selector(reconnectTablet), "r"), text: L("Reconnect Tablet")))
        rows.append(Row(key: "login", kind: .toggle(SMAppService.mainApp.status == .enabled, #selector(toggleLogin)), text: L("Open at Login")))
        rows.append(Row(key: "log", kind: .action(#selector(showLog), ""), text: L("Show Log")))
        rows.append(Row(key: "sep-quit", kind: .separator, text: ""))
        rows.append(Row(key: "quit", kind: .quit, text: L("Quit USB Audio Bridge")))
        return rows
    }

    private func refresh() {
        let rows = rows()
        let keys = rows.map(\.key)
        if keys != rowKeys {
            rowKeys = keys
            menu.removeAllItems()
            rows.forEach { menu.addItem(makeItem($0)) }
            return
        }
        for (index, row) in rows.enumerated() {
            guard let item = menu.item(at: index) else { continue }
            switch row.kind {
            case .info:
                if item.title != row.text { item.attributedTitle = infoTitle(row.text) }
            case .toggle(let on, _):
                item.state = on ? .on : .off
            default:
                break
            }
        }
    }

    private func makeItem(_ row: Row) -> NSMenuItem {
        switch row.kind {
        case .separator:
            return .separator()
        case .title:
            let i = NSMenuItem(title: row.text, action: nil, keyEquivalent: "")
            i.attributedTitle = NSAttributedString(string: row.text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            i.isEnabled = false
            return i
        case .info:
            let i = NSMenuItem(title: row.text, action: nil, keyEquivalent: "")
            i.attributedTitle = infoTitle(row.text)
            i.isEnabled = false
            return i
        case .toggle(let on, let action):
            let i = NSMenuItem(title: row.text, action: action, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            return i
        case .action(let action, let key):
            let i = NSMenuItem(title: row.text, action: action, keyEquivalent: key)
            i.target = self
            return i
        case .quit:
            return NSMenuItem(title: row.text, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }
    }

    private func infoTitle(_ text: String) -> NSAttributedString {
        let size = NSFont.menuFont(ofSize: 0).pointSize
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular),
            .foregroundColor: NSColor.disabledControlTextColor,
        ])
    }

    /// Right-aligns a number to `width` characters with figure spaces, which are as wide as a tabular digit.
    private func fixed(_ number: String, _ width: Int) -> String {
        String(repeating: "\u{2007}", count: max(0, width - number.count)) + number
    }

    private func describe(_ connected: Bool, _ enabled: Bool, _ db: Float) -> String {
        if !enabled { return L("off") }
        if !connected { return L("waiting") }
        if db <= -89 { return L("streaming · silent") }
        return String(format: L("streaming · %@ dB"), fixed(String(format: "%.0f", db), 3))
    }

    @objc private func toggleMic() { bridge.micEnabled.toggle(); refresh() }
    @objc private func toggleSpeaker() { bridge.speakerEnabled.toggle(); refresh() }
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
        refresh()
    }

    /// Debug aid for screenshots (`--show-menu`): shows the menu near the top-right corner for a few
    /// seconds, even when a menu bar manager hides the status item, then closes it.
    func showForSnapshot(seconds: Double) {
        guard let screen = NSScreen.main else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [menu] in menu.cancelTracking() }
        menuOpen = true
        refresh()
        let origin = NSPoint(x: screen.visibleFrame.maxX - 460, y: screen.visibleFrame.maxY - 8)
        menu.popUp(positioning: nil, at: origin, in: nil)
        menuOpen = false
    }
}
