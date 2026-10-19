import Foundation

/// Items that start at login or run in the background, from `sfltool dumpbtm`.
public enum BootItems {
    public enum Kind: String {
        case loginApp        // "Open at Login" app (type app)
        case appLoginItem    // a login item an app registered itself (type login item)
        case agent           // per-user launch agent (agent, legacy agent)
        case daemon          // system-wide daemon (daemon, legacy daemon)
    }

    public struct Item: Equatable {
        public var name: String
        public var kind: Kind
        public var enabled: Bool
        public var identifier: String     // without the "8." type prefix
        public var url: String?           // app bundle or plist, as a path
        public var executable: String?
        public var developer: String?
        public var uid: Int
    }

    /// Parses the dump. Apple's own items, Quick Look and Spotlight plug-ins, dock
    /// tiles, and "developer" group records are left out.
    public static func parse(_ text: String) -> [Item] {
        var out: [Item] = []
        var uid = -1
        var fields: [String: String] = [:]
        func flush() {
            defer { fields = [:] }
            guard let type = fields["Type"], let disposition = fields["Disposition"] else { return }
            let kind: Kind
            switch type {
            case _ where type.hasPrefix("app "): kind = .loginApp
            case _ where type.hasPrefix("login item"): kind = .appLoginItem
            case _ where type.hasPrefix("agent") || type.hasPrefix("legacy agent"): kind = .agent
            case _ where type.hasPrefix("daemon") || type.hasPrefix("legacy daemon"): kind = .daemon
            default: return
            }
            var id = fields["Identifier"] ?? ""
            if let dot = id.firstIndex(of: "."), Int(id[..<dot]) != nil { id = String(id[id.index(after: dot)...]) }
            if id.hasPrefix("com.apple.") { return }
            var url = fields["URL"].flatMap { $0 == "(null)" ? nil : $0 }
            if let u = url, let parsed = URL(string: u), parsed.isFileURL { url = parsed.path }
            let rawName = fields["Name"] ?? "(null)"
            let name = rawName == "(null)" ? (url.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "").replacingOccurrences(of: ".plist", with: "") } ?? id) : rawName
            let developer = fields["Developer Name"].flatMap { $0 == "(null)" ? nil : $0 }
            out.append(Item(name: name, kind: kind, enabled: disposition.contains("[enabled"), identifier: id,
                            url: url, executable: fields["Executable Path"], developer: developer, uid: uid))
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Records for UID ") {
                flush()
                uid = Int(t.dropFirst("Records for UID ".count).split(separator: " ").first ?? "") ?? -1
            } else if t.hasPrefix("#"), t.hasSuffix(":"), line.hasPrefix(" #") {
                flush()
            } else if let colon = t.firstIndex(of: ":"), !t.hasPrefix("#") {
                let key = String(t[..<colon])
                let value = t[t.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if fields[key] == nil { fields[key] = value }
            }
        }
        flush()
        // The same item can appear for several users; keep one per identifier and kind.
        var seen = Set<String>()
        return out.filter { seen.insert("\($0.kind.rawValue)|\($0.identifier)").inserted }
    }
}
