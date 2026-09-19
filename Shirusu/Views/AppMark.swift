import AppKit
import SwiftUI

/// The app's own icon, so this never drifts from what the Dock shows.
///
/// `NSApp.applicationIconImage` is the obvious route but it answers for the
/// *running* process, which in a SwiftUI preview is the preview host, not
/// Shirusu. Reading `CFBundleIconName` and asking the asset catalog is what the
/// system itself does, and it works in both places.
struct AppMark: View {
    var size: CGFloat = 96

    var body: some View {
        Image(nsImage: Self.icon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static let icon: NSImage = {
        let info = Bundle.main.infoDictionary
        for key in ["CFBundleIconName", "CFBundleIconFile"] {
            if let name = info?[key] as? String, let image = NSImage(named: name) {
                return image
            }
        }
        if let running = NSApp?.applicationIconImage { return running }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }()
}
