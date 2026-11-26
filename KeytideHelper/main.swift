import Foundation

guard Bundle.main.bundleIdentifier == HelperLocations.helperBundleId else {
    NSLog("[KeytideHelper] A matching app bundle is required")
    exit(EXIT_FAILURE)
}

let listener = HelperXPCListener()
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    listener.finish()
    exit(0)
}
termination.resume()
listener.resume()
NSLog("[KeytideHelper] listening on \(HelperLocations.machServiceName)")
CFRunLoopRun()
