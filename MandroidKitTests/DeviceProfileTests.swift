import Foundation
import Testing
@testable import MandroidKit

@Suite struct DeviceProfileTests {
    @Test func defaultPreservesExistingTabletGeometry() {
        let settings = RunnerSettings()
        var config = AVDConfig(systemImagePath: "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        let original = config
        settings.apply(to: &config)
        #expect(config.lcdWidth == original.lcdWidth)
        #expect(config.lcdHeight == original.lcdHeight)
        #expect(config.lcdDensity == original.lcdDensity)
    }

    @Test func customProfilePersistsAndRejectsCorruptPreferences() throws {
        let suite = "device-profile-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = RunnerSettings()
        settings.deviceProfile = .custom
        settings.customDeviceWidthDP = 600
        settings.customDeviceHeightDP = 1000
        settings.customDeviceDensity = 240
        settings.save(to: defaults)
        #expect(RunnerSettings.load(from: defaults) == settings)
        #expect(settings.deviceDisplay.widthPixels == 900)
        #expect(settings.deviceDisplay.heightPixels == 1500)
        defaults.set("missing-profile", forKey: "deviceProfile")
        defaults.set(Int.max, forKey: "customDeviceWidthDP")
        defaults.set(-1, forKey: "customDeviceHeightDP")
        defaults.set(0, forKey: "customDeviceDensity")
        let loaded = RunnerSettings.load(from: defaults)
        #expect(loaded.deviceProfile == .tablet)
        #expect(loaded.customDeviceWidthDP == 400)
        #expect(loaded.customDeviceHeightDP == 900)
        #expect(loaded.customDeviceDensity == 320)
        let bounded = DeviceDisplay(widthDP: Int.max, heightDP: Int.min, density: Int.max)
        #expect(bounded.widthPixels == 4800)
        #expect(bounded.heightPixels == 960)
    }

    @Test func profileSwitchColdBootsOnceAndPreservesUserdata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AVDStore(paths: SDKPaths(root: root))
        var config = AVDConfig(systemImagePath: "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        var settings = RunnerSettings()
        settings.apply(to: &config)
        #expect(try !store.write(config))
        let data = store.directory(for: config.name).appendingPathComponent("userdata-qemu.img")
        let marker = Data("installed apps and user data".utf8)
        try marker.write(to: data)
        for profile in [DeviceProfile.phone, .compactPhone, .custom, .tablet] {
            settings.deviceProfile = profile
            settings.apply(to: &config)
            #expect(try store.write(config))
            #expect(try !store.write(config))
            #expect(try Data(contentsOf: data) == marker)
            let ini = try String(contentsOf: store.directory(for: config.name).appendingPathComponent("config.ini"), encoding: .utf8)
            #expect(ini.contains("hw.lcd.width=\(settings.deviceDisplay.widthPixels)\n"))
            #expect(ini.contains("hw.lcd.density=\(settings.deviceDisplay.density)\n"))
            #expect(config.systemImagePath == "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        }
    }

    @Test func numericLaunchArgumentsConfigureCustomDisplay() throws {
        let suite = "device-profile-args-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setVolatileDomain([
            "deviceProfile": "custom", "customDeviceWidthDP": "600",
            "customDeviceHeightDP": "1000", "customDeviceDensity": "240",
        ], forName: UserDefaults.argumentDomain)
        let display = RunnerSettings.load(from: defaults).deviceDisplay
        #expect(display.widthPixels == 900)
        #expect(display.heightPixels == 1500)
        #expect(display.density == 240)
    }

    @Test func dataPartitionPersistsRejectsOutOfRangeAndDoesNotRequireRestart() throws {
        let suite = "data-partition-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RunnerSettings.load(from: defaults).dataPartitionMB == 16 * 1024)
        var settings = RunnerSettings()
        settings.dataPartitionMB = 64 * 1024
        settings.save(to: defaults)
        let loaded = RunnerSettings.load(from: defaults)
        #expect(loaded.dataPartitionMB == settings.dataPartitionMB)
        var config = AVDConfig(systemImagePath: "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        loaded.apply(to: &config)
        #expect(config.dataPartitionMB == 64 * 1024)
        #expect(config.renderConfigINI().contains("disk.dataPartition.size=65536M\n"))
        defaults.set(1000, forKey: "dataPartitionMB")
        #expect(RunnerSettings.load(from: defaults).dataPartitionMB == 16 * 1024)
        defaults.set(600 * 1024, forKey: "dataPartitionMB")
        #expect(RunnerSettings.load(from: defaults).dataPartitionMB == 16 * 1024)
        defaults.set(24 * 1024, forKey: "dataPartitionMB")
        #expect(RunnerSettings.load(from: defaults).dataPartitionMB == 16 * 1024)
        var resized = loaded
        resized.dataPartitionMB = 128 * 1024
        #expect(!resized.requiresRestart(comparedTo: loaded))
    }

    @Test func dataPartitionSizeIsFrozenOnceUserdataExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AVDStore(paths: SDKPaths(root: root))
        var config = AVDConfig(systemImagePath: "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        config.dataPartitionMB = 32 * 1024
        #expect(store.createdDataPartitionSize(config.name) == nil)
        #expect(try !store.write(config))
        let iniURL = store.directory(for: config.name).appendingPathComponent("config.ini")
        func ini() throws -> String { try String(contentsOf: iniURL, encoding: .utf8) }
        #expect(try ini().contains("disk.dataPartition.size=32768M\n"))

        let marker = Data("installed apps".utf8)
        let userdata = store.directory(for: config.name).appendingPathComponent("userdata-qemu.img")
        try marker.write(to: userdata)
        config.dataPartitionMB = 128 * 1024
        #expect(try !store.write(config))
        #expect(try ini().contains("disk.dataPartition.size=32768M\n"))
        #expect(try !ini().contains("131072M"))
        #expect(try Data(contentsOf: userdata) == marker)
        #expect(store.createdDataPartitionSize(config.name) == "32768M")

        try FileManager.default.removeItem(at: userdata)
        let qcow = store.directory(for: config.name).appendingPathComponent("userdata-qemu.img.qcow2")
        try Data("qcow".utf8).write(to: qcow)
        config.dataPartitionMB = 256 * 1024
        #expect(try !store.write(config))
        #expect(try ini().contains("disk.dataPartition.size=32768M\n"))
        #expect(try Data(contentsOf: qcow) == Data("qcow".utf8))
        #expect(store.hasUserdata(config.name))

        try FileManager.default.removeItem(at: qcow)
        #expect(!store.hasUserdata(config.name))
        config.dataPartitionMB = 64 * 1024
        #expect(try !store.write(config))
        #expect(try ini().contains("disk.dataPartition.size=65536M\n"))
        #expect(store.createdDataPartitionSize(config.name) == nil)
    }

    @Test func restartDependsOnEffectiveProfile() {
        let running = RunnerSettings()
        var edited = running
        edited.customDeviceWidthDP = 600
        #expect(!edited.requiresRestart(comparedTo: running))
        edited.deviceProfile = .custom
        #expect(edited.requiresRestart(comparedTo: running))
        edited.deviceProfile = .tablet
        #expect(!edited.requiresRestart(comparedTo: running))
        edited.deviceProfile = .phone
        #expect(edited.requiresRestart(comparedTo: running))
    }
}
