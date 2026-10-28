import AppKit
import AVFoundation
import ApplicationServices

/// The three things macOS makes you allow before a dictation app can work.
enum Permission: CaseIterable {
    case microphone, accessibility, inputMonitoring

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    /// Why Murmur needs it, in words for the menu.
    var reason: String {
        switch self {
        case .microphone: "to hear you"
        case .accessibility: "to type the text for you"
        case .inputMonitoring: "to notice when you hold the dictation key"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }

    private var settingsPage: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
    }

    /// Shows macOS's own prompt where one exists (this also adds Murmur to the right list), then opens that Settings page.
    func fix() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                return
            }
        case .accessibility:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPage)") {
            NSWorkspace.shared.open(url)
        }
    }
}
