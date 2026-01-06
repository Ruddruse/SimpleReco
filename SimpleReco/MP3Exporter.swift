import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

class MP3Exporter {

    static func convertToMP3(from sourceURL: URL) async -> URL? {
        print("Converting from: \(sourceURL.path)")

        // First verify source file exists
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            print("Source file does not exist!")
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let m4aURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")

        let asset = AVURLAsset(url: sourceURL)

        // Check if asset has audio tracks
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            print("Asset has \(tracks.count) audio tracks")
            if tracks.isEmpty {
                print("No audio tracks found, trying direct file conversion")
                return await convertUsingAudioFile(from: sourceURL)
            }
        } catch {
            print("Error loading tracks: \(error)")
            return await convertUsingAudioFile(from: sourceURL)
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            print("Failed to create export session")
            return await convertUsingAudioFile(from: sourceURL)
        }

        do {
            try await exportSession.export(to: m4aURL, as: .m4a)
            print("Export successful to: \(m4aURL.path)")
            return m4aURL
        } catch {
            print("Export failed: \(error.localizedDescription)")
            return await convertUsingAudioFile(from: sourceURL)
        }
    }

    private static func convertUsingAudioFile(from sourceURL: URL) async -> URL? {
        print("Attempting direct audio file conversion")
        do {
            let sourceFile = try AVAudioFile(forReading: sourceURL)
            let format = sourceFile.processingFormat
            let frameCount = UInt32(sourceFile.length)

            print("Source file: \(frameCount) frames, format: \(format)")

            guard frameCount > 0 else {
                print("Source file has no frames!")
                return nil
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                print("Failed to create buffer")
                return nil
            }

            try sourceFile.read(into: buffer)
            print("Read \(buffer.frameLength) frames into buffer")

            // Try to write as M4A/AAC
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 320000
            ]

            let tempDir = FileManager.default.temporaryDirectory
            let aacURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")

            do {
                let aacFile = try AVAudioFile(forWriting: aacURL, settings: aacSettings)
                try aacFile.write(from: buffer)
                print("AAC conversion successful: \(aacURL.path)")
                return aacURL
            } catch {
                print("AAC conversion failed: \(error), returning source file")
                // If AAC fails, just copy the source file as-is
                let copyURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
                try? FileManager.default.copyItem(at: sourceURL, to: copyURL)
                return copyURL
            }

        } catch {
            print("Error in convertUsingAudioFile: \(error)")
            return nil
        }
    }

    static func generateFilename() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy_MM_dd"
        let dateString = dateFormatter.string(from: Date())

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        var sequenceNumber = 1
        var filename: String

        repeat {
            filename = "Recording_\(dateString)_\(String(format: "%02d", sequenceNumber)).m4a"
            sequenceNumber += 1
        } while FileManager.default.fileExists(atPath: downloadsURL.appendingPathComponent(filename).path)

        return filename
    }

    static func getDefaultSaveURL() -> URL {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let filename = generateFilename()
        return downloadsURL.appendingPathComponent(filename)
    }

    static func saveToDownloads(from sourceURL: URL) -> URL? {
        print("Saving to downloads from: \(sourceURL.path)")

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            print("Source file does not exist for saving!")
            return nil
        }

        let destinationURL = getDefaultSaveURL()
        print("Destination: \(destinationURL.path)")

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            print("File saved successfully")
            return destinationURL
        } catch {
            print("Error saving file: \(error)")
            return nil
        }
    }

    static func saveWithPicker(from sourceURL: URL, suggestedName: String? = nil) {
        print("Opening save picker for: \(sourceURL.path)")

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            print("Source file does not exist for save picker!")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.mpeg4Audio, UTType.audio]
        savePanel.nameFieldStringValue = suggestedName ?? generateFilename()
        savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: url)
                    print("File saved via picker to: \(url.path)")
                } catch {
                    print("Error saving file via picker: \(error)")
                }
            }
        }
    }
}
