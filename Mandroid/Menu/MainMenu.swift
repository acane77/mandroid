import AppKit

@MainActor
enum MainMenu {
    static func build(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mandroid", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",").target = delegate
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mandroid", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mandroid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Mandroid"))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Library", action: #selector(AppDelegate.showLibrary), keyEquivalent: "l").target = delegate
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let android = NSMenu(title: "Android")
        android.addItem(withTitle: "Back", action: #selector(AppWindowController.androidBack(_:)), keyEquivalent: "[")
        let home = android.addItem(withTitle: "Home", action: #selector(AppWindowController.androidHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        android.addItem(withTitle: "Recents", action: #selector(AppWindowController.androidRecents(_:)), keyEquivalent: "")
        android.addItem(withTitle: "Rotate Window", action: #selector(AppWindowController.rotateWindow(_:)), keyEquivalent: "r")
        let shot = android.addItem(withTitle: "Save Screenshot", action: #selector(AppWindowController.saveScreenshot(_:)), keyEquivalent: "s")
        shot.keyEquivalentModifierMask = [.command, .shift]
        android.addItem(.separator())
        android.addItem(withTitle: "Restart Emulator", action: #selector(AppDelegate.restartEmulator(_:)), keyEquivalent: "").target = delegate
        android.addItem(withTitle: "Cold Boot Emulator…", action: #selector(AppDelegate.coldBootEmulator(_:)), keyEquivalent: "").target = delegate
        android.addItem(withTitle: "Delete Emulator and Apps…", action: #selector(AppDelegate.deleteEmulator(_:)), keyEquivalent: "").target = delegate
        android.addItem(.separator())
        android.addItem(withTitle: "Show Device Screen", action: #selector(AppDelegate.showDeviceScreen(_:)), keyEquivalent: "d").target = delegate
        android.addItem(withTitle: "Open Play Store", action: #selector(AppDelegate.openPlayStore(_:)), keyEquivalent: "").target = delegate
        main.addItem(submenu(android, title: "Android"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
