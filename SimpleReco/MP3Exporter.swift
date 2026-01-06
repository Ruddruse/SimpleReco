import Foundation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

class MP3Exporter {

    static func generateFilename() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy_MM_dd"
        let dateString = dateFormatter.string(from: Date())

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

        var sequenceNumber = 1
        var filename: String

        repeat {
            filename = "Recording_\(dateString)_\(String(format: "%02d", sequenceNumber)).wav"
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
        savePanel.allowedContentTypes = [UTType.wav, UTType.audio]
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
