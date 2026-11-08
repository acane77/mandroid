import MandroidKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let coordinator: RunnerCoordinator
    let windows: WindowManager
    @State private var settings = RunnerSettings.load()
    @State private var saved = RunnerSettings.load()
    @State private var volume: Double = 0
    @State private var volumeReady = false
    @State private var applyingVolume = false
    @State private var volumeError: String?


    private var needsRestart: Bool {
        if let session = coordinator.session {
            if (session.options.kernelSURamdisk != nil) != settings.kernelSUEnabled { return true }
            let display = settings.deviceDisplay
            if session.deviceWidth != display.widthPixels || session.deviceHeight != display.heightPixels
                || session.deviceDpi != display.density { return true }
        }
        return settings.requiresRestart(comparedTo: saved)
    }

    var body: some View {
        Form {
            Section("Virtual device") {
                Picker("Device screen profile", selection: $settings.deviceProfile) {
                    ForEach(DeviceProfile.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if settings.deviceProfile == .custom {
                    Stepper("Width: \(settings.customDeviceWidthDP) dp", value: $settings.customDeviceWidthDP,
                            in: DeviceDisplay.dimensionRange, step: 20)
                    Stepper("Height: \(settings.customDeviceHeightDP) dp", value: $settings.customDeviceHeightDP,
                            in: DeviceDisplay.dimensionRange, step: 20)
                    Stepper("Density: \(settings.customDeviceDensity) dpi", value: $settings.customDeviceDensity,
                            in: DeviceDisplay.densityRange, step: 20)
                }
                Text(settings.deviceDisplay.summary).font(.caption).foregroundStyle(.secondary)
                Text("Open Device Screen to test apps with this display profile. Separate app windows use their own window size.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Memory", selection: $settings.ramMB) {
                    ForEach(RunnerSettings.ramChoices, id: \.self) { Text("\($0 / 1024) GB").tag($0) }
                }
                Picker("CPU cores", selection: $settings.cores) {
                    ForEach(RunnerSettings.coreChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                if coordinator.avdStore.hasUserdata(coordinator.avdName) {
                    if let raw = coordinator.avdStore.createdDataPartitionSize(coordinator.avdName) {
                        LabeledContent("Internal storage") { Text(internalStorageLabel(raw)) }
                    }
                    Text("Chosen when this emulator was created and cannot be changed.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Stepper("Internal storage: \(settings.dataPartitionMB / 1024) GB", value: internalStorageGB,
                            in: RunnerSettings.dataPartitionGBRange, step: RunnerSettings.dataPartitionStepGB)
                    Text("Used for installed apps and games. The file grows on this Mac only as it fills up. This cannot be changed after the emulator is created.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Graphics", selection: $settings.gpuBackend) {
                    ForEach(GPUBackend.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if needsRestart {
                    HostNotice(message: "Changes saved. Restart the emulator to apply them.", symbol: "arrow.clockwise.circle")
                        .transition(.opacity)
                }
                HStack {
                    Button("Restart Emulator") { restart(cold: false) }
                    Button("Cold Boot") { restart(cold: true) }
                }
                Button("Delete Emulator and Apps…", role: .destructive) {
                    EmulatorDeletion.confirm(coordinator: coordinator, windows: windows)
                }
                .disabled(!canDeleteEmulator)
                Text("Removes this emulator and every installed Android app. The downloaded system image stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("KernelSU (experimental)") {
                Toggle("Boot with KernelSU", isOn: $settings.kernelSUEnabled)
                Text("Adds root support to the Android 36.1 ARM64 revision 4 image. A separate patched image preserves the stock image. Turn this off and restart to return to stock; installed apps and data are kept. This switch does not download a system image. Delete the emulator and create it again with Enable KernelSU integration when the installed revision is different.")
                    .font(.caption).foregroundStyle(.secondary)
                if coordinator.session?.options.kernelSURamdisk != nil {
                    Label("KernelSU is active", systemImage: "checkmark.circle")
                } else {
                    Text("KernelSU is not active in this session.").font(.caption).foregroundStyle(.secondary)
                }
                Text(coordinator.kernelSUStatus).font(.caption).foregroundStyle(.secondary)
                if let error = coordinator.kernelSUError { HostNotice(message: error) }
                HStack {
                    if coordinator.preparingKernelSU {
                        ProgressView().controlSize(.small)
                        Button("Cancel Preparation") { coordinator.cancelKernelSUPreparation() }
                    } else {
                        Button("Prepare Patched Image") {
                            Task { _ = try? await coordinator.prepareKernelSU() }
                        }
                        .disabled(!coordinator.bootstrap.isReady)
                    }
                    Button("Restart to Apply") { restart(cold: true) }
                        .disabled(coordinator.preparingKernelSU)
                }
                Link("KernelSU project and license", destination: URL(string: "https://github.com/tiann/KernelSU")!)
                    .font(.caption)
            }
            Section("Audio") {
                HStack {
                    Slider(value: $volume, in: 0...100, step: 1, label: { Text("Media volume") }, onEditingChanged: { editing in
                        if !editing { applyVolume() }
                    })
                    .disabled(!volumeReady || applyingVolume || !coordinator.state.isReady)
                    Text(volumeReady ? "\(Int(volume))%" : "—")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("Controls all Android apps. Changes apply immediately; 0% mutes media audio.")
                    .font(.caption).foregroundStyle(.secondary)
                if !coordinator.state.isReady {
                    Text("Available when Android is running.").font(.caption).foregroundStyle(.secondary)
                }
                if let volumeError { HostNotice(message: volumeError).transition(.opacity) }
            }
            Section("Camera & Microphone") {
                Toggle("Let Android apps use this Mac's microphone", isOn: $settings.hostMicrophone)
                Toggle("Let Android apps use this Mac's camera", isOn: $settings.hostCamera)
                Text("For voice and video calls. macOS asks for permission the first time an app records; the Mac's camera acts as the front camera. Takes effect after a restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mouse wheel") {
                Stepper("Swipe distance: \(settings.wheelSwipeDistanceDP) dp",
                        value: $settings.wheelSwipeDistanceDP,
                        in: WheelSwipeTuning.distanceRange, step: WheelSwipeTuning.distanceStep)
                Stepper("Swipe speed: \(settings.wheelSwipeSpeedDPPerSecond) dp/s",
                        value: $settings.wheelSwipeSpeedDPPerSecond,
                        in: WheelSwipeTuning.speedRange, step: WheelSwipeTuning.speedStep)
                Text("A wheel notch slides a finger this far, at this speed (about \(wheelSwipeMilliseconds) ms). A trackpad swipe does the same, and the default distance matches the fingers. Applies immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Windows") {
                Picker("New windows open", selection: $settings.landscapeByDefault) {
                    Text("Landscape").tag(true)
                    Text("Portrait").tag(false)
                }
                .pickerStyle(.segmented)
                Stepper("Default window height: \(settings.defaultWindowHeight) pt",
                        value: $settings.defaultWindowHeight, in: 500...1600, step: 50)
                Toggle("Create launchers in ~/Applications/Android Apps", isOn: $settings.launcherStubs)
                Text("Launchers let Android apps appear in Spotlight and the Dock.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Picker("Download SDK from", selection: $settings.downloadMirror) {
                    Text("Automatic").tag(DownloadMirror.Preference.auto)
                    Text(DownloadMirror.google.name).tag(DownloadMirror.Preference.google)
                    Text(DownloadMirror.china.name).tag(DownloadMirror.Preference.china)
                }
                Text("Automatic uses the China mirror only when this Mac's region or time zone is mainland China. Applies to the next download.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Files") {
                LabeledContent("System image") {
                    Text(coordinator.bootstrap.installedSystemImage()?.packagePath ?? "none").textSelection(.enabled)
                }
                HStack {
                    Button("Show Logs") { NSWorkspace.shared.open(coordinator.paths.logs) }
                    Button("Show Data Folder") { NSWorkspace.shared.open(coordinator.paths.root) }
                }
                Text("Data folder: \(coordinator.paths.root.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 720)
        .animation(HostStyle.motion(reduceMotion: reduceMotion), value: needsRestart)
        .animation(HostStyle.motion(reduceMotion: reduceMotion), value: volumeError != nil)
        .task(id: coordinator.state.isReady) {
            volumeReady = false
            guard coordinator.state.isReady, let adb = coordinator.session?.adb else { return }
            do {
                volume = Double(try await adb.mediaVolume().percent)
                volumeReady = true
                volumeError = nil
            } catch { volumeError = error.localizedDescription }
        }
        .onChange(of: settings) { _, new in
            new.save()
            if !new.launcherStubs {
                LauncherStubBuilder.sync([])
            } else if !coordinator.apps.isEmpty {
                LauncherStubBuilder.sync(coordinator.apps)
            }
        }
    }

    private var wheelSwipeMilliseconds: Int {
        let ms = Double(settings.wheelSwipeDistanceDP) / Double(max(settings.wheelSwipeSpeedDPPerSecond, 1)) * 1000
        return max(Int(ms.rounded()), 1)
    }

    private var canDeleteEmulator: Bool {
        coordinator.avdStore.exists(coordinator.avdName) || coordinator.avdStore.hasUserdata(coordinator.avdName)
    }

    private var internalStorageGB: Binding<Int> {
        Binding(
            get: { settings.dataPartitionMB / 1024 },
            set: { settings.dataPartitionMB = $0 * 1024 }
        )
    }

    private func internalStorageLabel(_ raw: String) -> String {
        if raw.hasSuffix("M"), let megabytes = Int(raw.dropLast()), megabytes.isMultiple(of: 1024), megabytes > 0 {
            return "\(megabytes / 1024) GB"
        }
        return raw
    }

    private func applyVolume() {
        guard volumeReady, !applyingVolume, let adb = coordinator.session?.adb else { return }
        applyingVolume = true
        let requested = Int(volume)
        Task {
            defer { applyingVolume = false }
            do {
                let actual = try await adb.setMediaVolume(percent: requested)
                volume = Double(actual.percent)
                settings.mediaVolumePercent = actual.percent
                volumeError = nil
            } catch { volumeError = error.localizedDescription }
        }
    }

    private func restart(cold: Bool) {
        saved = settings
        windows.closeAll()
        Task { await coordinator.restart(coldBoot: cold) }
    }
}

final class SettingsWindowController: NSWindowController {
    init(coordinator: RunnerCoordinator, windows: WindowManager) {
        let host = NSHostingController(rootView: SettingsView(coordinator: coordinator, windows: windows))
        let window = NSWindow(contentViewController: host)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.contentMinSize = NSSize(width: 480, height: 420)
        window.setContentSize(NSSize(width: 560, height: 720))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError() }
}
