import SwiftUI

/// Step-by-step setup wizard. Large text, high contrast (user has bad vision).
struct ContentView: View {
    @EnvironmentObject var state: SetupState
    @StateObject private var runner = StepRunner()

    private func bindRunner() {
        if runner.currentState == nil {
            runner.currentState = state
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Step indicator
                StepProgressBar(current: state.currentStep.rawValue, total: SetupStep.allCases.count)
                    .padding()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch state.currentStep {
                        case .welcome: WelcomeStep()
                        case .preflight: PreflightStep()
                        case .volume: VolumeStep()
                        case .download: DownloadStep()
                        case .firmware: FirmwareStep()
                        case .userdata: UserdataStep()
                        case .done: DoneStep()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }

                // Error banner
                if let err = state.lastError {
                    Text(err)
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.85))
                }

                // Navigation buttons
                HStack(spacing: 16) {
                    if state.currentStep != .welcome && state.currentStep != .done {
                        Button("Back") {
                            state.lastError = nil
                            state.currentStep = SetupStep(rawValue: state.currentStep.rawValue - 1) ?? .welcome
                        }
                        .font(.title2.bold())
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(14)
                        .disabled(state.isWorking)
                    }
                    stepActionButton
                }
                .padding()
            }
            .navigationTitle("iDroidik Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .environmentObject(runner)
        .onAppear { bindRunner() }
    }

    @ViewBuilder
    private var stepActionButton: some View {
        switch state.currentStep {
        case .welcome:
            BigButton("Start Setup", color: .blue) {
                state.currentStep = .preflight
            }
        case .preflight:
            BigButton("Run Checks", color: .blue, loading: state.isWorking) {
                runner.runPreflight()
            } next: {
                state.currentStep = .volume
            }
            .disabled(!state.preflightPassed && !state.isWorking)
            .opacity(state.preflightPassed ? 1 : 0.6)
        case .volume:
            BigButton(state.volumeExisted ? "Continue" : "Create Volume", color: .blue, loading: state.isWorking) {
                runner.runVolume()
            } next: {
                state.currentStep = .download
            }
            .disabled(!state.volumeExisted && !state.volumeConfirmed)
            .opacity((!state.volumeExisted && !state.volumeConfirmed) ? 0.5 : 1.0)
        case .download:
            BigButton(state.imageAlreadyPresent ? "Continue" : "Download Image", color: .blue, loading: state.isWorking) {
                runner.runDownload()
            } next: {
                state.currentStep = .firmware
            }
        case .firmware:
            BigButton("Generate Firmware", color: .blue, loading: state.isWorking) {
                runner.runFirmware()
            } next: {
                state.currentStep = .userdata
            }
        case .userdata:
            BigButton(state.userdataSkipped ? "Skip" : "Create userdata.img", color: .blue, loading: state.isWorking) {
                runner.runUserdata()
            } next: {
                state.currentStep = .done
            }
        case .done:
            BigButton("Done", color: .green) {}
                .hidden()
        }
    }
}

/// Runs each step on a background queue, updating state on main.
final class StepRunner: ObservableObject {
    @Published var volumeConfirmed = false

    func runPreflight() {
        guard let state = currentState else { return }
        state.isWorking = true
        state.lastError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = SetupEngine(state: state)
            let ok = engine.runPreflight()
            DispatchQueue.main.async { state.isWorking = false }
            _ = ok
        }
    }

    func runVolume() {
        guard let state = currentState else { return }
        // If volume already exists, just advance.
        if state.volumeExisted && !state.androidVolumeDevice.isEmpty {
            state.currentStep = .download
            return
        }
        state.isWorking = true
        state.lastError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = SetupEngine(state: state)
            var ok = false
            let existing = engine.findAndroidVolume()
            if !existing.isEmpty {
                DispatchQueue.main.async {
                    state.androidVolumeDevice = existing
                    state.volumeExisted = true
                }
                state.appendLog("Found existing Android volume: \(existing)")
                ok = engine.mountAndroidVolume()
            } else {
                ok = engine.createAndroidVolume() && engine.mountAndroidVolume()
            }
            DispatchQueue.main.async {
                state.isWorking = false
                if ok { state.currentStep = .download }
            }
        }
    }

    func runDownload() {
        guard let state = currentState else { return }
        state.isWorking = true
        state.lastError = nil
        state.progress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = SetupEngine(state: state)
            guard engine.mountAndroidVolume() else {
                DispatchQueue.main.async { state.isWorking = false }
                return
            }
            guard let parts = engine.fetchPartsManifest() else {
                DispatchQueue.main.async { state.isWorking = false }
                return
            }
            let ok = engine.downloadImage(parts: parts) { f, label in
                DispatchQueue.main.async {
                    state.progress = f
                    state.progressLabel = label
                }
            }
            DispatchQueue.main.async {
                state.isWorking = false
                if ok { state.currentStep = .firmware }
            }
        }
    }

    func runFirmware() {
        guard let state = currentState else { return }
        state.isWorking = true
        state.lastError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = SetupEngine(state: state)
            guard engine.mountAndroidVolume() else {
                DispatchQueue.main.async { state.isWorking = false }
                return
            }
            let ok = engine.generateFirmware()
            DispatchQueue.main.async {
                state.isWorking = false
                if ok { state.currentStep = .userdata }
            }
        }
    }

    func runUserdata() {
        guard let state = currentState else { return }
        if state.userdataSkipped {
            state.currentStep = .done
            return
        }
        state.isWorking = true
        state.lastError = nil
        state.progress = 0
        let gb = state.userdataGB
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = SetupEngine(state: state)
            guard engine.mountAndroidVolume() else {
                DispatchQueue.main.async { state.isWorking = false }
                return
            }
            let ok = engine.provisionUserdata(gb: gb) { f, label in
                DispatchQueue.main.async {
                    state.progress = f
                    state.progressLabel = label
                }
            }
            engine.unmountAndroidVolume()
            DispatchQueue.main.async {
                state.isWorking = false
                if ok { state.currentStep = .done }
            }
        }
    }

    // The state is passed via environment; this helper grabs it from the
    // current UI context through a stored weak reference set by ContentView.
    weak var currentState: SetupState?
}

struct BigButton: View {
    let title: String
    let color: Color
    var loading: Bool = false
    let action: () -> Void
    var next: (() -> Void)? = nil

    init(_ title: String, color: Color, loading: Bool = false,
         action: @escaping () -> Void, next: (() -> Void)? = nil) {
        self.title = title
        self.color = color
        self.loading = loading
        self.action = action
        self.next = next
    }

    // Two-phase button: first tap runs the work, second tap (after success) advances.
    @State private var didRun = false
    @EnvironmentObject var state: SetupState

    var body: some View {
        Button {
            if state.lastError == nil && didRun, let next = next {
                didRun = false
                next()
            } else {
                didRun = true
                action()
            }
        } label: {
            HStack {
                if loading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                }
                Text(buttonLabel)
                    .font(.title2.bold())
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
        .disabled(loading)
        .onChange(of: state.lastError) { _ in didRun = false }
        .onChange(of: state.currentStep) { _ in didRun = false }
    }

    private var buttonLabel: String {
        if loading { return "Working…" }
        if didRun && state.lastError == nil { return "Continue →" }
        return title
    }
}

struct StepProgressBar: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(current + 1) of \(total)")
                .font(.headline)
                .foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.25))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue)
                        .frame(width: geo.size.width * CGFloat(current + 1) / CGFloat(total), height: 12)
                }
            }
            .frame(height: 12)
        }
    }
}
