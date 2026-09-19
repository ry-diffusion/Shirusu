import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import OSLog

/// Watches the Globe (fn) key so dictation can start the instant it goes down.
///
/// Two things gate this and neither is in the app's gift:
///
/// 1. macOS routes Globe to the emoji picker or input-source switcher by default.
///    The user has to set System Settings → Keyboard → "Press 🌐 to" → "Do Nothing".
/// 2. Reading modifier keys while another app is frontmost needs an event tap,
///    which needs Accessibility permission.
///
/// The tap is listen-only, so it observes the key without swallowing it. Once the
/// interaction is settled, switching `tapOption` to `.defaultTap` and returning
/// `nil` from the callback would consume the press instead.
@MainActor
@Observable
final class GlobeHotkeyMonitor {
    enum Availability: Equatable {
        case off
        case needsAccessibilityPermission
        case active
        case failed
    }

    private(set) var availability: Availability = .off
    /// True while the Globe key is physically down.
    private(set) var isHeld = false

    /// Fired on key-down and key-up. Assigned by whoever owns the monitor.
    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "hotkey")

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Asks for Accessibility, then opens the pane regardless.
    ///
    /// macOS shows the system prompt only the *first* time a given app asks.
    /// Every call after that returns silently, so a button wired only to the
    /// prompt looks broken to anyone who has already dismissed it once. Opening
    /// the settings pane is the part that always does something.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    /// Where the app lives, so it can be dragged into the Accessibility list.
    /// Running from DerivedData makes this non-obvious.
    var bundleURL: URL { Bundle.main.bundleURL }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    /// Accessibility is granted outside the app, so the only way to notice is
    /// to look again. Called when the window comes back to the front.
    func recheck() {
        guard availability != .active else { return }
        if hasAccessibilityPermission { _ = enable() }
        else { availability = .needsAccessibilityPermission }
    }

    @discardableResult
    func enable() -> Bool {
        guard tap == nil else { return true }

        guard hasAccessibilityPermission else {
            availability = .needsAccessibilityPermission
            return false
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, _, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<GlobeHotkeyMonitor>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    let isDown = event.flags.contains(.maskSecondaryFn)
                    // The tap is attached to the main run loop, so this callback
                    // is already on the main thread.
                    MainActor.assumeIsolated { monitor.handle(isDown: isDown) }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            log.error("Could not create the Globe key event tap")
            availability = .failed
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        availability = .active
        log.info("Globe key monitor active")
        return true
    }

    func disable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isHeld = false
        availability = .off
    }

    private func handle(isDown: Bool) {
        guard isDown != isHeld else { return }
        isHeld = isDown
        log.notice("Globe key \(isDown ? "down" : "up", privacy: .public)")
        if isDown { onPress?() } else { onRelease?() }
    }

    /// True when macOS is set to leave the Globe key alone. Otherwise the
    /// system claims it for the emoji picker or input-source switch and the
    /// press never reaches an event tap.
    var isGlobeKeyFree: Bool {
        // Absent means the stock behaviour, which is the emoji picker.
        guard let usage = UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?[
            "AppleFnUsageType"] as? Int
        else { return false }
        return usage == 0
    }
}
