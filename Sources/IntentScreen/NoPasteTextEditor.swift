import AppKit
import SwiftUI

/// A text view that refuses every way of inserting text other than typing:
/// paste (menu, ⌘V, ⌥⇧⌘V), drag and drop, and Services.
final class NoPasteTextView: NSTextView {
    override func paste(_ sender: Any?) { NSSound.beep() }
    override func pasteAsPlainText(_ sender: Any?) { NSSound.beep() }
    override func pasteAsRichText(_ sender: Any?) { NSSound.beep() }
    override func readSelection(from pboard: NSPasteboard) -> Bool { false }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { false }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        returnType != nil ? nil : super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
            NSSound.beep()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct NoPasteTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 17
    var focusOnAppear = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = NoPasteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.backgroundColor = NSColor(white: 0.16, alpha: 1)
        tv.drawsBackground = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.string = text
        scroll.documentView = tv
        if focusOnAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let tv = scroll.documentView as? NSTextView, tv.string != text { tv.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoPasteTextEditor
        init(_ p: NoPasteTextEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
