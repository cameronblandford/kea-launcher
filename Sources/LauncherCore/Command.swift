import Foundation

public enum CommandMode: String, Codable {
    case action
    case list
}

/// Contents of `~/.launcher/commands/<name>/command.json`.
public struct CommandManifest: Codable, Equatable {
    public var title: String
    public var keyword: String
    public var subtitle: String?
    public var icon: String?
    public var mode: CommandMode

    public init(title: String, keyword: String, subtitle: String? = nil, icon: String? = nil, mode: CommandMode = .action) {
        self.title = title
        self.keyword = keyword
        self.subtitle = subtitle
        self.icon = icon
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey { case title, keyword, subtitle, icon, mode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        keyword = try c.decode(String.self, forKey: .keyword)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        mode = try c.decodeIfPresent(CommandMode.self, forKey: .mode) ?? .action
    }

    public static func decode(_ data: Data) throws -> CommandManifest {
        try JSONDecoder().decode(CommandManifest.self, from: data)
    }
}

/// What happens when a result is chosen.
public enum ItemAction: Equatable {
    case open(String)
    case shell(String)
    case copy(String)
}

public struct ScriptItem: Equatable {
    public var title: String
    public var subtitle: String?
    public var icon: String?
    public var action: ItemAction?

    public init(title: String, subtitle: String? = nil, icon: String? = nil, action: ItemAction? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.action = action
    }
}

/// JSON printed to stdout by a `list` command's `run` script.
public struct ScriptOutput: Equatable {
    public var items: [ScriptItem]

    public static func decode(_ data: Data) throws -> ScriptOutput {
        let raw = try JSONDecoder().decode(RawOutput.self, from: data)
        return ScriptOutput(items: raw.items.map { r in
            ScriptItem(title: r.title, subtitle: r.subtitle, icon: r.icon, action: r.action?.toAction())
        })
    }

    private struct RawOutput: Decodable {
        var items: [RawItem]
    }

    private struct RawItem: Decodable {
        var title: String
        var subtitle: String?
        var icon: String?
        var action: RawAction?
    }

    private struct RawAction: Decodable {
        var type: String
        var target: String

        func toAction() -> ItemAction? {
            switch type {
            case "open": return .open(target)
            case "shell": return .shell(target)
            case "copy": return .copy(target)
            default: return nil
            }
        }
    }
}
