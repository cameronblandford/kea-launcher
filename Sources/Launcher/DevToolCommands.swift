import AppKit
import LauncherCore

/// Small developer tools: `uuid`, `b64`, `url`, `hash`, `json`, `color`. Return copies.
/// With no text after the keyword, `b64`, `url`, `hash` and `json` use the clipboard.
enum DevToolCommands {
    static var commands: [KeaCommand] { [uuid, base64, url, hash, json, color] }

    private static func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    private static func copyRow(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, copy: String? = nil) -> Result {
        Result(id: id, title: title, subtitle: subtitle + " · Return copies", icon: icon(symbol), action: .item(.copy(copy ?? title)))
    }

    /// The text to work on: what was typed, or else the clipboard.
    private static func input(_ ctx: CommandContext) -> (text: String, fromClipboard: Bool) {
        let typed = ctx.argument.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return (typed, false) }
        return (NSPasteboard.general.string(forType: .string) ?? "", true)
    }

    private static func short(_ s: String, _ n: Int = 90) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    private static func empty(_ id: String, _ title: String, _ example: String, _ symbol: String) -> [Result] {
        [Result(id: "\(id):help", title: title, subtitle: example, icon: icon(symbol), action: .none)]
    }

    static var uuid: KeaCommand {
        KeaCommand(id: "uuid", name: "UUID", keywords: ["uuid"],
                   help: [.init(keyword: "uuid", summary: "A new UUID, lower and upper case", example: "uuid")],
                   results: { _ in
                       let u = UUID().uuidString
                       return [copyRow("uuid:lower", u.lowercased(), "New UUID", "number"), copyRow("uuid:upper", u, "Upper case", "number")]
                   })
    }

    static var base64: KeaCommand {
        KeaCommand(id: "base64", name: "Base64", keywords: ["b64", "base64"],
                   help: [.init(keyword: "b64", summary: "Base64 encode and decode text, or the clipboard", example: "b64 hello · b64 aGVsbG8=")],
                   results: { ctx in
                       let (text, clip) = input(ctx)
                       guard !text.isEmpty else { return empty("b64", "Base64: type text, or copy some first", "b64 hello · b64 aGVsbG8=", "textformat.abc") }
                       let from = clip ? "From the clipboard" : "Encoded"
                       var rows: [Result] = []
                       if let d = DevTools.base64Decode(text) { rows.append(copyRow("b64:decode", short(d), clip ? "Clipboard, decoded" : "Decoded", "lock.open", copy: d)) }
                       let e = DevTools.base64Encode(text)
                       rows.append(copyRow("b64:encode", short(e), from, "lock", copy: e))
                       return rows
                   })
    }

    static var url: KeaCommand {
        KeaCommand(id: "urlencode", name: "URL Encode", keywords: ["url", "urlencode"],
                   help: [.init(keyword: "url", summary: "Percent-encode and decode text, or the clipboard", example: "url a b&c · url a%20b")],
                   results: { ctx in
                       let (text, _) = input(ctx)
                       guard !text.isEmpty else { return empty("url", "URL encode: type text, or copy some first", "url a b&c · url a%20b", "link") }
                       var rows: [Result] = []
                       if let d = DevTools.urlDecode(text) { rows.append(copyRow("url:decode", short(d), "Decoded", "link", copy: d)) }
                       let e = DevTools.urlEncode(text)
                       if e != text { rows.append(copyRow("url:encode", short(e), "Encoded", "link", copy: e)) }
                       return rows.isEmpty ? [Result(id: "url:same", title: short(text), subtitle: "Nothing to encode or decode", icon: icon("link"), action: .none)] : rows
                   })
    }

    static var hash: KeaCommand {
        KeaCommand(id: "hash", name: "Hash", keywords: ["hash", "sha", "md5"],
                   help: [.init(keyword: "hash", summary: "SHA-256, SHA-1 and MD5 of text, or the clipboard", example: "hash hello")],
                   results: { ctx in
                       let (text, clip) = input(ctx)
                       guard !text.isEmpty else { return empty("hash", "Hash: type text, or copy some first", "hash hello", "number.square") }
                       return DevTools.hashes(text).map { h in
                           copyRow("hash:\(h.name)", h.hex, h.name + (clip ? " of the clipboard" : ""), "number.square")
                       }
                   })
    }

    static var json: KeaCommand {
        KeaCommand(id: "json", name: "JSON Format", keywords: ["json"],
                   help: [.init(keyword: "json", summary: "Format or minify JSON from the clipboard (or typed)", example: "json")],
                   results: { ctx in
                       let (text, clip) = input(ctx)
                       guard let j = DevTools.json(text) else {
                           return [Result(id: "json:bad", title: clip ? "The clipboard is not JSON" : "Not valid JSON",
                                          subtitle: "Copy a JSON object or array, then type json", icon: icon("curlybraces"), action: .none)]
                       }
                       let lines = j.pretty.split(separator: "\n").count
                       return [copyRow("json:pretty", "Formatted JSON · \(lines) lines", short(j.pretty, 70), "curlybraces", copy: j.pretty),
                               copyRow("json:min", "Minified JSON · \(j.minified.count) characters", short(j.minified, 70), "curlybraces", copy: j.minified)]
                   })
    }

    /// A small square of the color, as the row icon.
    private static func swatch(_ c: DevTools.RGB) -> NSImage {
        NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
            NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).stroke()
            return true
        }
    }

    private static func colorRows(_ c: DevTools.RGB) -> [Result] {
        [c.hex, c.css, c.hsl, c.swift].enumerated().map { i, s in
            Result(id: "color:\(i)", title: s, subtitle: "Return copies", icon: swatch(c), action: .item(.copy(s)))
        }
    }

    static var color: KeaCommand {
        KeaCommand(id: "color", name: "Color Picker", keywords: ["color", "colour"],
                   help: [.init(keyword: "color", summary: "Pick a color from the screen, or convert one (hex, rgb, hsl)", example: "color · color #ff8800")],
                   results: { ctx in
                       let arg = ctx.argument.trimmingCharacters(in: .whitespaces)
                       if let c = DevTools.parseColor(arg) { return colorRows(c) }
                       return [Result(id: "color:pick", title: "Pick a Color from the Screen", subtitle: "Click any pixel; its hex value is copied · or type one: color #ff8800",
                                      icon: icon("eyedropper"), action: .custom {
                                          // The panel must be gone before the magnifier shows.
                                          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                              NSColorSampler().show { picked in
                                                  guard let p = picked?.usingColorSpace(.sRGB) else { return }
                                                  let c = DevTools.RGB(Int((p.redComponent * 255).rounded()), Int((p.greenComponent * 255).rounded()), Int((p.blueComponent * 255).rounded()))
                                                  NSPasteboard.general.clearContents()
                                                  NSPasteboard.general.setString(c.hex, forType: .string)
                                                  Notify.post(title: "Copied \(c.hex)", body: "\(c.css) · \(c.hsl)")
                                                  Log.write("color picked: \(c.hex)")
                                              }
                                          }
                                      })]
                   })
    }
}

/// `tz 3pm pst in nyc`, and the same text in plain search without the keyword.
enum ZoneTimeCommand {
    private static let icon = NSImage(systemSymbolName: "globe.americas", accessibilityDescription: nil)

    private static func row(_ a: ZoneTimes.Answer) -> Result {
        let day = a.dayNote.isEmpty ? "" : " \(a.dayNote)"
        let text = "\(a.time)\(day) in \(a.place)"
        return Result(id: "tz:answer", title: "= \(text)", subtitle: (a.source == "now" ? "Now" : a.source) + " · Return copies",
                      icon: icon, action: .item(.copy(text)))
    }

    static func command(favorites: [String]) -> KeaCommand {
        KeaCommand(id: "timezones", name: "Time Zones", keywords: ["tz", "time"],
                   help: [.init(keyword: "tz", summary: "Convert a time between zones; also works without the keyword", example: "3pm pst in nyc · time in tokyo · tz")],
                   instant: { term in ZoneTimes.convert(term).map(row) },
                   results: { ctx in
                       let arg = ctx.argument.trimmingCharacters(in: .whitespaces)
                       if !arg.isEmpty {
                           // `time in tokyo` arrives here as "in tokyo", and `tz tokyo` as "tokyo".
                           let place = arg.lowercased().hasPrefix("in ") ? String(arg.dropFirst(3)) : arg
                           if let a = ZoneTimes.convert(arg) ?? ZoneTimes.convert("time in " + place) { return [row(a)] }
                           return [Result(id: "tz:bad", title: "Could not read \"\(arg)\"", subtitle: "Try 3pm pst in nyc · 9:30 london to tokyo · tokyo",
                                          icon: icon, action: .none)]
                       }
                       // No text: the time now in each favorite place.
                       return favorites.compactMap { place in
                           ZoneTimes.convert("time in " + place).map { a in
                               let day = a.dayNote.isEmpty ? "" : " · \(a.dayNote)"
                               return Result(id: "tz:\(place)", title: "\(a.time) · \(a.place)", subtitle: "Now\(day) · set tz.favorites in config to change this list",
                                             icon: icon, action: .item(.copy("\(a.time) in \(a.place)")))
                           }
                       }
                   })
    }
}
