// Tiny background-only helper bundled as Contents/Helpers/<Action>.app.
//
// Tools that can only "open an application" (e.g. Logi Options+ Smart
// Actions, Stream Deck, BetterTouchTool) launch one of these helpers. It
// forwards the `YQCCommandURL` from its Info.plist to Yeelight QuickControl
// (launching it if needed) and exits immediately — no Dock icon, no window.

import AppKit

guard let text = Bundle.main.object(forInfoDictionaryKey: "YQCCommandURL") as? String,
      let url = URL(string: text) else {
    NSLog("[YQC helper] Missing YQCCommandURL in Info.plist")
    exit(1)
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
let done = DispatchSemaphore(value: 0)
var failed = false
NSWorkspace.shared.open(url, configuration: configuration) { _, error in
    if let error {
        NSLog("[YQC helper] Could not open %@: %@", text, error.localizedDescription)
        failed = true
    }
    done.signal()
}
_ = done.wait(timeout: .now() + 5)
exit(failed ? 1 : 0)
