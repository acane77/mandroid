import MandroidKit
import SwiftUI

/// First-run download UI and boot progress.
struct SetupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var coordinator: RunnerCoordinator
    @State private var mirrorPreference = RunnerSettings.load().downloadMirror
    @State private var dataPartitionGB = RunnerSettings.load().dataPartitionMB / 1024
    @State private var kernelSUEnabled = RunnerSettings.load().kernelSUEnabled

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: HostStyle.inset) {
                    HStack(spacing: 16) {
                        Image(systemName: "iphone.gen3.badge.play")
                            .font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mandroid").font(.title2.weight(.semibold))
                            Text(subtitle).foregroundStyle(.secondary)
                        }
                    }
                    content.id(stage).transition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HostStyle.inset)
            }
            Divider()
            HStack {
                Text("Android on your Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                switch coordinator.state {
                case .needsSetup(let plan):
                    Button("Download and Install") { coordinator.runSetup(plan) }
                        .keyboardShortcut(.defaultAction)
                case .needsEmulator:
                    Button("Create Emulator") { coordinator.createEmulator() }
                        .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Try Again") { coordinator.retry() }.keyboardShortcut(.defaultAction)
                default:
                    ProgressView().controlSize(.small).accessibilityLabel(subtitle)
                }
            }
            .padding(16).background(.bar)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 480)
        .animation(HostStyle.motion(reduceMotion: reduceMotion), value: stage)
        .onChange(of: stage) { _, new in
            guard new == "needs-emulator" || new == "plan" else { return }
            let settings = RunnerSettings.load()
            dataPartitionGB = settings.dataPartitionMB / 1024
            kernelSUEnabled = settings.kernelSUEnabled
        }
    }

    // Progress bytes are intentionally excluded so downloads do not restart transitions.
    private var stage: String {
        switch coordinator.state {
        case .needsSetup: return "plan"
        case .needsEmulator: return "needs-emulator"
        case .settingUp(let phase):
            switch phase {
            case .fetchingManifests: return "manifests"
            case .downloading(let name, _): return "download-" + name
            case .extracting(let name): return "extract-" + name
            case .finished: return "finished"
            }
        case .booting: return "booting"
        case .failed: return "failed"
        default: return "checking"
        }
    }

    private var subtitle: String {
        switch coordinator.state {
        case .needsSetup: return "A one-time download is needed."
        case .needsEmulator: return "Create a new emulator."
        case .settingUp: return "Downloading components…"
        case .booting: return "Starting the Android emulator…"
        case .failed: return "Something went wrong."
        default: return "Checking installation…"
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.state {
        case .needsSetup(let plan):
            planView(plan)
        case .needsEmulator:
            VStack(alignment: .leading, spacing: 16) {
                Text("The virtual device and its installed apps have been removed. The downloaded Android system stays on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                storageChoice
                kernelSUChoice
            }
        case .settingUp(let phase):
            phaseView(phase)
        case .booting(let stage):
            HStack { ProgressView(); Text(stage) }
        case .failed(let message):
            HostNotice(message: message)
        default:
            HStack { ProgressView(); Text("Checking…") }
        }
    }

    private func planView(_ plan: BootstrapPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The following components will be downloaded into your Application Support folder:")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(plan.components) { c in
                HStack {
                    Text(c.displayName)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: c.sizeBytes, countStyle: .file))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Divider()
            HStack {
                Text("Total").bold()
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)).bold().monospacedDigit()
            }
            Picker("Download from", selection: $mirrorPreference) {
                Text("Automatic (\(plan.mirror.name))").tag(DownloadMirror.Preference.auto)
                Text(DownloadMirror.google.name).tag(DownloadMirror.Preference.google)
                Text(DownloadMirror.china.name).tag(DownloadMirror.Preference.china)
            }
            .onChange(of: mirrorPreference) { _, new in
                var s = RunnerSettings.load()
                guard s.downloadMirror != new else { return }
                s.downloadMirror = new
                s.save()
                coordinator.retry()
            }
            storageChoice
            kernelSUChoice
            Text("By continuing you accept the Android SDK License Agreement and the terms of the Google Play system image. Nothing outside this app's folder is modified.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var storageChoice: some View {
        if !coordinator.avdStore.hasUserdata(coordinator.avdName) {
            Stepper("Internal storage: \(dataPartitionGB) GB", value: $dataPartitionGB,
                    in: RunnerSettings.dataPartitionGBRange, step: RunnerSettings.dataPartitionStepGB)
                .onChange(of: dataPartitionGB) { _, new in
                    var s = RunnerSettings.load()
                    let megabytes = new * 1024
                    guard RunnerSettings.isValidDataPartitionMB(megabytes), s.dataPartitionMB != megabytes else { return }
                    s.dataPartitionMB = megabytes
                    s.save()
                }
            Text("Used for installed apps and games. The file grows on this Mac only as it fills up. This cannot be changed after the emulator is created.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var kernelSUChoice: some View {
        Toggle("Enable KernelSU integration", isOn: $kernelSUEnabled)
            .toggleStyle(.checkbox)
            .onChange(of: kernelSUEnabled) { _, new in
                var s = RunnerSettings.load()
                guard s.kernelSUEnabled != new else { return }
                s.kernelSUEnabled = new
                s.save()
                if case .needsSetup = coordinator.state { coordinator.retry() }
            }
        Text("Uses the Android 36.1 ARM64 revision 4 system image. If that revision is not installed, it is downloaded and replaces the image at that package path before the emulator is created.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(installedImageNote)
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var installedImageNote: String {
        guard let image = coordinator.bootstrap.installedSystemImage() else {
            return "No system image is installed yet."
        }
        let revision = coordinator.bootstrap.installedRevision(at: image.directory)?.description ?? "unknown"
        return "Installed system image: \(image.packagePath) (revision \(revision))."
    }

    @ViewBuilder private func phaseView(_ phase: BootstrapPhase) -> some View {
        switch phase {
        case .fetchingManifests:
            HStack { ProgressView(); Text("Preparing download…") }
        case .downloading(let name, let p):
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading \(name)")
                Group {
                    if let fraction = p.fraction { ProgressView(value: fraction) }
                    else { ProgressView().controlSize(.small) }
                }.accessibilityLabel("Downloading " + name)
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: p.received, countStyle: .file))
                    if let total = p.total { Text("of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))") }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text("Downloads resume if the app is quit and reopened.").font(.caption2).foregroundStyle(.tertiary)
            }
        case .extracting(let name):
            HStack { ProgressView(); Text("Unpacking \(name)…") }
        case .finished:
            HStack { ProgressView(); Text("Starting…") }
        }
    }
}
