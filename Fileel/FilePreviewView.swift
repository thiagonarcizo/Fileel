import AppKit
import QuickLookUI
import SwiftUI

// quick look handles document, archive, and other previews through the system's own generators
struct FilePreviewView: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL? { view.previewItem = url as NSURL? }
    }
}
