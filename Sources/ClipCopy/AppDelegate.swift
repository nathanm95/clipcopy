import AppKit
import ServiceManagement

/// Command-line options. Normal use takes none; the rest are for testing.
struct LaunchOptions {
    var dataDirectory = LaunchOptions.defaultDataDirectory
    var usesCustomDataDirectory = false
    var menuTest = false

    static var defaultDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipCopy", isDirectory: true)
    }

    init(arguments: [String]) {
        if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
            dataDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            usesCustomDataDirectory = true
        }
        menuTest = arguments.contains("--menu-test")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private var store: ClipStore?
    private var watcher: ClipboardWatcher?
    private var dropdown: DropdownController?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !options.usesCustomDataDirectory, anotherCopyIsRunning() {
            NSApp.terminate(nil)
            return
        }

        let store: ClipStore
        do {
            store = try ClipStore(directory: options.dataDirectory)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "ClipCopy can't open its history"
            alert.informativeText = "\(options.dataDirectory.path)\n\n\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.store = store

        // The menu test leaves the real clipboard alone.
        if !options.menuTest {
            let watcher = ClipboardWatcher(store: store)
            watcher.start()
            self.watcher = watcher
        }
        let dropdown = DropdownController(store: store, watcher: watcher)
        self.dropdown = dropdown

        if !options.usesCustomDataDirectory {
            LoginItem.enableOnFirstLaunch()
        }
        if options.menuTest {
            MenuTest.run(dropdown)
        }
    }

    private func anotherCopyIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != ownPID }
    }
}

/// Starting ClipCopy at login, through the system's login items.
enum LoginItem {
    private static let setUpKey = "didSetUpLoginItem"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClipCopy: couldn't change the login item: \(error)")
        }
    }

    /// Turns "Open at Login" on the first time ClipCopy runs. After that it's left to the menu toggle.
    static func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: setUpKey) else { return }
        UserDefaults.standard.set(true, forKey: setUpKey)
        setEnabled(true)
    }
}
