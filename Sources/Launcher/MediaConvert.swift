import AppKit
import AVFoundation
import LauncherCore
import UniformTypeIdentifiers

/// Turns one image or video file into another. Used by `conv` and `rec`. Every call
/// blocks until the new file is written, so call it off the main thread.
enum MediaConvert {
    /// Runs the conversion that `target` names. True when `output` was written.
    static func run(_ input: URL, to output: URL, target: Convert.Target) -> Bool {
        switch target {
        case .jpeg: return sips(["-s", "format", "jpeg", "-s", "formatOptions", "85"], input, output)
        case .png: return sips(["-s", "format", "png"], input, output)
        case .heic: return sips(["-s", "format", "heic"], input, output)
        case .resize(let side): return sips(["-Z", String(side)], input, output)
        case .mp4: return mp4(from: input, to: output)
        case .gif: return gif(from: input, to: output)
        }
    }

    private static func sips(_ options: [String], _ input: URL, _ output: URL) -> Bool {
        let result = Proc.run("/usr/bin/sips", options + [input.path, "--out", output.path])
        if result.status != 0 { Log.write("convert: sips failed for \(input.lastPathComponent): \(result.output.suffix(200))") }
        return result.status == 0 && FileManager.default.fileExists(atPath: output.path)
    }

    /// Waits for an async call from a thread that is not the main thread.
    private static func wait<T>(_ body: @escaping () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var value: T!
        Task.detached {
            value = await body()
            done.signal()
        }
        done.wait()
        return value
    }

    /// An MP4 of the movie. `passthrough` keeps the pictures as they are (fast, for a new
    /// recording); without it the movie is encoded again as H.264, which plays everywhere.
    static func mp4(from input: URL, to output: URL, passthrough: Bool = false) -> Bool {
        let asset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: asset, presetName: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality) else { return false }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        if session.status != .completed { Log.write("convert: mp4 export failed for \(input.lastPathComponent): \(session.error?.localizedDescription ?? "unknown")") }
        return session.status == .completed
    }

    /// An animated GIF of the movie: at most `maxWidth` pixels wide and `fps` frames a
    /// second, and it loops. A long movie gets fewer frames a second so the file stays small.
    static func gif(from input: URL, to output: URL, maxWidth: CGFloat = 720, fps: Double = 12) -> Bool {
        let asset = AVURLAsset(url: input)
        let seconds = wait { (try? await asset.load(.duration).seconds) ?? 0 }
        guard seconds > 0, seconds.isFinite else { return false }
        let rate = seconds > 30 ? min(fps, 8) : fps
        let count = max(1, min(Int(seconds * rate), 600))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else { return false }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: seconds / Double(count)]] as CFDictionary
        var written = 0
        for i in 0 ..< count {
            let time = CMTime(seconds: seconds * Double(i) / Double(count), preferredTimescale: 600)
            guard let image = wait({ try? await generator.image(at: time).image }) else { continue }
            CGImageDestinationAddImage(destination, image, frame)
            written += 1
        }
        guard written > 0 else { return false }
        return CGImageDestinationFinalize(destination)
    }
}
