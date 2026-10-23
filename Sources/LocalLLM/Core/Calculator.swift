import Foundation

/// Phase 5: the calculator tool's arithmetic.
///
/// A small hand-written recursive-descent parser — deliberately NOT
/// an eval, a JavaScript bridge, or NSExpression (which would happily
/// evaluate functions beyond arithmetic). It understands numbers,
/// `+ - * / % ^`, parentheses, unary minus, and `sqrt` / `abs`, and
/// nothing else; anything it doesn't understand is an error string,
/// never a crash. Pure and fully unit-tested.
enum Calculator {

    /// The largest expression the parser will look at — a guard rail,
    /// not a real limit anyone hits doing arithmetic.
    static let maxExpressionLength = 200

    /// Evaluate an expression to the string the model (and user) sees:
    /// either the formatted result or a plain "couldn't" message.
    static func evaluate(_ rawExpression: String) -> String {
        let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else {
            return "Couldn't calculate that — no expression was given."
        }
        guard expression.count <= maxExpressionLength else {
            return "Couldn't calculate that — the expression is too long."
        }
        var parser = Parser(expression)
        do {
            let value = try parser.parseExpression()
            try parser.expectEnd()
            return format(value)
        } catch let error as ParseError {
            return "Couldn't calculate that — \(error.message)."
        } catch {
            return "Couldn't calculate that."
        }
    }

    /// Human formatting: integers without a decimal point, fractions
    /// trimmed to at most 6 decimal places, no negative zero.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "the result isn't a finite number" }
        let cleaned = value == 0 ? 0.0 : value // folds -0 into 0
        if cleaned == cleaned.rounded() && abs(cleaned) < 1e15 {
            return String(Int64(cleaned))
        }
        var text = String(format: "%.6f", cleaned)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: - Parser

    struct ParseError: Error {
        let message: String
    }

    /// Grammar:
    ///   expression := term (('+' | '-') term)*
    ///   term       := factor (('*' | '/' | '%') factor)*
    ///   factor     := unary ('^' factor)?        (right-associative)
    ///   unary      := '-' unary | primary
    ///   primary    := number | '(' expression ')' | name '(' expression ')'
    private struct Parser {
        private let characters: [Character]
        private var position = 0

        init(_ expression: String) {
            characters = Array(expression)
        }

        private var peeked: Character? {
            position < characters.count ? characters[position] : nil
        }

        private mutating func skipSpaces() {
            while let c = peeked, c == " " || c == "\t" { position += 1 }
        }

        mutating func expectEnd() throws {
            skipSpaces()
            guard peeked == nil else {
                throw ParseError(message: "there was extra text it didn't understand")
            }
        }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while true {
                skipSpaces()
                guard let op = peeked, op == "+" || op == "-" else { return value }
                position += 1
                let rhs = try parseTerm()
                value = op == "+" ? value + rhs : value - rhs
            }
        }

        private mutating func parseTerm() throws -> Double {
            var value = try parseFactor()
            while true {
                skipSpaces()
                guard let op = peeked, op == "*" || op == "/" || op == "%" else { return value }
                position += 1
                let rhs = try parseFactor()
                switch op {
                case "*":
                    value *= rhs
                case "/":
                    guard rhs != 0 else { throw ParseError(message: "division by zero") }
                    value /= rhs
                default: // %
                    guard rhs != 0 else { throw ParseError(message: "remainder by zero") }
                    value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
        }

        private mutating func parseFactor() throws -> Double {
            let base = try parseUnary()
            skipSpaces()
            guard peeked == "^" else { return base }
            position += 1
            let exponent = try parseFactor()
            return pow(base, exponent)
        }

        private mutating func parseUnary() throws -> Double {
            skipSpaces()
            if peeked == "-" {
                position += 1
                return -(try parseUnary())
            }
            if peeked == "+" {
                position += 1
                return try parseUnary()
            }
            return try parsePrimary()
        }

        private mutating func parsePrimary() throws -> Double {
            skipSpaces()
            guard let c = peeked else {
                throw ParseError(message: "the expression ended early")
            }
            if c == "(" {
                position += 1
                let value = try parseExpression()
                skipSpaces()
                guard peeked == ")" else {
                    throw ParseError(message: "a closing parenthesis is missing")
                }
                position += 1
                return value
            }
            if c.isNumber || c == "." {
                return try parseNumber()
            }
            if c.isLetter {
                return try parseFunction()
            }
            throw ParseError(message: "unexpected character \u{201C}\(c)\u{201D}")
        }

        private mutating func parseNumber() throws -> Double {
            var text = ""
            var sawDigit = false
            var sawDot = false
            while let c = peeked {
                if c.isNumber {
                    sawDigit = true
                    text.append(c)
                    position += 1
                } else if c == "." && !sawDot {
                    sawDot = true
                    text.append(c)
                    position += 1
                } else {
                    break
                }
            }
            guard sawDigit, let value = Double(text) else {
                throw ParseError(message: "a number was malformed")
            }
            return value
        }

        private mutating func parseFunction() throws -> Double {
            var name = ""
            while let c = peeked, c.isLetter {
                name.append(c)
                position += 1
            }
            skipSpaces()
            guard peeked == "(" else {
                throw ParseError(message: "\u{201C}\(name)\u{201D} isn't a number or a known function")
            }
            position += 1
            let argument = try parseExpression()
            skipSpaces()
            guard peeked == ")" else {
                throw ParseError(message: "a closing parenthesis is missing")
            }
            position += 1
            switch name.lowercased() {
            case "sqrt":
                guard argument >= 0 else {
                    throw ParseError(message: "the square root of a negative number isn't a real number")
                }
                return sqrt(argument)
            case "abs":
                return abs(argument)
            default:
                throw ParseError(message: "\u{201C}\(name)\u{201D} isn't a function it knows (sqrt and abs are)")
            }
        }
    }
}
