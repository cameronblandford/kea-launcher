import Foundation

/// A parsed search box value. A leading list-command keyword followed by a
/// space routes the rest of the text to that command.
public enum Query: Equatable {
    case search(String)
    case command(keyword: String, argument: String)

    public static func parse(_ raw: String, listKeywords: Set<String>) -> Query {
        let trimmedLeading = raw.drop(while: { $0 == " " })
        // A bare keyword opens the command with no argument.
        if listKeywords.contains(String(trimmedLeading)) {
            return .command(keyword: String(trimmedLeading), argument: "")
        }
        if let space = trimmedLeading.firstIndex(of: " ") {
            let head = String(trimmedLeading[..<space])
            if listKeywords.contains(head) {
                let arg = String(trimmedLeading[trimmedLeading.index(after: space)...])
                return .command(keyword: head, argument: arg.trimmingCharacters(in: .whitespaces))
            }
        }
        return .search(raw.trimmingCharacters(in: .whitespaces))
    }
}
