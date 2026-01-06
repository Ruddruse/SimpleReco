import SwiftUI
import AVFoundation

struct ContentView: View {
    @ObservedObject var recordingState: RecordingState
    weak var appDelegate: AppDelegate?

    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackProgress: Double = 0
    @State private var playbackTimer: Timer?

    var body: some View {
        VStack(spacing: 12) {
            waveformSection
                .frame(height: 90)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            durationLabel

            controlsSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(width: 280, height: 220)
        .background(Color(NSColor.windowBackgroundColor))
        .onDisappear {
            stopPlayback()
        }
    }

    @ViewBuilder
    private var waveformSection: some View {
        switch recordingState.status {
        case .idle:
            IdleWaveformView()

        case .recording:
            LiveWaveformView(recordingState: recordingState)

        case .recorded, .playing:
            StaticWaveformView(
                recordingState: recordingState,
                isPlaying: isPlaying,
                playbackProgress: playbackProgress,
                onTap: togglePlayback
            )
        }
    }

    private var durationLabel: some View {
        Text(recordingState.formattedDuration)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.secondary)
    }

    private var controlsSection: some View {
        HStack(spacing: 12) {
            clearButton

            Spacer()

            recordButton

            Spacer()

            saveButton
        }
    }

    private var clearButton: some View {
        Button(action: clearRecording) {
            Text("Clear")
                .font(.caption)
                .frame(width: 60)
        }
        .buttonStyle(.bordered)
        .disabled(recordingState.status == .idle)
    }

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .fill(recordButtonColor)
                    .frame(width: 44, height: 44)

                if recordingState.status == .recording {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 20, height: 20)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!recordingState.permissionGranted)
    }

    private var recordButtonColor: Color {
        if !recordingState.permissionGranted {
            return .gray
        }
        return recordingState.status == .recording ? .red : .red.opacity(0.8)
    }

    private var saveButton: some View {
        Menu {
            Button("Save to Downloads") {
                saveToDownloads()
            }

            Button("Save as...") {
                saveWithPicker()
            }
        } label: {
            Text("Save as...")
                .font(.caption)
                .frame(width: 70)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 80)
        .disabled(recordingState.status != .recorded && recordingState.status != .playing)
    }

    private func toggleRecording() {
        stopPlayback()

        if recordingState.status == .recording {
            appDelegate?.stopRecording()
        } else {
            if recordingState.status == .recorded {
                clearRecording()
            }
            appDelegate?.startRecording()
        }
    }

    private func clearRecording() {
        stopPlayback()
        appDelegate?.clearRecording()
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let url = recordingState.audioURL else { return }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = PlaybackDelegate { [self] in
                stopPlayback()
            }
            audioPlayer?.play()
            isPlaying = true
            recordingState.status = .playing

            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                if let player = audioPlayer {
                    playbackProgress = player.currentTime / player.duration
                }
            }
        } catch {
            print("Error playing audio: \(error)")
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        playbackProgress = 0
        playbackTimer?.invalidate()
        playbackTimer = nil

        if recordingState.status == .playing {
            recordingState.status = .recorded
        }
    }

    private func saveToDownloads() {
        guard let sourceURL = recordingState.audioURL else { return }

        if let savedURL = MP3Exporter.saveToDownloads(from: sourceURL) {
            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
        }
    }

    private func saveWithPicker() {
        guard let sourceURL = recordingState.audioURL else { return }
        MP3Exporter.saveWithPicker(from: sourceURL)
    }
}

class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.onFinish()
        }
    }
}

#Preview {
    ContentView(recordingState: RecordingState(), appDelegate: nil)
}
