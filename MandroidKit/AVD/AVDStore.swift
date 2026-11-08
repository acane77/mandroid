import Foundation

/// Creates and inspects AVDs under the isolated `ANDROID_AVD_HOME`.
public struct AVDStore: Sendable {
    public let paths: SDKPaths
    public init(paths: SDKPaths) { self.paths = paths }

    public func directory(for name: String) -> URL {
        paths.avdHome.appendingPathComponent("\(name).avd", isDirectory: true)
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: name).appendingPathComponent("config.ini").path)
    }

    /// True once the emulator has created the data image. Changing
    /// `disk.dataPartition.size` after that does not resize the image.
    public func hasUserdata(_ name: String) -> Bool {
        let dir = directory(for: name)
        let files = ["userdata-qemu.img", "userdata-qemu.img.qcow2"]
        return files.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// `disk.dataPartition.size` from `config.ini` when a userdata image is present.
    public func createdDataPartitionSize(_ name: String) -> String? {
        guard hasUserdata(name) else { return nil }
        let file = directory(for: name).appendingPathComponent("config.ini")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return Self.configValue("disk.dataPartition.size", in: text)
    }

    /// Writes the AVD files. Existing user data (`userdata-qemu.img`,
    /// `userdata-qemu.img.qcow2`, snapshots) is preserved; only the ini files
    /// are (re)written. Once a userdata image exists, `disk.dataPartition.size`
    /// stays at the value that image was created with.
    /// The emulator appends `hw.displayN.*` keys at runtime; we strip them so
    /// every boot starts with display 0 only.
    /// Returns true when an existing display, GPU, boot or camera profile changed
    /// and its old quickboot snapshot must not be loaded (the guest camera HAL
    /// enumerates host cameras once at boot). User data is never reset.
    @discardableResult
    public func write(_ config: AVDConfig) throws -> Bool {
        let dir = directory(for: config.name)
        let ini = dir.appendingPathComponent("config.ini")
        let previous = try? String(contentsOf: ini, encoding: .utf8)
        var rendered = config.renderConfigINI()
        if hasUserdata(config.name),
           let previous,
           let kept = Self.configValue("disk.dataPartition.size", in: previous) {
            rendered = Self.replacingConfigValue("disk.dataPartition.size", with: kept, in: rendered)
        }
        let snapshotKeys = ["hw.lcd.width", "hw.lcd.height", "hw.lcd.density", "hw.initialOrientation", "hw.gpu.mode", "mandroid.gpu.backend", "mandroid.kernelsu.enabled",
                            "hw.camera.front", "hw.camera.back"]
        let profileChanged = previous.map { old in
            snapshotKeys.contains { Self.configValue($0, in: old) != Self.configValue($0, in: rendered) }
        } ?? false
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rendered.write(to: ini, atomically: true, encoding: .utf8)
        try config.renderPointerINI(avdDirectory: dir)
            .write(to: paths.avdHome.appendingPathComponent("\(config.name).ini"), atomically: true, encoding: .utf8)
        return profileChanged
    }

    private static func configValue(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func replacingConfigValue(_ key: String, with newValue: String, in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return "\(key)=\(newValue)"
            }
            return String(line)
        }.joined(separator: "\n")
    }

    /// Removes `hw.display1..3` lines the emulator may have persisted.
    public func stripPersistedDisplays(_ name: String) throws {
        let file = directory(for: name).appendingPathComponent("config.ini")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("hw.display") }
        let out = kept.joined(separator: "\n")
        if out != text { try out.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Removes the quickboot snapshot (used after a failed or corrupt load).
    public func deleteQuickbootSnapshot(_ name: String) {
        try? FileManager.default.removeItem(at: directory(for: name).appendingPathComponent("snapshots/default_boot", isDirectory: true))
    }

    /// Deletes the AVD entirely, including userdata and installed apps.
    /// Missing files are ignored. A failure to remove an existing file is thrown
    /// so the caller does not treat a locked image as gone.
    public func delete(_ name: String) throws {
        let fm = FileManager.default
        for url in [directory(for: name), paths.avdHome.appendingPathComponent("\(name).ini")] {
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
        }
    }
}
