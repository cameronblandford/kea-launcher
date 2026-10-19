import Foundation

/// Small arithmetic evaluator: + - * / ^ %, parentheses, unary minus,
/// sqrt sin cos tan ln log abs round floor ceil, constants pi and e.
/// Returns nil for anything that is not clearly an expression.
public enum Calculator {
    public static func evaluate(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        // Require an operator or function so a bare number never shows a calculator row.
        let hasOperator = cleaned.contains { "+-*/^%(".contains($0) }
        guard hasOperator else { return nil }
        var p = Parser(Array(cleaned.lowercased()))
        guard let v = p.parseExpression(), p.atEnd, v.isFinite else { return nil }
        return v
    }

    public static func format(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 1e21 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.usesGroupingSeparator = false
            f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: value)) ?? String(value)
        }
        var s = String(format: "%.10g", value)
        if s.contains("e") { return s }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ chars: [Character]) { self.chars = chars }
        var atEnd: Bool { i >= chars.count }
        var peek: Character? { atEnd ? nil : chars[i] }

        mutating func parseExpression() -> Double? {
            guard var lhs = parseTerm() else { return nil }
            while let c = peek, c == "+" || c == "-" {
                i += 1
                guard let rhs = parseTerm() else { return nil }
                lhs = c == "+" ? lhs + rhs : lhs - rhs
            }
            return lhs
        }

        mutating func parseTerm() -> Double? {
            guard var lhs = parseUnary() else { return nil }
            while let c = peek, c == "*" || c == "/" {
                i += 1
                guard let rhs = parseUnary() else { return nil }
                if c == "/" {
                    guard rhs != 0 else { return nil }
                    lhs /= rhs
                } else {
                    lhs *= rhs
                }
            }
            return lhs
        }

        mutating func parseUnary() -> Double? {
            if peek == "-" { i += 1; return parseUnary().map { -$0 } }
            if peek == "+" { i += 1; return parseUnary() }
            return parsePower()
        }

        mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            if peek == "^" {
                i += 1
                guard let exp = parseUnary() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func parsePostfix() -> Double? {
            guard var v = parsePrimary() else { return nil }
            while peek == "%" { i += 1; v /= 100 }
            return v
        }

        mutating func parsePrimary() -> Double? {
            guard let c = peek else { return nil }
            if c == "(" {
                i += 1
                guard let v = parseExpression(), peek == ")" else { return nil }
                i += 1
                return v
            }
            if c.isNumber || c == "." { return parseNumber() }
            if c.isLetter { return parseIdentifier() }
            return nil
        }

        mutating func parseNumber() -> Double? {
            let start = i
            while let c = peek, c.isNumber || c == "." { i += 1 }
            return Double(String(chars[start..<i]))
        }

        mutating func parseIdentifier() -> Double? {
            let start = i
            while let c = peek, c.isLetter { i += 1 }
            let name = String(chars[start..<i])
            switch name {
            case "pi": return Double.pi
            case "e": return M_E
            default: break
            }
            guard peek == "(" else { return nil }
            i += 1
            guard let arg = parseExpression(), peek == ")" else { return nil }
            i += 1
            switch name {
            case "sqrt": return arg < 0 ? nil : sqrt(arg)
            case "sin": return sin(arg)
            case "cos": return cos(arg)
            case "tan": return tan(arg)
            case "ln": return arg <= 0 ? nil : log(arg)
            case "log": return arg <= 0 ? nil : log10(arg)
            case "abs": return abs(arg)
            case "round": return arg.rounded()
            case "floor": return arg.rounded(.down)
            case "ceil": return arg.rounded(.up)
            default: return nil
            }
        }
    }
}
