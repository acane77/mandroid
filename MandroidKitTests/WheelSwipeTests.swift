import Foundation
import Testing
@testable import MandroidKit

@Suite struct WheelSwipeMotionTests {
    private let tuning = WheelSwipeTuning(distanceDP: 160, speedDPPerSecond: 1600)

    @Test func oneNotchMovesTheConfiguredDistanceAtTheConfiguredSpeed() {
        var motion = WheelSwipeMotion()
        let down = motion.addLines(1, at: (10, 100), tuning: tuning, dpi: 160, displayWidth: 200, displayHeight: 800)
        #expect(down == WheelSwipeMotion.Sample(x: 10, y: 100, pressure: 1000))
        // 1600 dp/s at 160 dpi is 1600 px/s; 0.05 s is 80 px of the 160 px stroke.
        let step = motion.advance(dt: 0.05, tuning: tuning, dpi: 160, displayHeight: 800)
        #expect(step == WheelSwipeMotion.Sample(x: 10, y: 180, pressure: 1000))
        let done = motion.advance(dt: 0.05, tuning: tuning, dpi: 160, displayHeight: 800)
        #expect(done == WheelSwipeMotion.Sample(x: 10, y: 260, pressure: 1000))
        #expect(motion.advance(dt: 0.05, tuning: tuning, dpi: 160, displayHeight: 800) == nil)
        #expect(motion.isIdle)
        #expect(motion.lift() == WheelSwipeMotion.Sample(x: 10, y: 260, pressure: 0))
        #expect(!motion.isDown)
    }

    @Test func negativeNotchMovesTheFingerUp() {
        var motion = WheelSwipeMotion()
        _ = motion.addLines(-1, at: (4, 200), tuning: tuning, dpi: 160, displayWidth: 100, displayHeight: 800)
        let done = motion.advance(dt: 1, tuning: tuning, dpi: 160, displayHeight: 800)
        #expect(done == WheelSwipeMotion.Sample(x: 4, y: 40, pressure: 1000))
        #expect(motion.isIdle)
    }

    @Test func distanceScalesWithDensity() {
        var motion = WheelSwipeMotion()
        _ = motion.addLines(1, at: (0, 100), tuning: tuning, dpi: 320, displayWidth: 400, displayHeight: 2000)
        let done = motion.advance(dt: 1, tuning: tuning, dpi: 320, displayHeight: 2000)
        #expect(done?.y == 100 + 320)
    }

    @Test func furtherNotchesExtendTheSameFingerAndAReverseTurnsAround() {
        var motion = WheelSwipeMotion()
        #expect(motion.addLines(1, at: (4, 400), tuning: tuning, dpi: 160, displayWidth: 100, displayHeight: 2000) != nil)
        #expect(motion.addLines(1, at: (9, 10), tuning: tuning, dpi: 160, displayWidth: 100, displayHeight: 2000) == nil)
        #expect(motion.addLines(-1, at: (9, 10), tuning: tuning, dpi: 160, displayWidth: 100, displayHeight: 2000) == nil)
        let done = motion.advance(dt: 1, tuning: tuning, dpi: 160, displayHeight: 2000)
        // The reverse discards the queued downward travel and keeps the original X.
        #expect(done == WheelSwipeMotion.Sample(x: 4, y: 240, pressure: 1000))
    }

    @Test func fastWheelDoesNotQueueMoreThanAFewNotches() {
        var motion = WheelSwipeMotion()
        _ = motion.addLines(1, at: (20, 100), tuning: tuning, dpi: 160, displayWidth: 400, displayHeight: 2000)
        for _ in 0..<5 {
            #expect(motion.addLines(1, at: (20, 100), tuning: tuning, dpi: 160, displayWidth: 400, displayHeight: 2000) == nil)
        }
        let done = motion.advance(dt: 10, tuning: tuning, dpi: 160, displayHeight: 2000)
        // Outstanding travel stays at 3 notches (480 px), not the 6 that arrived.
        #expect(done?.y == 580)
        #expect(motion.isIdle)
    }

    @Test func strokeDoesNotStartOffTheEdge() {
        var motion = WheelSwipeMotion()
        #expect(motion.addLines(1, at: (5, 799), tuning: tuning, dpi: 160, displayWidth: 100, displayHeight: 800) == nil)
        #expect(!motion.isDown)
        #expect(motion.addLines(-1, at: (5, 0), tuning: tuning, dpi: 160, displayWidth: 100, displayHeight: 800) == nil)
        #expect(motion.lift() == nil)
    }

    @Test func trackpadPixelsScaleWithTheDistanceSetting() {
        var motion = WheelSwipeMotion()
        let normal = WheelSwipeTuning()
        _ = motion.add(.pixels(-60), at: (10, 200), tuning: normal, dpi: 160, displayWidth: 100, displayHeight: 800)
        let done = motion.advance(dt: 1, tuning: normal, dpi: 160, displayHeight: 800)
        #expect(done == WheelSwipeMotion.Sample(x: 10, y: 140, pressure: 1000))

        var longer = WheelSwipeMotion()
        let doubled = WheelSwipeTuning(distanceDP: 360, speedDPPerSecond: 2400)
        _ = longer.add(.pixels(-60), at: (10, 200), tuning: doubled, dpi: 160, displayWidth: 100, displayHeight: 800)
        let far = longer.advance(dt: 1, tuning: doubled, dpi: 160, displayHeight: 800)
        #expect(far == WheelSwipeMotion.Sample(x: 10, y: 80, pressure: 1000))
    }

    @Test func strokeStopsAtTheEdge() {
        var motion = WheelSwipeMotion()
        _ = motion.addLines(1, at: (5, 700), tuning: tuning, dpi: 160, displayWidth: 100, displayHeight: 800)
        let done = motion.advance(dt: 1, tuning: tuning, dpi: 160, displayHeight: 800)
        #expect(done?.y == 799)
        #expect(motion.isIdle)
    }
}

@Suite struct WheelSwipeDriverTests {
    private actor Log {
        var samples: [WheelSwipeMotion.Sample] = []
        func add(_ sample: WheelSwipeMotion.Sample) { samples.append(sample) }
    }

    private func tuning(speed: Int = 32_000) -> WheelSwipeTuning {
        WheelSwipeTuning(distanceDP: 160, speedDPPerSecond: speed)
    }

    @Test func strokeEndsWithALiftAfterTheConfiguredDistance() async {
        let log = Log()
        let driver = WheelSwipeDriver(tick: .milliseconds(5))
        let accepted = await driver.wheel(
            .lines(1), x: 40, y: 100, tuning: tuning(), dpi: 160, width: 200, height: 800
        ) { await log.add($0) }
        #expect(accepted)
        await driver.waitUntilIdle()
        let samples = await log.samples
        #expect(samples.first == WheelSwipeMotion.Sample(x: 40, y: 100, pressure: 1000))
        #expect(samples.last == WheelSwipeMotion.Sample(x: 40, y: 260, pressure: 0))
        #expect(samples.filter { $0.pressure == 0 }.count == 1)
    }

    @Test func notchDuringTheStrokeExtendsIt() async {
        let log = Log()
        let driver = WheelSwipeDriver(tick: .milliseconds(5))
        let tuning = tuning()
        let accepted = await driver.wheel(
            .lines(1), x: 40, y: 100, tuning: tuning, dpi: 160, width: 200, height: 800
        ) { sample in
            await log.add(sample)
            if sample.pressure == 1000, sample.y == 100 {
                await driver.wheel(.lines(1), x: 80, y: 100, tuning: tuning, dpi: 160, width: 200, height: 800) { await log.add($0) }
            }
        }
        #expect(accepted)
        await driver.waitUntilIdle()
        let samples = await log.samples
        #expect(samples.first?.pressure == 1000)
        #expect(samples.last == WheelSwipeMotion.Sample(x: 40, y: 420, pressure: 0))
        #expect(samples.allSatisfy { $0.x == 40 })
    }

    @Test func cancelLiftsTheFinger() async {
        let log = Log()
        let driver = WheelSwipeDriver(tick: .milliseconds(5))
        await driver.wheel(
            .lines(1), x: 40, y: 100, tuning: tuning(speed: 400), dpi: 160, width: 200, height: 800
        ) { sample in
            await log.add(sample)
            if sample.pressure == 1000, sample.y == 100 {
                await driver.cancel()
            }
        }
        await driver.waitUntilIdle()
        let samples = await log.samples
        #expect(samples.first == WheelSwipeMotion.Sample(x: 40, y: 100, pressure: 1000))
        #expect(samples.last == WheelSwipeMotion.Sample(x: 40, y: 100, pressure: 0))
        #expect(samples.count == 2)
    }
}
