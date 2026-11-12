import Cocoa

// Avoid starting the NSApplication run loop when unit test bundles are loaded under XCTest.
let isRunningTests = NSClassFromString("XCTestCase") != nil

// NSApplication's delegate is weak. Retain the delegate for the app's entire lifetime.
private var retainedQuickDictateDelegate: AppDelegate?

if !isRunningTests {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedQuickDictateDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
