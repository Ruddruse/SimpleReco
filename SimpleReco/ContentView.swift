import SwiftUI
import AVFoundation

struct ContentView: View {
    @ObservedObject var recordingState: RecordingState
    weak var appDelegate: AppDelegate?

    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var playbackProgress: Double = 0
    @State private var playbackTimer: Timer?
    @State private var playbackDelegate: PlaybackDelegate?

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
        Text(formattedTime)
            .font(.system(.body, design: .monospaced))
            .foregroundColor(.secondary)
    }

    private var formattedTime: String {
        if isPlaying, let player = audioPlayer {
            let current = Int(player.currentTime)
            let minutes = current / 60
            let seconds = current % 60
            return String(format: "%02d:%02d", minutes, seconds)
        }
        return recordingState.formattedDuration
    }

    private var controlsSection: some View {
        HStack(spacing: 12) {
            clearButton

            Spacer()

            mainButton

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
        .disabled(recordingState.status == .idle || recordingState.status == .recording)
    }

    private var mainButton: some View {
        Button(action: handleMainButtonTap) {
            ZStack {
                Circle()
                    .fill(mainButtonBackgroundColor)
                    .frame(width: 44, height: 44)

                mainButtonIcon
            }
        }
        .buttonStyle(.plain)
        .disabled(!recordingState.permissionGranted)
    }

    @ViewBuilder
    private var mainButtonIcon: some View {
        switch recordingState.status {
        case .idle:
            // Record icon - filled circle
            Circle()
                .fill(Color.white)
                .frame(width: 20, height: 20)

        case .recording:
            // Stop icon - square
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white)
                .frame(width: 16, height: 16)

        case .recorded:
            // Play icon - triangle
            Image(systemName: "play.fill")
                .font(.system(size: 18))
                .foregroundColor(.white)
                .offset(x: 2)

        case .playing:
            // Pause icon - two bars
            Image(systemName: "pause.fill")
                .font(.system(size: 18))
                .foregroundColor(.white)
        }
    }

    private var mainButtonBackgroundColor: Color {
        if !recordingState.permissionGranted {
            return .gray
        }

        switch recordingState.status {
        case .idle:
            return .red.opacity(0.8)
        case .recording:
            return .red
        case .recorded, .playing:
            return .blue
        }
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

    private func handleMainButtonTap() {
        switch recordingState.status {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .recorded:
            startPlayback()
        case .playing:
            pausePlayback()
        }
    }

    private func startRecording() {
        appDelegate?.startRecording()
    }

    private func stopRecording() {
        appDelegate?.stopRecording()
    }

    private func clearRecording() {
        stopPlayback()
        appDelegate?.clearRecording()
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let url = recordingState.audioURL else {
            print("No audio URL available")
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            playbackDelegate = PlaybackDelegate { [self] in
                stopPlayback()
            }
            audioPlayer?.delegate = playbackDelegate
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

    private func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        recordingState.status = .recorded
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playbackDelegate = nil
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
