import Foundation

/// The config sections of the personal features, which are not in the public repository.
/// Kea's own build has `Personal/PersonalConfig.swift` instead of this file (see
/// Package.swift). It reads its keys from the top level of the same `config.json`.
public struct PersonalConfig: Codable, Equatable {
    public init() {}
}
