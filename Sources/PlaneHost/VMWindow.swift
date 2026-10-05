import AppKit
import Virtualization

/// A plain window showing a VM's display. Used for provisioning (interactive) and for watching
/// a session (input blocked unless the viewer takes control).
@MainActor
public final class VMWindow: NSObject, NSWindowDelegate {
    public let window: NSWindow
    private let view = VZVirtualMachineView()
    private let shield = InputShield()
    public var onClose: (() -> Void)?

    public init(vm: VZVirtualMachine, title: String, interactive: Bool) {
        view.virtualMachine = vm
        view.capturesSystemKeys = interactive
        if #available(macOS 14.0, *) { view.automaticallyReconfiguresDisplay = false }
        let size = NSSize(width: VMFactory.display.width, height: VMFactory.display.height)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentAspectRatio = size
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        shield.frame = container.bounds
        shield.autoresizingMask = [.width, .height]
        shield.isHidden = interactive
        container.addSubview(shield)
        window.contentView = container
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        window.center()
    }

    public var interactive: Bool {
        get { shield.isHidden }
        set { shield.isHidden = newValue; view.capturesSystemKeys = newValue }
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillClose(_ notification: Notification) { onClose?() }
}

/// Transparent overlay that swallows mouse and keyboard input in watch-only mode.
final class InputShield: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : self }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
}
