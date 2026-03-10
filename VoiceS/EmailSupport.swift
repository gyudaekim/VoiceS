import Foundation
import SwiftUI
import AppKit

struct EmailSupport {
    static func openSupportEmail() {
        if let projectURL = URL(string: "https://github.com/gdkim/VoiceS") {
            NSWorkspace.shared.open(projectURL)
        }
    }
}
