import SwiftUI
import AppKit

@main
struct FConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup(id: "mainWindow") {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 600)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    /// Keeps App Nap from stretching the fan-control timers while the window is hidden.
    private var activityToken: NSObjectProtocol?
    private weak var mainWindow: NSWindow?
    
    private var isLaunchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return false
        }
        return event.eventID == kAEOpenApplication &&
               event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        EventLog.shared.record("F-Connect started")
        setupStatusItem()
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Fan curve control and telemetry polling"
        )
        DeviceManager.shared.start()
        
        let wasAutoLaunched = isLaunchedAsLoginItem
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                self.mainWindow = window
                window.delegate = self
                window.isReleasedWhenClosed = false
                
                if wasAutoLaunched {
                    // System boot / login: start silently in status bar, hide window and Dock
                    window.orderOut(nil)
                    NSApp.setActivationPolicy(.accessory)
                } else {
                    // User explicitly opened the app: show window and keep in Dock
                    NSApp.setActivationPolicy(.regular)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        DeviceManager.shared.releaseAllToMotherboard()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        
        button.image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "F-Connect")
        
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }
    
    // MARK: - NSMenuDelegate (live fan speeds and control mode)
    
    /// Menu rows whose text follows the hardware while the menu is open.
    private var liveItems: [(item: NSMenuItem, text: () -> String)] = []
    private var menuRefreshTimer: Timer?
    
    private static let menuFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    
    private func addLiveItem(to menu: NSMenu, indent: Int = 1, text: @escaping () -> String) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.indentationLevel = indent
        item.isEnabled = false
        menu.addItem(item)
        liveItems.append((item, text))
        refresh(item, text)
    }
    
    private func refresh(_ item: NSMenuItem, _ text: () -> String) {
        // Disabled items are drawn grey; keep that, but use digits of equal width so the numbers do not jitter.
        item.attributedTitle = NSAttributedString(string: text(), attributes: [
            .font: Self.menuFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        liveItems.removeAll()
        
        menu.addItem(NSMenuItem(title: "Show F-Connect", action: #selector(showWindow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem.separator())
        
        let manager = DeviceManager.shared
        let controllers = manager.connectedControllers
        
        if controllers.isEmpty {
            let item = NSMenuItem(title: manager.problem.map { "\u{26A0}\u{FE0E} \($0)" } ?? "No controller found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }
        
        for controller in controllers {
            if controllers.count > 1 {
                let header = NSMenuItem(title: controller.deviceName, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            
            if let issue = controller.connectionIssue {
                let item = NSMenuItem(title: "\u{26A0}\u{FE0E} \(issue)", action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                item.isEnabled = false
                menu.addItem(item)
            }
            
            let title = NSMenuItem(title: StatusMenuFormatter.sectionTitle, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            
            for (index, group) in controller.groupStates.enumerated() where !group.isHidden {
                addLiveItem(to: menu) { [weak controller] in
                    guard let controller = controller, index < controller.groupStates.count else { return "" }
                    return StatusMenuFormatter.groupLine(controller.groupStates[index])
                }
            }
            menu.addItem(NSMenuItem.separator())
        }
        
        menu.addItem(NSMenuItem(title: "Quit F-Connect", action: #selector(quitApp), keyEquivalent: "q"))
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for (item, text) in self.liveItems { self.refresh(item, text) }
        }
        // Menus are tracked in the event-tracking run loop mode; the default mode would freeze the numbers while it is open.
        RunLoop.main.add(timer, forMode: .common)
        menuRefreshTimer = timer
    }
    
    func menuDidClose(_ menu: NSMenu) {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }
    
    @objc func showWindow() {
        // Bring to Dock and Cmd+Tab when window is shown
        NSApp.setActivationPolicy(.regular)
        
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            self.mainWindow = window
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - NSWindowDelegate (Close button behavior)
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide window instead of terminating application
        sender.orderOut(nil)
        
        // Immediately remove from Dock and Cmd+Tab when window is closed
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showWindow()
        }
        return true
    }
}
