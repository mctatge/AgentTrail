import AppKit
import SwiftUI

struct NonblockingSheet: NSViewRepresentable {
    func makeNSView(context: Context) -> SheetTerminationView { SheetTerminationView() }
    func updateNSView(_ view: SheetTerminationView, context: Context) {}
}

final class SheetTerminationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.preventsApplicationTerminationWhenModal = false
    }
}
