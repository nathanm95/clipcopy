import AppKit

let arguments = CommandLine.arguments

// Test and tooling modes, which exit without starting the app.
if arguments.contains("--self-test") {
    exit(MainActor.assumeIsolated { SelfTest.run() } ? 0 : 1)
}
if let index = arguments.firstIndex(of: "--render-test"), index + 1 < arguments.count {
    exit(MainActor.assumeIsolated { RenderTest.run(into: URL(fileURLWithPath: arguments[index + 1])) } ? 0 : 1)
}
if let index = arguments.firstIndex(of: "--write-iconset"), index + 1 < arguments.count {
    do {
        try Paperclip.writeIconset(to: URL(fileURLWithPath: arguments[index + 1]))
        exit(0)
    } catch {
        print("Couldn't write the iconset: \(error)")
        exit(1)
    }
}
if let index = arguments.firstIndex(of: "--fill"), index + 1 < arguments.count, let count = Int(arguments[index + 1]) {
    let options = LaunchOptions(arguments: arguments)
    guard options.usesCustomDataDirectory else {
        print("--fill needs --data-dir <folder>, so it never touches your real history.")
        exit(1)
    }
    exit(MainActor.assumeIsolated { TestData.fill(directory: options.dataDirectory, count: count) } ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: LaunchOptions(arguments: arguments))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
    // `run()` only returns when the app quits; this keeps the delegate alive until then.
    withExtendedLifetime(delegate) {}
}
