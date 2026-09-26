import AppKit

// Ask hands the command-line agents the document's tools through the app's own
// executable, started with this flag. It answers on standard output and never
// becomes an app: no Dock icon, no windows, no activation.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == AskMCPServer.flag {
    AskMCPServer.run(documentPath: CommandLine.arguments[2])
}

// SwiftPM builds a plain executable, so the NSApplication bootstrap that
// @main would normally generate is done by hand here.
let application = NSApplication.shared
let controller = AppDelegate()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
