import AppKit
import MandroidKit
import Observation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        if UserDefaults.standard.string(forKey: "uiTestControlDirectory") != nil, !UITestMode.enabled {
            fatalError("Offscreen UI tests require a Debug build")
        }
        migrateFromPreviousNames()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(UITestMode.enabled ? .prohibited : .regular)
        app.run()
    }

    let coordinator = RunnerCoordinator()

    /// Move user data only after the previous app has released its emulator.
    private static func migrateFromPreviousNames() {
        guard SDKPaths.overrideRoot == nil else { return }
        if let oldApp = AppMigration.legacyBundleIDs.flatMap({
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }).first {
            let alert = NSAlert()
            alert.messageText = "Quit the previous app first"
            alert.informativeText = "Mandroid replaces Madroid and Android App Runner. Quit \(oldApp.localizedName ?? "the previous app") so its data can be migrated, then open Mandroid again."
            alert.runModal()
            exit(0)
        }
        do {
            if let old = try AppMigration.migrateData(in: SDKPaths.applicationSupport) {
                Log.file("migrated data from \(old.lastPathComponent)")
            }
            AppMigration.migratePreferences(.standard)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not migrate app data"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }
    private(set) lazy var windows = WindowManager(coordinator: coordinator)
    private var setupWindow: SetupWindowController?
    private var libraryWindow: LibraryWindowController?
    private var settingsWindow: SettingsWindowController?
    private var stateObservation: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !UITestMode.enabled { coordinator.hostClipboard = PasteboardClipboard() }
        NSApp.mainMenu = MainMenu.build(delegate: self)
        if !UITestMode.enabled { NSApp.activate(ignoringOtherApps: true) }
        if UITestMode.enabled { Task { await UITestMode.receiveCommands(delegate: self) } }
        observeState()
        observeApps()
        coordinator.start()
    }

    /// Re-evaluates which top-level window should be visible whenever the
    /// coordinator state changes.
    private var appsObservation: Task<Void, Never>?

    private func observeApps() {
        appsObservation = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let apps = withObservationTracking { self.coordinator.apps } onChange: {}
                if !UITestMode.enabled, self.coordinator.state.isReady, UserDefaults.standard.object(forKey: "launcherStubs") as? Bool ?? true {
                    LauncherStubBuilder.sync(apps)
                }
                await withCheckedContinuation { cont in
                    withObservationTracking { _ = self.coordinator.apps } onChange: { cont.resume() }
                }
            }
        }
    }

    private func observeState() {
        stateObservation = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let state = withObservationTracking { self.coordinator.state } onChange: {}
                self.apply(state)
                await withCheckedContinuation { cont in
                    withObservationTracking { _ = self.coordinator.state } onChange: { cont.resume() }
                }
            }
        }
    }

    private func apply(_ state: RunnerState) {
        switch state {
        case .ready:
            setupWindow?.close(); setupWindow = nil
            showLibrary()
        case .idle:
            break
        default:
            libraryWindow?.close(); libraryWindow = nil
            windows.closeAll()
            showSetup()
        }
    }

    private func showSetup() {
        if setupWindow == nil { setupWindow = SetupWindowController(coordinator: coordinator) }
        if !UITestMode.enabled { setupWindow?.showWindow(nil) }
    }

    @objc func showLibrary() {
        if libraryWindow == nil { libraryWindow = LibraryWindowController(coordinator: coordinator, windows: windows) }
        if !UITestMode.enabled {
            libraryWindow?.showWindow(nil)
            libraryWindow?.window?.makeKeyAndOrderFront(nil)
        }
    }

    @objc func showDeviceScreen(_ sender: Any?) { windows.showDeviceScreen() }
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(coordinator: coordinator, windows: windows) }
        if !UITestMode.enabled {
            settingsWindow?.showWindow(nil)
            settingsWindow?.window?.makeKeyAndOrderFront(nil)
        }
    }
    @objc func restartEmulator(_ sender: Any?) {
        windows.closeAll()
        Task { await coordinator.restart() }
    }
    @objc func deleteEmulator(_ sender: Any?) {
        EmulatorDeletion.confirm(coordinator: coordinator, windows: windows)
    }
    @objc func coldBootEmulator(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Cold boot the emulator?"
        alert.informativeText = "Running apps will be closed and Android will boot from scratch instead of restoring the saved snapshot. Installed apps and data are kept."
        alert.addButton(withTitle: "Cold Boot")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        windows.closeAll()
        Task { await coordinator.restart(coldBoot: true) }
    }
    @objc func openPlayStore(_ sender: Any?) {
        Task { await coordinator.openPlayStore() }
        windows.showDeviceScreen()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if coordinator.state.isReady { showLibrary() } else { showSetup() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            #if DEBUG
            await DebugHooks.finishRecording()
            #endif
            windows.closeAll()
            await coordinator.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL, url.pathExtension.lowercased() == "apk" {
                URLSchemeHandler(delegate: self).whenReady {
                    Task {
                        do { try await self.coordinator.installAPK(url) }
                        catch { self.windows.presentError(error, title: "Install failed") }
                    }
                }
            } else if url.scheme == "mandroid" {
                URLSchemeHandler(delegate: self).handle(url)
            }
        }
    }
}

@MainActor enum EmulatorDeletion {
    static func confirm(coordinator: RunnerCoordinator, windows: WindowManager) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the emulator and installed apps?"
        alert.informativeText = "This removes the virtual device, every installed Android app, and their data. Launcher shortcuts are removed too. The downloaded Android system stays on this Mac, and you can choose the internal storage size before creating a new emulator."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        windows.closeAll()
        Task {
            let removed = await coordinator.deleteVirtualDevice()
            if removed { LauncherStubBuilder.sync([]) }
        }
    }
}
