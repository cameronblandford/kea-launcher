import Foundation

/// The rules of `conv`: what a file can become, and what the new file is called.
public enum Convert {
    public enum Kind: Equatable { case image, video }

    /// What to do to a file.
    public enum Target: Equatable {
        case jpeg, png, heic
        case mp4, gif
        /// Make an image no larger than this many pixels on its long side.
        case resize(Int)

        /// The extension of the result; nil keeps the extension of the original.
        public var fileExtension: String? {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .heic: return "heic"
            case .mp4: return "mp4"
            case .gif: return "gif"
            case .resize: return nil
            }
        }

        public var label: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            case .heic: return "HEIC"
            case .mp4: return "MP4"
            case .gif: return "GIF"
            case .resize(let side): return "\(side) px"
            }
        }

        /// The kind of file the target applies to.
        public var kind: Kind {
            switch self {
            case .jpeg, .png, .heic, .resize: return .image
            case .mp4, .gif: return .video
            }
        }
    }

    private static let imageExtensions: Set<String> = ["heic", "heif", "png", "jpg", "jpeg", "tiff", "tif", "gif", "bmp", "webp"]
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public static func kind(ofPath path: String) -> Kind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    /// `jpg`, `png`, `heic`, `mp4`, `gif`, or a number of pixels (`1600`, `1600px`).
    public static func target(from text: String) -> Target? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "jpg", "jpeg": return .jpeg
        case "png": return .png
        case "heic", "heif": return .heic
        case "mp4": return .mp4
        case "gif": return .gif
        default:
            let digits = t.hasSuffix("px") ? String(t.dropLast(2)) : t
            guard let side = Int(digits), side >= 16, side <= 20000 else { return nil }
            return .resize(side)
        }
    }

    /// The targets to offer for a group of files, the most likely first. A target that
    /// would change nothing (PNG for files that are all PNG) is left out.
    public static func targets(forPaths paths: [String]) -> [Target] {
        let kinds = Set(paths.compactMap(kind(ofPath:)))
        let extensions = Set(paths.map { ($0 as NSString).pathExtension.lowercased() })
        var out: [Target] = []
        if kinds.contains(.image) {
            if !extensions.isSubset(of: ["jpg", "jpeg"]) { out.append(.jpeg) }
            if extensions != ["png"] { out.append(.png) }
            out.append(.resize(1600))
        }
        if kinds.contains(.video) {
            if extensions != ["mp4"] { out.append(.mp4) }
            out.append(.gif)
        }
        return out
    }

    /// The paths a target applies to.
    public static func applicable(_ paths: [String], to target: Target) -> [String] {
        paths.filter { path in
            guard kind(ofPath: path) == target.kind else { return false }
            // A GIF is an image here, and making a GIF from a GIF means nothing.
            if let ext = target.fileExtension, ext == (path as NSString).pathExtension.lowercased() { return false }
            return true
        }
    }

    /// The path of the result, next to the original: `photo.jpg`, `photo 1600px.png` for
    /// a resize, and `photo 2.jpg` when the name is taken. `exists` says whether a path is in use.
    public static func outputPath(for path: String, target: Target, exists: (String) -> Bool) -> String {
        let ns = path as NSString
        let folder = ns.deletingLastPathComponent
        var stem = (ns.lastPathComponent as NSString).deletingPathExtension
        let ext = target.fileExtension ?? ns.pathExtension
        if case .resize(let side) = target { stem += " \(side)px" }
        func make(_ name: String) -> String { (folder as NSString).appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)") }
        var candidate = make(stem)
        var n = 2
        while exists(candidate) {
            candidate = make("\(stem) \(n)")
            n += 1
        }
        return candidate
    }
}
