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
    private var totalFramesWritten: Int64 = 0

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
                self.totalFramesWritten = 0

                stream = SCStream(filter: filter, configuration: config, delegate: self)

                try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

                try await stream?.startCapture()
                print("Recording started")

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
            let file = try AVAudioFile(forWriting: tempFile, settings: audioSettings)
            print("Created audio file at: \(tempFile.path)")
            return file
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

                // Important: Close the audio file by setting it to nil
                // This ensures all data is flushed to disk
                let framesWritten = totalFramesWritten
                audioFile = nil

                print("Recording stopped. Total frames written: \(framesWritten)")

                guard let tempURL = tempFileURL else {
                    print("No temp URL")
                    completion(nil)
                    return
                }

                // Check if file exists and has content
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: tempURL.path) {
                    do {
                        let attributes = try fileManager.attributesOfItem(atPath: tempURL.path)
                        let fileSize = attributes[.size] as? Int64 ?? 0
                        print("Temp file size: \(fileSize) bytes")

                        if fileSize == 0 {
                            print("Warning: Audio file is empty!")
                            completion(nil)
                            return
                        }
                    } catch {
                        print("Error getting file attributes: \(error)")
                    }
                } else {
                    print("Temp file does not exist!")
                    completion(nil)
                    return
                }

                // Convert to M4A
                print("Converting to M4A...")
                let convertedURL = await MP3Exporter.convertToMP3(from: tempURL)

                // Clean up temp file
                try? fileManager.removeItem(at: tempURL)

                if let url = convertedURL {
                    print("Conversion successful: \(url.path)")
                } else {
                    print("Conversion failed!")
                }

                completion(convertedURL)

            } catch {
                print("Error stopping capture: \(error)")
                completion(nil)
            }
        }
    }
}

extension AudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
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
            totalFramesWritten += Int64(frameCount)
        } catch {
            print("Error writing audio: \(error)")
        }

        // Update live waveform
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
