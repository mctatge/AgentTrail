import Foundation

final class CaptureRunLoop {
    private var runLoop: CFRunLoop?
    private var finished: DispatchSemaphore?

    func start(install: @escaping () throws -> (() -> Void)) throws {
        precondition(runLoop == nil)
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var startupError: Error?
        let thread = Thread {
            do {
                let cleanup = try install()
                let current = CFRunLoopGetCurrent()!
                let keepAlive = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3600, 3600, 0, 0) { _ in }
                CFRunLoopAddTimer(current, keepAlive, .defaultMode)
                self.runLoop = current
                ready.signal()
                CFRunLoopRun()
                cleanup()
                CFRunLoopRemoveTimer(current, keepAlive, .defaultMode)
            } catch {
                startupError = error
                ready.signal()
            }
            finished.signal()
        }
        thread.name = "AgentTrail input capture"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if let startupError { finished.wait(); throw startupError }
        self.finished = finished
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { CFRunLoopStop(runLoop) }
        CFRunLoopWakeUp(runLoop)
        finished?.wait()
        self.runLoop = nil
        finished = nil
    }

    deinit { stop() }
}
