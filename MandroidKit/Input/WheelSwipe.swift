import Foundation

/// How far and how fast a mouse-wheel notch slides a finger on the Android display.
/// Distance is dp per notch; speed is dp per second. Both are independent of the
/// macOS window size.
public struct WheelSwipeTuning: Sendable, Equatable {
    public var distanceDP: Int
    public var speedDPPerSecond: Int

    public static let defaultDistanceDP = 180
    public static let defaultSpeedDPPerSecond = 2400
    public static let distanceRange = 10...800
    public static let speedRange = 400...8000
    public static let distanceStep = 10
    public static let speedStep = 200

    public init(distanceDP: Int = defaultDistanceDP, speedDPPerSecond: Int = defaultSpeedDPPerSecond) {
        self.distanceDP = min(max(distanceDP, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
        self.speedDPPerSecond = min(max(speedDPPerSecond, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    /// Display pixels one wheel line moves the finger at `dpi`.
    public func pixelsPerLine(dpi: Int) -> Double {
        Double(distanceDP) * Double(max(dpi, 1)) / 160
    }

    /// 1 at the default distance. Trackpad travel is multiplied by this, so a
    /// larger distance setting moves the finger farther than the fingers moved.
    public var distanceScale: Double {
        Double(distanceDP) / Double(Self.defaultDistanceDP)
    }

    public func pixelsPerSecond(dpi: Int) -> Double {
        Double(speedDPPerSecond) * Double(max(dpi, 1)) / 160
    }
}

/// What one scroll event contributes to the finger stroke.
public enum WheelSwipeInput: Sendable, Equatable {
    /// Discrete wheel notches. One line travels `distanceDP`.
    case lines(Double)
    /// Trackpad travel in display pixels, before the distance scale is applied.
    case pixels(Double)
}

/// One finger stroke driven by mouse-wheel lines and trackpad drags.
///
/// AppKit's positive wheel delta moves content down, and a finger moving down
/// the screen does the same, so positive lines increase Y. A notch in the
/// opposite direction turns the finger around immediately. Outstanding travel
/// is capped at a few notches so a fast wheel cannot leave the finger moving
/// long after the wheel has stopped.
public struct WheelSwipeMotion: Sendable {
    public struct Sample: Sendable, Equatable {
        public var x: Int
        public var y: Int
        /// 1000 while the finger is down, 0 when it lifts.
        public var pressure: Int
    }

    /// Mouse clicks use identifier 0. A wheel stroke is a second finger so the
    /// two never merge, and its lift uses the same identifier.
    public static let touchIdentifier = 1

    /// Queued travel beyond this many notches is dropped.
    private static let queuedNotchCap = 3.0

    private var down = false
    private var x = 0
    private var y = 0.0
    private var remaining = 0.0
    private var displayHeight = 1

    public init() {}

    public var isDown: Bool { down }
    /// True when the finger is down and has nowhere left to travel.
    public var isIdle: Bool { down && abs(remaining) < 0.5 }

    /// Adds one scroll event. Returns the touch-down sample when a stroke starts.
    /// A stroke that cannot move (the finger is already on that edge) does not start.
    @discardableResult
    public mutating func add(
        _ input: WheelSwipeInput,
        at point: (x: Int, y: Int),
        tuning: WheelSwipeTuning,
        dpi: Int,
        displayWidth: Int,
        displayHeight: Int
    ) -> Sample? {
        let height = max(displayHeight, 1)
        let travel: Double
        let cap: Double
        switch input {
        case .lines(let lines):
            guard lines != 0 else { return nil }
            travel = lines * tuning.pixelsPerLine(dpi: dpi)
            let linePx = abs(tuning.pixelsPerLine(dpi: dpi))
            cap = linePx * max(Self.queuedNotchCap, abs(lines))
        case .pixels(let pixels):
            guard pixels != 0 else { return nil }
            travel = pixels * tuning.distanceScale
            // A trackpad drag may cross the screen. A wheel notch must not
            // queue several screens of motion after the wheel has stopped.
            cap = max(Double(height), abs(tuning.pixelsPerLine(dpi: dpi)) * Self.queuedNotchCap)
        }
        return beginOrExtend(
            travel: travel, cap: cap, at: point,
            displayWidth: displayWidth, displayHeight: height)
    }

    /// Adds wheel lines. Returns the touch-down sample when a stroke starts.
    @discardableResult
    public mutating func addLines(
        _ lines: Double,
        at point: (x: Int, y: Int),
        tuning: WheelSwipeTuning,
        dpi: Int,
        displayWidth: Int,
        displayHeight: Int
    ) -> Sample? {
        add(.lines(lines), at: point, tuning: tuning, dpi: dpi, displayWidth: displayWidth, displayHeight: displayHeight)
    }

    @discardableResult
    private mutating func beginOrExtend(
        travel: Double,
        cap: Double,
        at point: (x: Int, y: Int),
        displayWidth: Int,
        displayHeight: Int
    ) -> Sample? {
        guard travel != 0 else { return nil }
        let height = max(displayHeight, 1)
        let width = max(displayWidth, 1)
        self.displayHeight = height
        if !down {
            let startY = min(max(Double(point.y), 0), Double(height - 1))
            var pixels = travel
            if startY <= 0, pixels < 0 { pixels = 0 }
            if startY >= Double(height - 1), pixels > 0 { pixels = 0 }
            guard abs(pixels) >= 0.5 else { return nil }
            down = true
            x = min(max(point.x, 0), width - 1)
            y = startY
            remaining = pixels
            capQueued(cap)
            return Sample(x: x, y: Int(y.rounded()), pressure: 1000)
        }
        if remaining != 0, (travel > 0) != (remaining > 0) {
            remaining = travel
        } else {
            remaining += travel
        }
        capQueued(cap)
        clipRemaining()
        return nil
    }

    /// Moves the finger for `dt` seconds. Nil when the on-screen pixel did not change.
    public mutating func advance(dt: Double, tuning: WheelSwipeTuning, dpi: Int, displayHeight: Int) -> Sample? {
        guard down, dt > 0 else { return nil }
        self.displayHeight = max(displayHeight, 1)
        let limit = Double(self.displayHeight - 1)
        if y > limit {
            y = limit
            remaining = 0
            return Sample(x: x, y: Int(y.rounded()), pressure: 1000)
        }
        guard abs(remaining) >= 0.5 else { return nil }
        let speed = max(tuning.pixelsPerSecond(dpi: dpi), 1)
        let step = min(abs(remaining), speed * dt)
        let delta = remaining > 0 ? step : -step
        let unclamped = y + delta
        let clamped = min(max(unclamped, 0), limit)
        remaining -= delta
        if clamped != unclamped || abs(remaining) < 0.5 { remaining = 0 }
        let previous = Int(y.rounded())
        y = clamped
        clipRemaining()
        let next = Int(y.rounded())
        guard next != previous else { return nil }
        return Sample(x: x, y: next, pressure: 1000)
    }

    /// Lifts the finger. Nil when it was already up.
    public mutating func lift() -> Sample? {
        guard down else { return nil }
        down = false
        remaining = 0
        return Sample(x: x, y: Int(y.rounded()), pressure: 0)
    }

    private mutating func capQueued(_ cap: Double) {
        guard cap > 0, abs(remaining) > cap else { return }
        remaining = remaining > 0 ? cap : -cap
    }

    private mutating func clipRemaining() {
        if y <= 0, remaining < 0 { remaining = 0 }
        if y >= Double(displayHeight - 1), remaining > 0 { remaining = 0 }
    }
}

/// Plays a `WheelSwipeMotion` as timed touch samples. Notches that arrive
/// while the finger is still down extend the same stroke; the finger lifts
/// after it has been still for a few ticks, which is long enough to merge one
/// burst of wheel events and short enough to fling.
public actor WheelSwipeDriver {
    private var motion = WheelSwipeMotion()
    private var pending: [WheelSwipeMotion.Sample] = []
    private var running = false
    private var stop = false
    private var fingerSent = false
    private var tuning = WheelSwipeTuning()
    private var dpi = 320
    private var height = 1
    private var send: (@Sendable (WheelSwipeMotion.Sample) async -> Void)?
    private let tick: Duration
    /// Extra ticks the finger stays down after travel ends so the next notch can join.
    private let holdTicks = 4

    public init(tick: Duration = .milliseconds(16)) {
        self.tick = tick
    }

    /// Accepts one scroll event. Positive travel moves the finger down.
    /// Returns true when the finger is down afterwards. The samples are delivered
    /// to `send` in order, including the later lift.
    @discardableResult
    public func wheel(
        _ input: WheelSwipeInput,
        x: Int,
        y: Int,
        tuning: WheelSwipeTuning,
        dpi: Int,
        width: Int,
        height: Int,
        send: @escaping @Sendable (WheelSwipeMotion.Sample) async -> Void
    ) async -> Bool {
        stop = false
        self.send = send
        self.tuning = tuning
        self.dpi = max(dpi, 1)
        self.height = max(height, 1)
        if let down = motion.add(
            input, at: (x, y), tuning: tuning, dpi: self.dpi,
            displayWidth: max(width, 1), displayHeight: self.height
        ) {
            pending.append(down)
        }
        guard motion.isDown else { return false }
        if !running {
            running = true
            Task { await self.run() }
        }
        return true
    }

    /// Lifts the finger if a stroke is in progress. Safe when the finger is up.
    public func cancel() async {
        stop = true
        guard !running else { return }
        pending.removeAll()
        await liftIfSent()
        stop = false
    }

    /// Resolves when the finger is up and no stroke is playing.
    public func waitUntilIdle() async {
        while running || motion.isDown || !pending.isEmpty {
            try? await Task.sleep(for: tick)
        }
    }

    private func run() async {
        defer { running = false }
        let dt = Self.seconds(tick)
        var idleTicks = 0
        while true {
            if stop {
                pending.removeAll()
                await liftIfSent()
                stop = false
                if pending.isEmpty, !motion.isDown { return }
                continue
            }
            if !pending.isEmpty {
                let sample = pending.removeFirst()
                await deliver(sample)
                if stop { continue }
                try? await Task.sleep(for: tick)
                continue
            }
            if let sample = motion.advance(dt: dt, tuning: tuning, dpi: dpi, displayHeight: height) {
                idleTicks = 0
                await deliver(sample)
                if stop { continue }
                try? await Task.sleep(for: tick)
                continue
            }
            if motion.isIdle {
                idleTicks += 1
                if idleTicks >= holdTicks {
                    await liftIfSent()
                    idleTicks = 0
                    if pending.isEmpty, !motion.isDown { return }
                    continue
                }
                try? await Task.sleep(for: tick)
                continue
            }
            if !motion.isDown {
                if pending.isEmpty { return }
                continue
            }
            idleTicks = 0
            try? await Task.sleep(for: tick)
        }
    }

    private func deliver(_ sample: WheelSwipeMotion.Sample) async {
        fingerSent = sample.pressure != 0
        await send?(sample)
    }

    private func liftIfSent() async {
        guard let up = motion.lift() else {
            fingerSent = false
            return
        }
        if fingerSent {
            fingerSent = false
            await send?(up)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
