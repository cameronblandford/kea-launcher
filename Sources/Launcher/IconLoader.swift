import AppKit

/// Resolves icons for file paths and `sf:` symbol names, with a cache.
final class IconLoader {
    static let shared = IconLoader()
    private var cache: [String: NSImage] = [:]
    private let size = NSSize(width: 32, height: 32)

    func icon(forPath path: String) -> NSImage {
        if let hit = cache[path] { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = size
        cache[path] = img
        return img
    }

    /// `spec` is an absolute path, a `~` path, or `sf:<symbol>`.
    func icon(forSpec spec: String?) -> NSImage? {
        guard let spec, !spec.isEmpty else { return nil }
        if spec.hasPrefix("sf:") {
            let name = String(spec.dropFirst(3))
            if let hit = cache[spec] { return hit }
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
            let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            let out = img.withSymbolConfiguration(cfg) ?? img
            cache[spec] = out
            return out
        }
        return icon(forPath: Paths.expand(spec))
    }

    var terminalIcon: NSImage {
        icon(forSpec: "sf:terminal") ?? NSImage()
    }
}
