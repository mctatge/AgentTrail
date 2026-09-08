import AppKit
import ScreenCaptureKit
import TrailCore

final class ScreenshotCapture {
    private var busy = false
    private var lastCapture = Date.distantPast

    func request(pid: Int32, completion: @escaping (Data?, String?) -> Void) {
        guard !busy, Date().timeIntervalSince(lastCapture) >= 1 else { return }
        busy = true
        lastCapture = Date()
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let available = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let window = available.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100 }) else {
                    completion(nil, "No capturable foreground window")
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.width = min(2560, Int(window.frame.width * 2))
                configuration.height = max(1, Int(Double(configuration.width) * window.frame.height / window.frame.width))
                configuration.showsCursor = true
                let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let representation = NSBitmapImageRep(cgImage: screenshot)
                completion(representation.representation(using: .jpeg, properties: [.compressionFactor: 0.72]), nil)
            } catch { completion(nil, error.localizedDescription) }
        }
    }
}
