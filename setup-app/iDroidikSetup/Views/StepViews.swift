import SwiftUI

// MARK: - Shared bits

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .padding(.bottom, 4)
    }
}

struct BodyText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title3)
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WarningBox: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title3.bold())
            .foregroundColor(.yellow)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow, lineWidth: 2))
    }
}

struct ProgressSection: View {
    @EnvironmentObject var state: SetupState
    var body: some View {
        if state.isWorking || state.progress > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.progressLabel)
                    .font(.title3)
                    .foregroundColor(.secondary)
                ProgressView(value: state.progress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .scaleEffect(x: 1, y: 2.5, anchor: .center)
                Text("\(Int(state.progress * 100))%")
                    .font(.title2.monospacedDigit().bold())
            }
            .padding(.vertical, 8)
        }
    }
}

struct LogView: View {
    @EnvironmentObject var state: SetupState
    var body: some View {
        if !state.log.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Log")
                    .font(.headline)
                    .foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.log.suffix(30), id: \.self) { line in
                            Text(line)
                                .font(.footnote.monospaced())
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .padding(8)
                .background(Color.black.opacity(0.4))
                .cornerRadius(10)
            }
        }
    }
}

// MARK: - Steps

struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "Install Android on this iPhone")
            BodyText(text: "This app sets up your iPhone 7 to boot Android 16 (iDroidik). Everything happens on this phone — no computer needed for setup.")
            WarningBox(text: "⚠️ NEVER restore or erase this iPhone. Setup only ADDS a storage volume — your iOS stays untouched.")
            BodyText(text: "You will need:")
            VStack(alignment: .leading, spacing: 8) {
                BulletRow("iPhone 7 on iOS 15, jailbroken (you are)")
                BulletRow("About 12 GB free space (3 GB image + 6 GB data + headroom)")
                BulletRow("Wi-Fi (downloads ~3 GB)")
                BulletRow("20–40 minutes")
            }
            BodyText(text: "After setup, you boot Android from a computer over USB (tethered). Going back to iOS is just a reboot.")
        }
    }
}

struct BulletRow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("•").font(.title2.bold()).foregroundColor(.blue)
            Text(text).font(.title3)
        }
    }
}

struct PreflightStep: View {
    @EnvironmentObject var state: SetupState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "Device Checks")
            BodyText(text: "Verifying this phone can run the setup.")
            if state.preflightPassed {
                CheckRow(label: "Running as root", value: "uid 0 ✓", ok: true)
                CheckRow(label: "Device", value: state.deviceModel, ok: true)
                CheckRow(label: "iOS", value: state.iosVersion, ok: true)
                CheckRow(label: "Free space", value: formatGB(state.freeBytes), ok: state.freeBytes > state.requiredFreeBytes)
                if state.freeBytes <= state.requiredFreeBytes {
                    WarningBox(text: "Low space: need ~\(formatGB(state.requiredFreeBytes)) free (image + \(state.userdataGB) GB data + 3 GB iOS headroom). Free space in iOS Settings first.")
                }
            } else {
                BodyText(text: "Tap \"Run Checks\" below.")
            }
            LogView()
        }
    }

    private func formatGB(_ b: Int64) -> String {
        String(format: "%.1f GB", Double(b) / 1_073_741_824.0)
    }
}

struct CheckRow: View {
    let label: String
    let value: String
    let ok: Bool
    var body: some View {
        HStack {
            Text(label).font(.title3)
            Spacer()
            Text(value).font(.title3.bold()).foregroundColor(ok ? .green : .red)
        }
        .padding(.vertical, 4)
    }
}

struct VolumeStep: View {
    @EnvironmentObject var state: SetupState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "Android Storage")
            if state.volumeExisted {
                BodyText(text: "Found an existing Android volume (\(state.androidVolumeDevice)). It will be reused — nothing is erased.")
            } else {
                BodyText(text: "No Android volume found. The app will create one inside your iPhone's storage container.")
                WarningBox(text: "This ADDS a volume. It does not erase iOS or any of your data. ~\(state.userdataGB + 4) GB will be reserved.")
                Toggle(isOn: $state.volumeConfirmed) {
                    Text("I understand — create the Android volume")
                        .font(.title3.bold())
                }
                .padding()
                .background(Color.blue.opacity(0.12))
                .cornerRadius(12)
            }
            LogView()
        }
    }
}

struct DownloadStep: View {
    @EnvironmentObject var state: SetupState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "Android Image")
            if state.imageAlreadyPresent {
                BodyText(text: "The Android image is already on the phone and verified. Nothing to download.")
            } else {
                BodyText(text: "Downloads the Android 16 image (~3 GB) from the iDroidik release and verifies its checksum. This takes a while on Wi-Fi.")
                WarningBox(text: "Keep the app open and the phone awake during the download.")
            }
            ProgressSection()
            LogView()
        }
    }
}

struct FirmwareStep: View {
    @EnvironmentObject var state: SetupState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "Touch + Wi-Fi Firmware")
            BodyText(text: "Copies the touchscreen and Wi-Fi firmware from YOUR OWN iOS into the Android volume. Nothing is downloaded — this is how the project stays legal.")
            if state.firmwareFileCount > 0 {
                CheckRow(label: "Firmware files", value: "\(state.firmwareFileCount)", ok: true)
            }
            LogView()
        }
    }
}

struct UserdataStep: View {
    @EnvironmentObject var state: SetupState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "Persistent Data")
            BodyText(text: "Creates userdata.img so your apps and settings survive reboots. Without it, Android's /data is wiped every boot.")
            HStack {
                Text("Size:").font(.title2.bold())
                Spacer()
                Picker("", selection: $state.userdataGB) {
                    ForEach([2, 4, 6, 8, 12, 16], id: \.self) { gb in
                        Text("\(gb) GB").tag(gb).font(.title2)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .font(.title2)
            }
            .padding()
            .background(Color.gray.opacity(0.15))
            .cornerRadius(12)
            Toggle(isOn: $state.userdataSkipped) {
                Text("Skip (I want RAM-only /data)")
                    .font(.title3)
            }
            if !state.userdataSkipped {
                WarningBox(text: "Writing \(state.userdataGB) GB takes 3–8 minutes. Keep the phone awake.")
            }
            ProgressSection()
            LogView()
        }
        .disabled(state.isWorking)
    }
}

struct DoneStep: View {
    @EnvironmentObject var state: SetupState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(text: "✅ Setup Complete")
            BodyText(text: "Your iPhone 7 is ready to boot Android 16.")
            VStack(alignment: .leading, spacing: 10) {
                SummaryRow("Android image", state.imageAlreadyPresent ? "already present ✓" : "downloaded ✓")
                SummaryRow("Firmware files", "\(state.firmwareFileCount)")
                if state.userdataSkipped {
                    SummaryRow("Persistent /data", "skipped (RAM-only)")
                } else {
                    SummaryRow("Persistent /data", "\(state.userdataGB) GB ✓")
                    if !state.userdataNonce.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Boot nonce (save this):").font(.title3.bold())
                            Text(state.userdataNonce)
                                .font(.title2.monospaced().bold())
                                .padding()
                                .background(Color.black.opacity(0.4))
                                .cornerRadius(10)
                                .textSelection(.enabled)
                            Text("The boot script needs this as androidboot.sc_userdata. It's also saved at /var/mnt/android/userdata-a16.conf on the phone.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(Color.green.opacity(0.08))
            .cornerRadius(14)

            SectionTitle(text: "Next: boot Android")
            BodyText(text: "1. Build the USB loaders on your Intel Mac (3 commands — see the repo README).\n2. Connect the phone, enter DFU, run the boot script.\n3. To return to iOS: just reboot.")
            LogView()
        }
    }
}

struct SummaryRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label; self.value = value
    }
    var body: some View {
        HStack {
            Text(label).font(.title3)
            Spacer()
            Text(value).font(.title3.bold()).foregroundColor(.green)
        }
    }
}
