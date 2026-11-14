import AppKit

// IntentScreen — the kiosk intent screen. Started at login by the LaunchAgent
// com.intentmode.screen (KeepAlive: relaunched if it crashes or is killed).

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
