import AppKit

// Started by one of Ask's command-line agents, as its tool server or its hook,
// the app serves it and exits before it becomes an app: no Dock icon, no
// windows, no activation.
AgentTransport.serveIfAsked()

// SwiftPM builds a plain executable, so the NSApplication bootstrap that
// @main would normally generate is done by hand here.
let application = NSApplication.shared
let controller = AppDelegate()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
