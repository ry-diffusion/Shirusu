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

    /// Builds the window and its hosting view without showing either.
    ///
    /// The first press of the Globe key otherwise pays for an `NSPanel`, an
    /// `NSHostingView` and the first layout of a Liquid Glass capsule, on top
    /// of opening the microphone and waking the recogniser. None of that is
    /// visible work, and all of it can be done at launch instead.
    func prepare(_ content: some View) {
        guard panel == nil else { return }
        let panel = makePanel()
        panel.contentView = glassContent(for: content)
        panel.setFrame(Self.frame, display: false)
        // Laid out, so the first real show is not the first layout, but never
        // ordered front: `alphaValue` is left at zero until `show` raises it.
        panel.alphaValue = 0
        panel.contentView?.layoutSubtreeIfNeeded()
        self.panel = panel
    }

    func show(_ content: some View) {
        dismissal?.cancel()
        dismissal = nil

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = glassContent(for: content)
        // Always, not only on first show: the screen can change under it.
        panel.setFrame(Self.frame, display: false)
        // The hosting view must be in a window to observe transcript changes,
        // but an empty Live Captions run should not leave a glass bar onscreen.
        // Keep it ordered at zero alpha until CaptionView reports content.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isVisible = false
    }

    /// Called by CaptionView whenever its content becomes meaningful or empty.
    /// This is intentionally at the panel level: hiding the SwiftUI child alone
    /// leaves the panel's own Liquid Glass surface visible.
    func setContentVisible(_ visible: Bool) {
        guard let panel else { return }

        if visible {
            guard !isVisible else { return }
            isVisible = true
            let destination = Self.frame
            panel.setFrame(destination.offsetBy(dx: 0, dy: -14), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.duration
                context.timingFunction = Self.settle
                panel.animator().alphaValue = 1
                panel.animator().setFrame(destination, display: true)
            }
            return
        }

        guard isVisible else { return }
        dismiss()
    }

    /// Gives the whole nonactivating panel a native Liquid Glass backing.
    /// `CaptionView` still owns the close-fitting capsule and its state rim;
    /// this outer glass is the surface visible behind it and refracts the app
    /// below instead of leaving a transparent rectangular window around it.
    private func glassContent(for content: some View) -> NSGlassEffectView {
        let host = NSHostingView(rootView: AnyView(content))
        // A hosting view that paints its own backing would hide the glass.
        host.layer?.backgroundColor = nil
        host.sizingOptions = []

        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Self.frame.size))
        glass.style = .regular
        glass.cornerRadius = Self.height / 2
        glass.contentView = host
        return glass
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        dismiss()
    }

    /// Leaves the way it arrived: sinking and fading, not blinking out.
    private func dismiss() {
        guard let panel else {
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
        } completionHandler: { [weak self] in
            // Run on the main thread, which is where the animation was started.
            MainActor.assumeIsolated {
                // Something may have asked for the bar again during the third
                // of a second this took to leave. If it did, it is mid-entrance
                // now, and ordering it out from under itself left a panel that
                // believed it was visible and so refused to come back.
                guard self?.isVisible != true else { return }
                panel.orderOut(nil)
                panel.setFrame(origin, display: false)
                panel.alphaValue = 1
            }
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
    /// The glass panel is deliberately wider than the caption itself, so its
    /// position stays fixed while words land and the inner capsule resizes.
    private static let width: CGFloat = 400
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
