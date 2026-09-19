import AppKit
import Observation
import SwiftUI

/// The caption slab, as an AppKit panel rather than a SwiftUI scene.
///
/// Two things a `Window` scene cannot do, and this feature needs both: appear
/// while the main window is closed, and take no focus. A caption that activates
/// Shirusu would pull the cursor out of whatever the user is dictating into,
/// which defeats the point — hence `.nonactivatingPanel`.
@MainActor
@Observable
final class CaptionPanel {
    /// Stored rather than read back off the panel, so a view can observe it.
    /// `NSPanel.isVisible` is invisible to SwiftUI, which left the button that
    /// toggles the bar showing the wrong verb until something else redrew it.
    private(set) var isVisible = false

    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    func show(_ content: some View) {
        dismissal?.cancel()
        dismissal = nil

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: AnyView(content))
        // Without this the hosting view paints an opaque backing and the glass
        // has nothing to be transparent against.
        host.layer?.backgroundColor = nil
        // And without this it can drive the window's size from the content,
        // which is how an 800-point bar ended up wider than the screen.
        host.sizingOptions = []

        let wasVisible = panel.isVisible
        panel.contentView = host
        // Always, not only on first show: the screen can change under it.
        panel.setFrame(Self.frame, display: false)

        // Ordering front without activating: the caption appears, the caret
        // stays where the user left it.
        isVisible = true

        guard !wasVisible else {
            panel.orderFrontRegardless()
            return
        }

        // Rises into place from just below, which is where it will sink back to.
        let destination = Self.frame
        panel.setFrame(destination, display: false)
        panel.setFrame(destination.offsetBy(dx: 0, dy: -14), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = Self.settle
            panel.animator().alphaValue = 1
            panel.animator().setFrame(destination, display: true)
        }
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        dismiss()
    }

    /// Leaves the way it arrived: sinking and fading, not blinking out.
    private func dismiss() {
        guard let panel, panel.isVisible else {
            isVisible = false
            return
        }
        isVisible = false
        let origin = panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = Self.settle
            panel.animator().alphaValue = 0
            panel.animator().setFrame(origin.offsetBy(dx: 0, dy: -14), display: true)
        } completionHandler: {
            panel.orderOut(nil)
            panel.setFrame(origin, display: false)
            panel.alphaValue = 1
        }
    }

    /// Leaves the text up long enough to be read, then clears it away.
    func hide(after seconds: Double) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: Self.frame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Follow the user across desktops and over full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
        // Pinned to the dark rendering of the material, which is what makes a
        // caption readable at all. Left to follow the system, the glass renders
        // light and `Color.primary` resolves to black — black text over a blue
        // desktop, which is what this is fixing. Dark glass darkens whatever is
        // behind it enough for light text to hold over any backdrop, bright
        // document or dark editor alike. It is why every caption surface, on
        // every platform, is a dark plate with light text.
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    /// A bound, not a size.
    ///
    /// The window itself is invisible and never moves; the capsule inside it is
    /// the only thing seen, and that one is sized to the sentence. This just
    /// has to be wider than the capsule can ever get, so that finding its width
    /// is never a reason for the window to find a new position.
    private static let width: CGFloat = 520
    /// One line of caption plus its padding.
    private static let height: CGFloat = 56

    /// Critically damped: nothing here is thrown by a gesture, so nothing here
    /// should overshoot. Matches the app's `Motion.settle`.
    private static let duration: TimeInterval = 0.34
    private static let settle = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.24, 1)

    /// The one place screen geometry is decided, so every path agrees.
    private static var frame: NSRect {
        guard let screen = activeScreen else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let visible = screen.visibleFrame

        // Narrow the bar rather than let it hang off a small display.
        let barWidth = min(width, visible.width - 48)
        let x = (visible.midX - barWidth / 2).rounded()
        let y = (visible.minY + 110).rounded()

        return NSRect(
            // Clamped, so an odd screen arrangement cannot push it out of view.
            x: min(max(x, visible.minX + 24), visible.maxX - barWidth - 24),
            y: min(max(y, visible.minY + 24), visible.maxY - height - 24),
            width: barWidth,
            height: height
        )
    }

    /// The screen the user is actually looking at.
    ///
    /// `NSScreen.main` is the screen holding the window with keyboard focus,
    /// and this panel is deliberately never that window — so on a multi-display
    /// Mac it can answer for the wrong one. The pointer is the better guess.
    private static var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
