import Foundation

public enum RunnerState: Sendable, Equatable {
    case idle
    case checking
    case needsSetup(BootstrapPlan)
    /// The SDK is installed, but the virtual device and its apps were removed.
    case needsEmulator
    case settingUp(BootstrapPhase)
    case booting(String)          // human-readable stage
    case ready
    case shuttingDown
    case failed(String)

    public var isReady: Bool { if case .ready = self { return true } else { return false } }

    public static func == (a: RunnerState, b: RunnerState) -> Bool {
        switch (a, b) {
        case (.idle, .idle), (.checking, .checking), (.needsEmulator, .needsEmulator), (.ready, .ready), (.shuttingDown, .shuttingDown): return true
        case (.needsSetup(let x), .needsSetup(let y)): return x.systemImagePath == y.systemImagePath && x.components.map(\.id) == y.components.map(\.id)
        case (.settingUp(let x), .settingUp(let y)): return x == y
        case (.booting(let x), .booting(let y)): return x == y
        case (.failed(let x), .failed(let y)): return x == y
        default: return false
        }
    }
}
