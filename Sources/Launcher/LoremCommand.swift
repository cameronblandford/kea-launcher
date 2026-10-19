import AppKit
import LauncherCore

/// `lorem`: placeholder text. `lorem` alone offers a phrase, a sentence, a paragraph and
/// five paragraphs; `lorem 3` gives that many paragraphs; `lorem 3 md` a Markdown document.
enum LoremCommand {
    static var command: KeaCommand {
        KeaCommand(id: "lorem", name: "Lorem Ipsum", keywords: ["lorem"],
                   help: [.init(keyword: "lorem", summary: "Placeholder text: a phrase, N paragraphs, or a Markdown document", example: "lorem · lorem 3 · lorem 3 md")],
                   results: { results(filter: $0.argument) })
    }

    static func results(filter: String) -> [Result] {
        let icon = IconLoader.shared.icon(forSpec: "sf:text.alignleft")
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        // `lorem 3`, `lorem 3 md`, `lorem md`: that many paragraphs, plain or Markdown.
        if let req = Lorem.parseRequest(f) {
            let n = req.paragraphs
            let label = "\(n) Paragraph\(n == 1 ? "" : "s")"
            func row(_ id: String, _ title: String, _ text: String, _ hint: String) -> Result {
                let words = text.split { $0 == " " || $0 == "\n" }.count
                let preview = text.replacingOccurrences(of: "\n", with: " ")
                return Result(id: "lorem:\(id)", title: title,
                              subtitle: "Return copies · \(words) words · \(hint)" + String(preview.prefix(70)) + "…", icon: icon, action: .item(.copy(text)))
            }
            let md = row("md", "\(label), Markdown", Lorem.markdown(paragraphs: n), "headers, lists, image, quote, code, table · ")
            return req.markdown ? [md] : [row("n", label, Lorem.paragraphs(n), ""), md]
        }
        let kinds = Lorem.Kind.allCases.filter { f.isEmpty || FuzzyMatcher.score(query: f, candidate: $0.title) != nil }
        return kinds.map { kind in
            let text = Lorem.generate(kind)
            let preview = text.replacingOccurrences(of: "\n\n", with: " ¶ ")
            return Result(id: "lorem:\(kind.rawValue)", title: kind.title,
                          subtitle: "Return copies · " + (preview.count > 100 ? String(preview.prefix(100)) + "…" : preview),
                          icon: icon, action: .item(.copy(text)))
        }
    }
}
