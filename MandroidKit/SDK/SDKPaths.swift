import Foundation

/// All on-disk locations used by the runner. Everything lives under
/// `~/Library/Application Support/Mandroid/` so the user's own SDK
/// (if any) is never touched.
public struct SDKPaths: Sendable, Hashable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Default location under Application Support, unless the app was
    /// launched with `-dataRoot <path>` (testing a fresh install side by side
    /// with a real one).
    public static var `default`: SDKPaths {
        if let override = overrideRoot { return SDKPaths(root: override) }
        return SDKPaths(root: applicationSupport.appendingPathComponent("Mandroid", isDirectory: true))
    }

    /// `-dataRoot` launch argument, if any.
    public static var overrideRoot: URL? {
        guard let path = UserDefaults.standard.string(forKey: "dataRoot"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public var sdkRoot: URL { root.appendingPathComponent("sdk", isDirectory: true) }
    public var avdHome: URL { root.appendingPathComponent("avd", isDirectory: true) }
    public var emulatorHome: URL { root.appendingPathComponent("emulator-home", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var tools: URL { root.appendingPathComponent("tools", isDirectory: true) }

    public var licenses: URL { sdkRoot.appendingPathComponent("licenses", isDirectory: true) }
    public var emulatorDir: URL { sdkRoot.appendingPathComponent("emulator", isDirectory: true) }
    public var emulatorBinary: URL { emulatorDir.appendingPathComponent("emulator") }
    public var platformToolsDir: URL { sdkRoot.appendingPathComponent("platform-tools", isDirectory: true) }
    public var adbBinary: URL { platformToolsDir.appendingPathComponent("adb") }
    public var systemImagesDir: URL { sdkRoot.appendingPathComponent("system-images", isDirectory: true) }
    public var aapt2Binary: URL { tools.appendingPathComponent("aapt2") }

    /// `system-images;android-36.1;google_apis_playstore;arm64-v8a` →
    /// `<sdk>/system-images/android-36.1/google_apis_playstore/arm64-v8a`.
    public func directory(forPackagePath path: String) -> URL {
        path.split(separator: ";").reduce(sdkRoot) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }

    /// Environment for every emulator/adb process we spawn.
    public func environment(adbServerPort: Int) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_SDK_ROOT"] = sdkRoot.path
        env["ANDROID_HOME"] = sdkRoot.path
        env["ANDROID_AVD_HOME"] = avdHome.path
        env["ANDROID_EMULATOR_HOME"] = emulatorHome.path
        env["ANDROID_ADB_SERVER_PORT"] = String(adbServerPort)
        // Mandroid only connects to its emulator. USB enumeration can block
        // indefinitely in macOS IOKit when launched from the desktop.
        env["ADB_USB"] = "0"
        // Keep any JDK out of the picture; the emulator does not need one.
        env.removeValue(forKey: "JAVA_HOME")
        return env
    }

    /// Removes records of apps that were installed in the virtual device:
    /// the icon and label cache, and per-app proxy settings. SDK downloads
    /// stored beside the app cache are left alone.
    public func removeInstalledAppRecords() {
        let fm = FileManager.default
        try? fm.removeItem(at: cache.appendingPathComponent("apps", isDirectory: true))
        try? fm.removeItem(at: root.appendingPathComponent("app-proxies.json"))
    }

    public func createDirectories() throws {
        for dir in [root, sdkRoot, avdHome, emulatorHome, downloads, logs, cache, tools, licenses] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
