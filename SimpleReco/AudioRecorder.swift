import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

class AudioRecorder: NSObject {
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?
    private var recordingState: RecordingState
    private var actualSampleRate: Double = 48000
    private var actualChannelCount: UInt32 = 2
    private var isFirstBuffer: Bool = true

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
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
                self.isFirstBuffer = true

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

    private func createAudioFile(sampleRate: Double, channelCount: UInt32) -> AVAudioFile? {
        guard let tempFile = tempFileURL else { return nil }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            return try AVAudioFile(forWriting: tempFile, settings: audioSettings)
        } catch {
            print("Error creating audio file: \(error)")
            return nil
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

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channelCount = asbd.pointee.mChannelsPerFrame

        if isFirstBuffer {
            isFirstBuffer = false
            actualSampleRate = sampleRate
            actualChannelCount = channelCount
            audioFile = createAudioFile(sampleRate: sampleRate, channelCount: channelCount)
            print("Audio format: \(sampleRate) Hz, \(channelCount) channels")
        }

        guard let audioFile = audioFile else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }

        let bytesPerFrame = MemoryLayout<Float>.size * Int(channelCount)
        let frameCount = length / bytesPerFrame

        guard frameCount > 0 else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        ) else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        if let bufferData = buffer.floatChannelData?[0] {
            let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
            for i in 0..<(frameCount * Int(channelCount)) {
                bufferData[i] = floatPointer[i]
            }
        }

        do {
            try audioFile.write(from: buffer)
        } catch {
            print("Error writing audio: \(error)")
        }

        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: length / MemoryLayout<Float>.size)
        var sum: Float = 0
        let samplesToCheck = min(frameCount * Int(channelCount), 1000)
        for i in 0..<samplesToCheck {
            sum += abs(floatPointer[i])
        }
        let avg = sum / Float(samplesToCheck)

        Task { @MainActor in
            recordingState.appendLiveSample(avg * 5)
        }
    }
}
