import Foundation
import SwiftUI

/// The app, or the command line, depending on how the binary was started.
///
/// One binary for both because the app is sandboxed. A separate tool would
/// live outside the container, so it would see none of the models already
/// downloaded or the voices already saved, and would fetch gigabytes again to
/// sit beside them. Run from here, the command line shares the container, and
/// the sandbox stays exactly as tight as it is: files come in on stdin and go
/// out on stdout, so the process never needs a path outside its own walls.
/// The `shirusu` script in `CLI/` is what turns paths into those redirects.
@main
enum Launcher {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == CommandLineTool.flag else {
            ShirusuApp.main()
            return
        }
        CommandLineTool.start(Array(arguments.dropFirst()))
        // The tool exits the process itself when its work is done.
        dispatchMain()
    }
}
