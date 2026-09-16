import AppKit

enum AppRunLoopTimer {
    static func schedule(interval: TimeInterval, repeats: Bool = true, block: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }
}
