import Foundation
import Testing
@testable import MandroidKit

@Suite struct KernelSUTests {
    @Test func settingPersistsAndRequiresRestart() throws {
        let suite = "kernelsu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!RunnerSettings.load(from: defaults).kernelSUEnabled)
        let stock = RunnerSettings()
        var rooted = stock
        rooted.kernelSUEnabled = true
        rooted.save(to: defaults)
        #expect(RunnerSettings.load(from: defaults).kernelSUEnabled)
        #expect(rooted.requiresRestart(comparedTo: stock))
        #expect(stock.requiresRestart(comparedTo: rooted))
        stock.save(to: defaults)
        #expect(!RunnerSettings.load(from: defaults).kernelSUEnabled)
    }

    @Test func switchingToStockCannotRestoreRootedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AVDStore(paths: SDKPaths(root: root))
        var config = AVDConfig(systemImagePath: "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        #expect(try !store.write(config))
        let userdata = store.directory(for: config.name).appendingPathComponent("userdata-qemu.img")
        try Data("user data".utf8).write(to: userdata)
        for enabled in [true, false] {
            config.kernelSUEnabled = enabled
            #expect(try store.write(config))
            #expect(try !store.write(config))
            #expect(try Data(contentsOf: userdata) == Data("user data".utf8))
        }
        var launch = EmulatorLaunchOptions(avdName: "runner", consolePort: 5554, grpcPort: 8554, adbServerPort: 5137)
        #expect(!launch.arguments.contains("-ramdisk"))
        launch.kernelSURamdisk = root.appendingPathComponent("patched ramdisk.img")
        #expect(launch.arguments.contains("-no-snapshot"))
        #expect(launch.arguments.contains(launch.kernelSURamdisk!.path))
        launch.kernelSURamdisk = nil
        launch.coldBoot = true
        #expect(launch.arguments.contains("-no-snapshot-load"))
        #expect(!launch.arguments.contains("-ramdisk"))
    }

    @Test func bootImageUsesPinnedDirectoryWhenKernelSUIsOn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = SDKPaths(root: root)
        let newer = paths.directory(forPackagePath: "system-images;android-37;google_apis_playstore;arm64-v8a")
        let pinned = paths.directory(forPackagePath: KernelSUPatcher.imagePackagePath)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: true)
        try Data().write(to: newer.appendingPathComponent("system.img"))
        try Data().write(to: pinned.appendingPathComponent("system.img"))
        try "Pkg.Revision=4\n".write(to: pinned.appendingPathComponent("source.properties"), atomically: true, encoding: .utf8)
        let bootstrap = SDKBootstrap(paths: paths)
        #expect(bootstrap.installedSystemImage()?.packagePath == "system-images;android-37;google_apis_playstore;arm64-v8a")
        #expect(bootstrap.bootImage(kernelSU: false)?.packagePath == "system-images;android-37;google_apis_playstore;arm64-v8a")
        #expect(bootstrap.bootImage(kernelSU: true)?.packagePath == KernelSUPatcher.imagePackagePath)
        #expect(bootstrap.pinnedKernelSUImageInstalled)
        try "Pkg.Revision=3\n".write(to: pinned.appendingPathComponent("source.properties"), atomically: true, encoding: .utf8)
        #expect(!bootstrap.pinnedKernelSUImageInstalled)
        #expect(bootstrap.bootImage(kernelSU: true)?.packagePath == KernelSUPatcher.imagePackagePath)
        try FileManager.default.removeItem(at: pinned.appendingPathComponent("system.img"))
        #expect(bootstrap.bootImage(kernelSU: true) == nil)
    }

    @Test func rejectsDifferentKernelsAndPageSizes() throws {
        try KernelSUPatcher.requireSupportedKernel(Data("prefix Linux version \(KernelSUPatcher.kernelVersion) build".utf8))
        for version in ["6.12.38-android16-5-other-4k", KernelSUPatcher.kernelVersion + "-16k", "6.6.1-android15-4k"] {
            #expect(throws: KernelSUPatcher.Failure.self) {
                try KernelSUPatcher.requireSupportedKernel(Data("Linux version \(version) build".utf8))
            }
        }
    }

    @Test func cacheRejectsChangedInputAndCorruptOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ramdisk = root.appendingPathComponent("ramdisk.img"), guest = root.appendingPathComponent("ksud-android")
        try Data("patched".utf8).write(to: ramdisk)
        try Data("helper".utf8).write(to: guest)
        let manifest = KernelSUPatcher.Manifest(version: KernelSUPatcher.version, kernelHash: "kernel", stockRamdiskHash: "stock",
                                               patchedHash: try KernelSUPatcher.hash(ramdisk), guestToolHash: try KernelSUPatcher.hash(guest))
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        #expect(KernelSUPatcher.validCache(at: root, kernelHash: "kernel", stockHash: "stock"))
        #expect(!KernelSUPatcher.validCache(at: root, kernelHash: "updated", stockHash: "stock"))
        #expect(!KernelSUPatcher.validCache(at: root, kernelHash: "kernel", stockHash: "updated"))
        try Data("corrupt".utf8).write(to: guest)
        #expect(!KernelSUPatcher.validCache(at: root, kernelHash: "kernel", stockHash: "stock"))
        try Data("helper".utf8).write(to: guest)
        try Data("corrupt".utf8).write(to: ramdisk)
        #expect(!KernelSUPatcher.validCache(at: root, kernelHash: "kernel", stockHash: "stock"))
    }

    @Test func toolFailureAndCancellationAreReported() async throws {
        await #expect(throws: KernelSUPatcher.Failure.self) {
            _ = try await KernelSUPatcher.run(URL(fileURLWithPath: "/usr/bin/false"), [])
        }
        let task = Task { try await KernelSUPatcher.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func unsupportedImageRemainsUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let image = root.appendingPathComponent("image")
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = image.appendingPathComponent("plain")
        try Data("Linux version 6.6.0 unsupported".utf8).write(to: plain)
        let compressed = try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c", plain.path])
        let kernel = image.appendingPathComponent("kernel-ranchu"), ramdisk = image.appendingPathComponent("ramdisk.img")
        try compressed.stdout.write(to: kernel)
        try Data("stock ramdisk".utf8).write(to: ramdisk)
        let patcher = KernelSUPatcher(paths: SDKPaths(root: root))
        await #expect(throws: KernelSUPatcher.Failure.self) {
            _ = try await patcher.prepare(imageDirectory: image) { _ in }
        }
        #expect(try Data(contentsOf: kernel) == compressed.stdout)
        #expect(try Data(contentsOf: ramdisk) == Data("stock ramdisk".utf8))
        #expect(!FileManager.default.fileExists(atPath: patcher.root.path))
    }
}
