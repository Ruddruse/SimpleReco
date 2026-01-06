import Foundation
import AVFoundation
import Combine

enum RecordingStatus {
    case idle
    case recording
    case recorded
    case playing
}

@MainActor
class RecordingState: ObservableObject {
    @Published var status: RecordingStatus = .idle
    @Published var duration: TimeInterval = 0
    @Published var waveformSamples: [Float] = []
    @Published var liveWaveformSamples: [Float] = []
    @Published var isRecordingIndicatorOn: Bool = false
    @Published var permissionGranted: Bool = false
    @Published var errorMessage: String?

    var audioData: Data?
    var audioURL: URL?

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func reset() {
        status = .idle
        duration = 0
        waveformSamples = []
        liveWaveformSamples = []
        audioData = nil
        audioURL = nil
        errorMessage = nil
    }

    func appendLiveSample(_ sample: Float) {
        liveWaveformSamples.append(sample)
        if liveWaveformSamples.count > 100 {
            liveWaveformSamples.removeFirst()
        }
    }

    func setFinalWaveform(_ samples: [Float]) {
        waveformSamples = samples
    }
}
