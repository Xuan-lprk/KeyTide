import SwiftUI

/// The window owns the calibration session. The SwiftUI view only displays its state.
final class MouseDistanceCalibrationViewController: NSHostingController<MouseDistanceCalibrationView> {
    private let model: MouseDistanceCalibrationModel
    private var updateTimer: Timer?
    private var calibrationGeneration = 0
    private var requestingProgress = false

    init() {
        let model = MouseDistanceCalibrationModel()
        self.model = model
        super.init(rootView: MouseDistanceCalibrationView(model: model))
        model.retry = { [weak self] in self?.prepareForDisplay() }
        model.close = { [weak self] in self?.view.window?.close() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelCalibration()
    }

    deinit { updateTimer?.invalidate() }

    func prepareForDisplay() {
        calibrationGeneration &+= 1
        requestingProgress = false
        BackgroundInputController.shared.request(.cancelCalibration) { _, _ in }
        model.state = .waiting

        let generation = calibrationGeneration
        let meters = (try? JSONEncoder().encode(0.10)) ?? Data()
        BackgroundInputController.shared.request(.beginCalibration, data: meters) { [weak self] data, ok in
            guard let self, self.calibrationGeneration == generation else { return }
            self.stopTimer()
            guard ok, let data, let result = try? JSONDecoder().decode(InputCalibrationResult.self, from: data) else {
                self.model.state = .failed(pixels: 0)
                return
            }
            if let factor = result.factor {
                self.model.state = .succeeded(pixels: result.pixels, factor: factor)
            } else {
                self.model.state = .failed(pixels: result.pixels)
            }
        }
        startTimer()
    }

    func cancelCalibration() {
        guard updateTimer != nil else { return }
        stopTimer()
        calibrationGeneration &+= 1
        requestingProgress = false
        BackgroundInputController.shared.request(.cancelCalibration) { _, _ in }
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshLiveStatus() }
        updateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshLiveStatus()
    }

    private func stopTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func refreshLiveStatus() {
        guard !requestingProgress else { return }
        requestingProgress = true
        let generation = calibrationGeneration
        BackgroundInputController.shared.request(.calibrationPixels) { [weak self] data, ok in
            guard let self, self.calibrationGeneration == generation else { return }
            self.requestingProgress = false
            guard self.updateTimer != nil, ok, let data,
                  let progress = try? JSONDecoder().decode(InputCalibrationProgress.self, from: data) else { return }
            self.model.state = .measuring(pixels: progress.pixels, moving: progress.moving)
        }
    }
}

final class MouseDistanceCalibrationModel: ObservableObject {
    enum State: Equatable {
        case waiting
        case measuring(pixels: Double, moving: Bool)
        case succeeded(pixels: Double, factor: Double)
        case failed(pixels: Double)

        var pixels: Double {
            switch self {
            case .waiting: return 0
            case .measuring(let pixels, _), .succeeded(let pixels, _), .failed(let pixels): return pixels
            }
        }

        var isFinished: Bool {
            switch self {
            case .succeeded, .failed: return true
            case .waiting, .measuring: return false
            }
        }
    }

    @Published var state = State.waiting
    var retry: () -> Void = {}
    var close: () -> Void = {}
}

struct MouseDistanceCalibrationView: View {
    @ObservedObject var model: MouseDistanceCalibrationModel

    private var pixelText: String { String(format: "%.0f px", model.state.pixels) }

    var body: some View {
        VStack(spacing: 10) {
            Text("settings.mouseDistanceCalibration.title")
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("settings.mouseDistanceCalibration.instruction")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(pixelText)
                .font(.system(size: 28, weight: .medium).monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 64)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                }
            Text(statusText).foregroundStyle(.secondary)
            result
            HStack(spacing: 8) {
                Button("settings.mouseDistanceCalibration.retry", action: model.retry)
                Button(model.state.isFinished ? "settings.mouseDistanceCalibration.close"
                       : "settings.mouseDistanceCalibration.cancel", action: model.close)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(minWidth: 360, minHeight: 240)
    }

    private var statusText: String {
        switch model.state {
        case .measuring(_, true):
            return String(format: NSLocalizedString("settings.mouseDistanceCalibration.status.moving", comment: ""), pixelText)
        case .waiting, .measuring:
            return NSLocalizedString("settings.mouseDistanceCalibration.status.waiting", comment: "")
        case .succeeded:
            return NSLocalizedString("settings.mouseDistanceCalibration.success.title", comment: "")
        case .failed:
            return NSLocalizedString("settings.mouseDistanceCalibration.failure.title", comment: "")
        }
    }

    @ViewBuilder private var result: some View {
        switch model.state {
        case .succeeded(_, let factor):
            Text(String(
                format: NSLocalizedString("settings.mouseDistanceCalibration.success.message", comment: ""),
                pixelText, String(format: "%.3f×", factor)
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .failed:
            Text("settings.mouseDistanceCalibration.failure.message")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .waiting, .measuring:
            EmptyView()
        }
    }
}

#if DEBUG
struct MouseDistanceCalibrationView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview(.waiting).previewDisplayName("Waiting")
            preview(.succeeded(pixels: 625, factor: 1.14)).previewDisplayName("Complete")
            preview(.failed(pixels: 0)).preferredColorScheme(.dark).previewDisplayName("Unavailable")
        }
    }

    private static func preview(_ state: MouseDistanceCalibrationModel.State) -> some View {
        let model = MouseDistanceCalibrationModel()
        model.state = state
        return MouseDistanceCalibrationView(model: model).frame(width: 360, height: 260)
    }
}
#endif
