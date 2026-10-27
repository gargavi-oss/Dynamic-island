import Foundation

/// Tiny safe expression evaluator for the launcher: + - * / ^ ( ) and decimals.
/// (Hand-written on purpose: NSExpression raises uncatchable exceptions on bad input.)
enum Calculator {
    /// Returns a formatted answer, or nil if the text isn't a math expression.
    static func evaluate(_ input: String) -> String? {
        let cleaned = input
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "x", with: "*")
            .filter { !$0.isWhitespace && $0 != "," }
        let chars = Array(cleaned)

        // Needs a real operator (a leading minus alone doesn't count).
        guard chars.dropFirst().contains(where: { "+-*/^".contains($0) }) else { return nil }

        var parser = Parser(c: chars)
        guard let value = parser.parseExpression(), parser.i == chars.count,
              value.isFinite else { return nil }
        return format(value)
    }

    private static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.10g", v)
    }

    private struct Parser {
        let c: [Character]
        var i = 0

        // expression := term (('+' | '-') term)*
        mutating func parseExpression() -> Double? {
            guard var v = parseTerm() else { return nil }
            while i < c.count, c[i] == "+" || c[i] == "-" {
                let op = c[i]; i += 1
                guard let r = parseTerm() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        // term := unary (('*' | '/') unary)*
        mutating func parseTerm() -> Double? {
            guard var v = parseUnary() else { return nil }
            while i < c.count, c[i] == "*" || c[i] == "/" {
                let op = c[i]; i += 1
                guard let r = parseUnary() else { return nil }
                if op == "/" {
                    if r == 0 { return nil }
                    v /= r
                } else {
                    v *= r
                }
            }
            return v
        }

        // unary := ('-' | '+') unary | power
        mutating func parseUnary() -> Double? {
            if i < c.count, c[i] == "-" { i += 1; return parseUnary().map { -$0 } }
            if i < c.count, c[i] == "+" { i += 1; return parseUnary() }
            return parsePower()
        }

        // power := atom ('^' unary)?      (right-associative, so -2^2 = -4)
        mutating func parsePower() -> Double? {
            guard let base = parseAtom() else { return nil }
            if i < c.count, c[i] == "^" {
                i += 1
                guard let e = parseUnary() else { return nil }
                return pow(base, e)
            }
            return base
        }

        // atom := number | '(' expression ')'
        mutating func parseAtom() -> Double? {
            if i < c.count, c[i] == "(" {
                i += 1
                guard let v = parseExpression(), i < c.count, c[i] == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while i < c.count, c[i].isNumber || c[i] == "." { i += 1 }
            guard i > start else { return nil }
            return Double(String(c[start..<i]))
        }
    }
}
