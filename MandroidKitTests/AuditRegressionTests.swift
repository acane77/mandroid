import Foundation
import Testing
@testable import MandroidKit

@Suite struct AuditRegressionTests {
    @Test func completedDownloadMovesToNewDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("archive.zip")
        let payload = Data("downloaded bytes".utf8)
        try payload.write(to: destination.appendingPathExtension("part"))
        try await Downloader().download(URL(string: "http://127.0.0.1:1/unused")!,
            to: destination, expectedSize: Int64(payload.count), sha1: nil) { _ in }
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func emulatorExitTimeoutReturnsBeforeProcessExits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SDKPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.emulatorDir, withIntermediateDirectories: true)
        try "#!/bin/sh\nexec /bin/sleep 2\n".write(to: paths.emulatorBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.emulatorBinary.path)
        let process = try EmulatorProcess(paths: paths, options: .init(avdName: "test", consolePort: 5554,
            grpcPort: 8554, adbServerPort: 5137))
        try process.start()
        defer { process.kill() }
        let start = ContinuousClock.now
        #expect(await process.waitForExit(timeout: .milliseconds(50)) == false)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func clipboardCanReturnToEarlierValue() {
        var guardState = ClipboardEchoGuard()
        guardState.noteSentToGuest("a")
        guardState.noteReceivedFromGuest("b")
        #expect(guardState.shouldSendToGuest("a"))
        guardState.noteSentToGuest("a")
        #expect(guardState.shouldAcceptFromGuest("b"))
    }

    @Test func shellArgumentsAreLiteral() async throws {
        let value = "a.b'; printf injected; # $(printf expanded) `printf expanded`"
        let result = try await Subprocess.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' " + ADBClient.shellQuote(value)])
        #expect(result.status == 0)
        #expect(result.stdoutText == value)
    }

    @MainActor @Test func failedEmulatorLaunchStopsPrivateADB() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SDKPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = paths.directory(forPackagePath: "system-images;android-36;google_apis_playstore;arm64-v8a")
        for directory in [image, paths.emulatorDir, paths.platformToolsDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: image.appendingPathComponent("system.img"))
        let calls = root.appendingPathComponent("adb-calls")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(ADBClient.shellQuote(calls.path))\n".write(to: paths.adbBinary, atomically: true, encoding: .utf8)
        try "#!/missing-mandroid-test-interpreter\n".write(to: paths.emulatorBinary, atomically: true, encoding: .utf8)
        for binary in [paths.adbBinary, paths.emulatorBinary] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let coordinator = RunnerCoordinator(paths: paths)
        await coordinator.boot()
        if case .failed = coordinator.state { } else { Issue.record("boot should fail") }
        let commands = try String(contentsOf: calls, encoding: .utf8)
        #expect(commands.contains("start-server"))
        #expect(commands.contains("kill-server"))
        await coordinator.shutdown()
        #expect(coordinator.state == .idle)
    }

    @MainActor @Test func shutdownCancelsStartupBeforeSessionExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SDKPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = paths.directory(forPackagePath: "system-images;android-36;google_apis_playstore;arm64-v8a")
        for directory in [image, paths.emulatorDir, paths.platformToolsDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data().write(to: image.appendingPathComponent("system.img"))
        let started = root.appendingPathComponent("starting-adb")
        try "#!/bin/sh\nif [ \"$3\" = start-server ]; then touch \(ADBClient.shellQuote(started.path)); exec /bin/sleep 10; fi\n".write(to: paths.adbBinary, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(to: paths.emulatorBinary, atomically: true, encoding: .utf8)
        for binary in [paths.adbBinary, paths.emulatorBinary] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let coordinator = RunnerCoordinator(paths: paths)
        coordinator.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: started.path))
        #expect(coordinator.session == nil)
        let start = ContinuousClock.now
        await coordinator.shutdown()
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(coordinator.state == .idle)
        #expect(coordinator.session == nil)
    }

    @Test func subprocessDrainsLargeOutputAndInput() async throws {
        let input = Data(repeating: 65, count: 2 << 20)
        let result = try await Subprocess.run(URL(fileURLWithPath: "/bin/cat"), arguments: [], stdin: input)
        #expect(result.status == 0)
        #expect(result.stdout == input)
    }

    @Test func alreadyCancelledSubprocessDoesNotRun() async throws {
        let result = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Subprocess.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        }
        do {
            _ = try await result.value
            Issue.record("cancelled subprocess succeeded")
        } catch is CancellationError { }
    }

    @Test func subprocessCancellationEscalatesPastIgnoredTermination() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await Subprocess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c",
                "trap '' TERM; touch " + ADBClient.shellQuote(marker.path) + "; exec /bin/sleep 10"])
        }
        let readyDeadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        let start = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("cancelled process succeeded") } catch is CancellationError { }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func malformedFramesAndDisplayOutputAreRejected() {
        for (width, height) in [(0, 1), (-1, -1), (Int.max, 2), (2, Int.max)] {
            #expect(!Frame(width: width, height: height, pixels: Data(), sequence: 0, timestampUs: 0).isComplete)
        }
        #expect(DumpsysDisplayParser.parse("mBaseDisplayInfo=DisplayInfo{\"broken\", displayId 1, uniqueId \"x\", real ,").isEmpty)
    }

    @Test func largestSupportedDisplayFitsScreenshotTransport() {
        let (width, height, _) = DisplaySlotPool.sanitize(width: Int.max, height: Int.max, dpi: 320)
        let bytes = width * height * 4
        let options = EmulatorConnection.largeMessageOptions
        #expect((options.maxRequestMessageBytes ?? 0) > bytes)
        #expect((options.maxResponseMessageBytes ?? 0) > bytes)
    }

    @MainActor @Test func launcherStubsKeepSameLabelAppsAndUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appendingPathComponent("Same.app")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let sentinel = unrelated.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        let apps = ["com.one", "com.two"].map {
            AppInfo(package: $0, label: "Same", versionCode: 1, versionName: "1", launcherComponent: nil, iconFile: nil)
        }
        LauncherStubBuilder.sync(apps, at: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        LauncherStubBuilder.sync([], at: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Same.app"])
    }

    @Test func failedDisplayDiscoveryRollsBackGuest() async throws {
        let remote = AuditDisplayRemote()
        let pool = DisplaySlotPool(setDisplays: { try await remote.set($0) },
            readDisplays: { throw MandroidKitError.adb("disconnected") }, configureIME: { _ in })
        do {
            _ = try await pool.acquire(width: 640, height: 640, dpi: 320)
            Issue.record("discovery should fail")
        } catch { }
        #expect(await remote.displays.isEmpty)
        #expect(await pool.freeCount == 3)
    }

    @Test func failedDisplayReleaseKeepsOwnership() async throws {
        let remote = AuditDisplayRemote()
        let pool = DisplaySlotPool(setDisplays: { try await remote.set($0) },
            readDisplays: { "mBaseDisplayInfo=DisplayInfo{\"test\", displayId 7, uniqueId \"virtual:com.android.emulator.multidisplay:1234562\", real 640 x 640," },
            configureIME: { _ in })
        let slot = try await pool.acquire(width: 640, height: 640, dpi: 320)
        await remote.failNext()
        do { try await pool.release(slot.emulatorIndex); Issue.record("release should fail") } catch { }
        #expect(await pool.freeCount == 2)
        try await pool.release(slot.emulatorIndex)
        #expect(await pool.freeCount == 3)
    }

    @MainActor @Test func deleteVirtualDeviceRemovesAppsAndKeepsTheSDK() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = SDKPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AVDStore(paths: paths)
        var config = AVDConfig(systemImagePath: "system-images;android-36.1;google_apis_playstore;arm64-v8a")
        config.name = "runner"
        try store.write(config)
        let userdata = store.directory(for: config.name).appendingPathComponent("userdata-qemu.img.qcow2")
        try Data("installed games".utf8).write(to: userdata)
        let appCache = paths.cache.appendingPathComponent("apps/com.example.game-1", isDirectory: true)
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: appCache.appendingPathComponent("meta.json"))
        try Data("sdk manifest".utf8).write(to: paths.cache.appendingPathComponent("repository.xml"))
        try FileManager.default.createDirectory(at: paths.emulatorDir, withIntermediateDirectories: true)
        try Data("emulator".utf8).write(to: paths.emulatorBinary)
        let proxy = try HTTPProxyEndpoint(host: "127.0.0.1", port: 8080)
        try AppProxyStore.save(["com.example.game": proxy], at: paths.root)

        let coordinator = RunnerCoordinator(paths: paths)
        #expect(coordinator.appProxies["com.example.game"]?.port == 8080)
        #expect(await coordinator.deleteVirtualDevice())
        #expect(coordinator.state == .needsEmulator)
        #expect(coordinator.appProxies.isEmpty)
        #expect(coordinator.apps.isEmpty)
        #expect(!store.exists(config.name))
        #expect(!store.hasUserdata(config.name))
        #expect(!FileManager.default.fileExists(atPath: paths.cache.appendingPathComponent("apps").path))
        #expect(!FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("app-proxies.json").path))
        #expect(try Data(contentsOf: paths.cache.appendingPathComponent("repository.xml")) == Data("sdk manifest".utf8))
        #expect(try Data(contentsOf: paths.emulatorBinary) == Data("emulator".utf8))
        #expect(await coordinator.deleteVirtualDevice())
        #expect(coordinator.state == .needsEmulator)
    }

    @Test func downloadRejectsTruncationAndWrongResumeRange() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditDownloadProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let downloader = Downloader(session: session)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["short", "wrong-range"] {
            let destination = root.appendingPathComponent(name)
            if name == "wrong-range" { try Data("old".utf8).write(to: destination.appendingPathExtension("part")) }
            do {
                try await downloader.download(URL(string: "https://audit.invalid/\(name)")!,
                    to: destination, expectedSize: 10, sha1: nil) { _ in }
                Issue.record("invalid download was accepted: \(name)")
            } catch { }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
}

private actor AuditDisplayRemote {
    var displays: [DisplaySpec] = []
    private var shouldFail = false
    func failNext() { shouldFail = true }
    func set(_ displays: [DisplaySpec]) throws {
        if shouldFail { shouldFail = false; throw MandroidKitError.display("RPC failed") }
        self.displays = displays
    }
}

private final class AuditDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resume = request.url!.lastPathComponent == "wrong-range"
        let headers = resume ? ["Content-Range": "bytes 0-2/10", "Content-Length": "3"] : ["Content-Length": "3"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: resume ? 206 : 200,
            httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("new".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
