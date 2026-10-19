import CryptoKit
import Foundation

/// Small text tools for `b64`, `hash`, `json`, `url` and `color`.
public enum DevTools {
    public static func base64Encode(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// The decoded text, when `text` is valid Base64 (standard or URL-safe, padding optional) of UTF-8.
    public static func base64Decode(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !s.isEmpty, s.count % 4 != 1 else { return nil }
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s), let out = String(data: data, encoding: .utf8), !out.isEmpty else { return nil }
        return out
    }

    public static func urlEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    public static func urlDecode(_ text: String) -> String? {
        guard text.contains("%") || text.contains("+"), let out = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding, out != text else { return nil }
        return out
    }

    public static func hashes(_ text: String) -> [(name: String, hex: String)] {
        let data = Data(text.utf8)
        func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
        return [("SHA-256", hex(SHA256.hash(data: data))), ("SHA-1", hex(Insecure.SHA1.hash(data: data))), ("MD5", hex(Insecure.MD5.hash(data: data)))]
    }

    /// Pretty (2-space, sorted keys kept in order is not possible, so keys are sorted) and minified forms.
    public static func json(_ text: String) -> (pretty: String, minified: String)? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              obj is [Any] || obj is [String: Any],
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let mini = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        // Foundation pretty-prints with "key" : value; the usual style has no space before the colon.
        let p = String(decoding: pretty, as: UTF8.self).replacingOccurrences(of: "\" : ", with: "\": ")
        return (p, String(decoding: mini, as: UTF8.self))
    }

    public struct RGB: Equatable {
        public var r: Int, g: Int, b: Int
        public init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }

        public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
        public var css: String { "rgb(\(r), \(g), \(b))" }

        public var hsl: String {
            let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
            let mx = max(rf, gf, bf), mn = min(rf, gf, bf), d = mx - mn
            let l = (mx + mn) / 2
            var h = 0.0, s = 0.0
            if d > 0 {
                s = d / (1 - abs(2 * l - 1))
                if mx == rf { h = ((gf - bf) / d).truncatingRemainder(dividingBy: 6) }
                else if mx == gf { h = (bf - rf) / d + 2 }
                else { h = (rf - gf) / d + 4 }
                h *= 60
                if h < 0 { h += 360 }
            }
            return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        }

        public var swift: String { String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", Double(r) / 255, Double(g) / 255, Double(b) / 255) }
    }

    /// `#f80`, `ff8800`, `rgb(255, 136, 0)`, `255 136 0`.
    public static func parseColor(_ text: String) -> RGB? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let hex = t.hasPrefix("#") ? String(t.dropFirst()) : t
        if hex.allSatisfy(\.isHexDigit), hex.count == 3 || hex.count == 6 {
            let full = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            if let v = Int(full, radix: 16) { return RGB((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff) }
        }
        let nums = t.replacingOccurrences(of: "rgb", with: "").split { !$0.isNumber }.compactMap { Int($0) }
        if nums.count == 3, nums.allSatisfy({ (0...255).contains($0) }) { return RGB(nums[0], nums[1], nums[2]) }
        return nil
    }
}
