import AppKit

if let flag = CommandLine.arguments.firstIndex(of: "--transcribe") {
    guard flag + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: Murmur --transcribe <audio file>\n".utf8))
        exit(2)
    }
    CLI.transcribe(path: CommandLine.arguments[flag + 1], useMyDictionary: CommandLine.arguments.contains("--my-dictionary"), pauses: !CommandLine.arguments.contains("--no-pauses"))
}

if let flag = CommandLine.arguments.firstIndex(of: "--render-hud") {
    guard flag + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: Murmur --render-hud <folder>\n".utf8))
        exit(2)
    }
    MainActor.assumeIsolated { CLI.renderHUD(into: CommandLine.arguments[flag + 1]) }
}

if let flag = CommandLine.arguments.firstIndex(of: "--render-window") {
    guard flag + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: Murmur --render-window <folder>\n".utf8))
        exit(2)
    }
    MainActor.assumeIsolated { CLI.renderWindows(into: CommandLine.arguments[flag + 1]) }
}

if let flag = CommandLine.arguments.firstIndex(of: "--mic-test") {
    let seconds = flag + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[flag + 1]) ?? 2 : 2
    CLI.micTest(seconds: seconds)
}

if CommandLine.arguments.contains("--selftest-model") {
    MainActor.assumeIsolated { CLI.selfTestModel() }
}

if let flag = CommandLine.arguments.firstIndex(of: "--render-icon") {
    guard flag + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: Murmur --render-icon <iconset folder>\n".utf8))
        exit(2)
    }
    exit(MainActor.assumeIsolated { IconRenderer.render(into: CommandLine.arguments[flag + 1]) } ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar app: no Dock icon.
    app.setActivationPolicy(.accessory)
    app.run()
}
