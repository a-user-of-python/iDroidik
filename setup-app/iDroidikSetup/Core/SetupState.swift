import Foundation
import SwiftUI
import Combine

/// Steps of the setup wizard, in order.
enum SetupStep: Int, CaseIterable {
    case welcome = 0
    case preflight
    case volume
    case download
    case firmware
    case userdata
    case done

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .preflight: return "Checks"
        case .volume: return "Storage Volume"
        case .download: return "Android Image"
        case .firmware: return "Firmware"
        case .userdata: return "Persistent Data"
        case .done: return "Finished"
        }
    }
}

/// Shared observable state for the whole wizard.
final class SetupState: ObservableObject {
    @Published var currentStep: SetupStep = .welcome
    @Published var log: [String] = []
    @Published var isWorking: Bool = false
    @Published var progress: Double = 0.0          // 0..1 for the active step
    @Published var progressLabel: String = ""
    @Published var lastError: String? = nil

    // Preflight results
    @Published var deviceModel: String = ""
    @Published var iosVersion: String = ""
    @Published var isRoot: Bool = false
    @Published var freeBytes: Int64 = 0
    @Published var preflightPassed: Bool = false

    // Volume
    @Published var androidVolumeDevice: String = ""
    @Published var volumeExisted: Bool = false
    @Published var volumeConfirmed: Bool = false

    // Download
    @Published var imageAlreadyPresent: Bool = false

    // Firmware
    @Published var firmwareFileCount: Int = 0

    // Userdata
    @Published var userdataGB: Int = 6
    @Published var userdataNonce: String = ""
    @Published var userdataSkipped: Bool = false

    // Constants
    let expectedImageSHA256 = "437cf287068e2b0ffd17225d1309314aa108437a62fb187d53ed31a93f39dfe1"
    let releaseBaseURL = "https://github.com/a-user-of-python/iDroidik/releases/download/v0.1-exp"
    let imageName = "nand-a16"
    let mountPoint = "/var/mnt/android"
    let androidVolumeLabel = "Android"

    /// Estimated image size (~3 GB). Refined once the parts manifest is read.
    @Published var estimatedImageBytes: Int64 = 3_221_225_472

    func appendLog(_ message: String) {
        DispatchQueue.main.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            self.log.append("[\(stamp)] \(message)")
        }
    }

    func fail(_ message: String) {
        DispatchQueue.main.async {
            self.lastError = message
            self.isWorking = false
        }
        appendLog("ERROR: \(message)")
    }

    /// Required free space: image + userdata + 3 GB iOS headroom.
    var requiredFreeBytes: Int64 {
        estimatedImageBytes + Int64(userdataGB) * 1_073_741_824 + 3 * 1_073_741_824
    }
}
