import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

class AudioRecorder: NSObject {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var recordingState: RecordingState
    private var sampleBuffer: [Float] = []
    private let outputFormat: AVAudioFormat

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
        self.outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        super.init()
    }

    func startRecording() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                guard let display = content.displays.first else {
                    await MainActor.run {
                        recordingState.errorMessage = "No display found"
                    }
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2

                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.showsCursor = false

                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
                self.tempFileURL = tempFile

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]

                guard let format = AVAudioFormat(settings: audioSettings) else {
                    await MainActor.run {
                        recordingState.errorMessage = "Failed to create audio format"
                    }
                    return
                }

                self.audioFile = try AVAudioFile(forWriting: tempFile, settings: audioSettings)

                stream = SCStream(filter: filter, configuration: config, delegate: self)

                try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

                try await stream?.startCapture()

            } catch {
                await MainActor.run {
                    recordingState.errorMessage = "Failed to start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        Task {
            do {
                try await stream?.stopCapture()
                stream = nil
                audioFile = nil

                if let tempURL = tempFileURL {
                    let mp3URL = await MP3Exporter.convertToMP3(from: tempURL)
                    try? FileManager.default.removeItem(at: tempURL)
                    completion(mp3URL)
                } else {
                    completion(nil)
                }
            } catch {
                print("Error stopping capture: \(error)")
                completion(nil)
            }
        }
    }
}

extension AudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            recordingState.errorMessage = "Stream stopped: \(error.localizedDescription)"
        }
    }
}

extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let audioFile = audioFile else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }

        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
        let frameCount = length / (MemoryLayout<Float>.size * 2)

        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        if let channelData = buffer.floatChannelData {
            for frame in 0..<frameCount {
                let leftSample = floatPointer[frame * 2]
                let rightSample = floatPointer[frame * 2 + 1]
                channelData[0][frame] = leftSample
                channelData[1][frame] = rightSample
            }
        }

        do {
            try audioFile.write(from: buffer)
        } catch {
            print("Error writing audio: \(error)")
        }

        var sum: Float = 0
        for i in 0..<min(frameCount, 1000) {
            sum += abs(floatPointer[i * 2])
        }
        let avg = sum / Float(min(frameCount, 1000))

        Task { @MainActor in
            recordingState.appendLiveSample(avg * 5)
        }
    }
}
