import SwiftUI

struct WaveformView: View {
    let samples: [Float]
    let isLive: Bool
    var isPlaying: Bool = false
    var playbackProgress: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let barCount = samples.isEmpty ? 50 : samples.count
            let barWidth: CGFloat = 3
            let spacing: CGFloat = 2
            let totalWidth = CGFloat(barCount) * (barWidth + spacing)
            let startX = (geometry.size.width - totalWidth) / 2

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.1))

                if samples.isEmpty {
                    ForEach(0..<barCount, id: \.self) { index in
                        let x = startX + CGFloat(index) * (barWidth + spacing)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: barWidth, height: 4)
                            .position(x: x + barWidth / 2, y: geometry.size.height / 2)
                    }
                } else {
                    ForEach(0..<samples.count, id: \.self) { index in
                        let sample = CGFloat(min(samples[index], 1.0))
                        let maxHeight = geometry.size.height - 20
                        let height = max(4, sample * maxHeight)
                        let x = startX + CGFloat(index) * (barWidth + spacing)

                        let progressIndex = Int(playbackProgress * Double(samples.count))
                        let barColor: Color = {
                            if isLive {
                                return .red
                            } else if isPlaying && index <= progressIndex {
                                return .blue
                            } else {
                                return .accentColor
                            }
                        }()

                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(barColor)
                            .frame(width: barWidth, height: height)
                            .position(x: x + barWidth / 2, y: geometry.size.height / 2)
                            .animation(isLive ? .easeOut(duration: 0.1) : nil, value: sample)
                    }
                }
            }
        }
    }
}

struct LiveWaveformView: View {
    @ObservedObject var recordingState: RecordingState

    var body: some View {
        ZStack {
            WaveformView(samples: recordingState.liveWaveformSamples, isLive: true)

            VStack {
                Text("Recording...")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
            }
        }
    }
}

struct StaticWaveformView: View {
    @ObservedObject var recordingState: RecordingState
    var isPlaying: Bool
    var playbackProgress: Double
    var onTap: () -> Void

    var body: some View {
        ZStack {
            WaveformView(
                samples: recordingState.waveformSamples,
                isLive: false,
                isPlaying: isPlaying,
                playbackProgress: playbackProgress
            )

            if !recordingState.waveformSamples.isEmpty {
                Button(action: onTap) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct IdleWaveformView: View {
    var body: some View {
        ZStack {
            WaveformView(samples: [], isLive: false)

            Text("Press record to start")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        WaveformView(
            samples: (0..<50).map { _ in Float.random(in: 0.1...1.0) },
            isLive: false
        )
        .frame(height: 80)

        WaveformView(samples: [], isLive: false)
            .frame(height: 80)
    }
    .padding()
}
