import Foundation

/// 数式を計算する。式を自前で読み解き、許可した演算・関数・定数だけを扱う
/// （Web ページやメール経由で悪意ある式を渡されても、計算以外のことはできない）
///
/// 書ける式: + - * / // % ** ^ × ÷、かっこ、[1, 2, 3] のような並び、
/// 関数 abs round min max sum int float sqrt floor ceil log log10 log2 exp sin cos tan radians degrees factorial gcd、定数 pi e
enum Calculator {
    static func evaluate(_ expression: String) async throws -> String {
        let value = try compute(expression)
        return "\(expression) = \(format(value))"
    }

    /// 計算だけを行い、数値を返す（書式は付けない）
    static func compute(_ expression: String) throws -> Double {
        guard expression.count <= 1000 else { throw fail("式が長すぎます") }
        var parser = Parser(tokens: try tokenize(normalize(expression)))
        let v = try parser.parseExpression()
        guard parser.atEnd else { throw fail("使えない書き方です: \(parser.peekText)") }
        return try v.number()
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.12g", v)
        if s.contains("e") { s = s.replacingOccurrences(of: "e+", with: "e") }
        return s
    }

    // MARK: 字句

    private static func normalize(_ s: String) -> String {
        let half = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s  // 全角の数字・記号を半角に
        return half.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "、", with: ",")
    }

    fileprivate enum Token: Equatable, CustomStringConvertible {
        case number(Double), name(String), op(String), lparen, rparen, lbracket, rbracket, comma

        /// エラー文に出すときの表記
        var description: String {
            switch self {
            case .number(let v): Calculator.format(v)
            case .name(let n): n
            case .op(let o): o
            case .lparen: "("
            case .rparen: ")"
            case .lbracket: "["
            case .rbracket: "]"
            case .comma: ","
            }
        }
    }

    private static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isASCII, c.isNumber || c == "." {
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isNumber || chars[j] == "." || chars[j] == "_" { j += 1 }
                // 指数表記（1e3, 2.5E-4）
                if j < chars.count, chars[j] == "e" || chars[j] == "E" {
                    var k = j + 1
                    if k < chars.count, chars[k] == "+" || chars[k] == "-" { k += 1 }
                    if k < chars.count, chars[k].isASCII, chars[k].isNumber {
                        while k < chars.count, chars[k].isASCII, chars[k].isNumber { k += 1 }
                        j = k
                    }
                }
                let text = String(chars[i..<j]).replacingOccurrences(of: "_", with: "")
                guard let v = Double(text) else { throw fail("数字を読めません: \(text)") }
                tokens.append(.number(v)); i = j; continue
            }
            if c.isASCII, c.isLetter {
                var j = i
                while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                tokens.append(.name(String(chars[i..<j]).lowercased())); i = j; continue
            }
            let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
            if two == "**" || two == "//" { tokens.append(.op(two)); i += 2; continue }
            switch c {
            case "+", "-", "*", "/", "%": tokens.append(.op(String(c)))
            case "^": tokens.append(.op("**"))
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            case "[": tokens.append(.lbracket)
            case "]": tokens.append(.rbracket)
            case ",": tokens.append(.comma)
            default: throw fail("使えない文字です: \(c)")
            }
            i += 1
        }
        return tokens
    }

    // MARK: 構文（Python と同じ優先順位: 単項の - は ** より弱く、** は右結合）

    /// 数値、または関数に渡す並び（[1, 2, 3]）
    fileprivate enum Value {
        case number(Double), list([Double])
        func number() throws -> Double {
            guard case .number(let v) = self else { throw fail("並び（[...]）は関数に渡すときだけ使えます") }
            return v
        }
        var flattened: [Double] {
            switch self { case .number(let v): [v]; case .list(let l): l }
        }
    }

    fileprivate struct Parser {
        let tokens: [Token]
        var pos = 0
        var depth = 0

        var atEnd: Bool { pos >= tokens.count }
        var peekText: String { atEnd ? "" : "\(tokens[pos])" }

        mutating func next() -> Token? {
            guard pos < tokens.count else { return nil }
            defer { pos += 1 }
            return tokens[pos]
        }

        mutating func expect(_ t: Token, _ message: String) throws {
            guard next() == t else { throw fail(message) }
        }

        mutating func nest<T>(_ body: (inout Parser) throws -> T) throws -> T {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw fail("かっこが深すぎます") }
            return try body(&self)
        }

        // 足し算・引き算
        mutating func parseExpression() throws -> Value {
            var left = try parseTerm()
            while case .op(let o)? = tokens[safe: pos], o == "+" || o == "-" {
                pos += 1
                let right = try parseTerm().number()
                left = .number(try check(o == "+" ? left.number() + right : left.number() - right))
            }
            return left
        }

        // 掛け算・割り算・余り
        mutating func parseTerm() throws -> Value {
            var left = try parseUnary()
            while case .op(let o)? = tokens[safe: pos], ["*", "/", "//", "%"].contains(o) {
                pos += 1
                let a = try left.number(), b = try parseUnary().number()
                if o != "*", b == 0 { throw fail("0 で割ることはできません") }
                switch o {
                case "*": left = .number(try check(a * b))
                case "/": left = .number(try check(a / b))
                case "//": left = .number(try check((a / b).rounded(.down)))
                default: left = .number(try check(a - b * (a / b).rounded(.down)))  // Python と同じく、余りは割る数と同じ符号
                }
            }
            return left
        }

        // 符号
        mutating func parseUnary() throws -> Value {
            if case .op(let o)? = tokens[safe: pos], o == "+" || o == "-" {
                pos += 1
                let v = try nest { try $0.parseUnary() }.number()
                return .number(o == "-" ? -v : v)
            }
            return try parsePower()
        }

        // べき乗（右結合。2 ** -1 のように指数には符号が付けられる）
        mutating func parsePower() throws -> Value {
            let base = try parsePrimary()
            guard case .op("**")? = tokens[safe: pos] else { return base }
            pos += 1
            let exponent = try nest { try $0.parseUnary() }.number()
            guard abs(exponent) <= 1000 else { throw fail("指数が大きすぎます") }
            let b = try base.number()
            if b == 0, exponent < 0 { throw fail("0 で割ることはできません") }
            return .number(try check(pow(b, exponent)))
        }

        mutating func parsePrimary() throws -> Value {
            guard let t = next() else { throw fail("式が途中で終わっています") }
            switch t {
            case .number(let v):
                return .number(v)
            case .lparen:
                let v = try nest { try $0.parseExpression() }
                try expect(.rparen, "かっこが閉じていません")
                return v
            case .lbracket:
                var items: [Double] = []
                if tokens[safe: pos] == .rbracket { pos += 1; return .list(items) }
                repeat {
                    items += try nest { try $0.parseExpression() }.flattened
                    guard items.count <= 10_000 else { throw fail("並びが長すぎます") }
                } while try consumeComma()
                try expect(.rbracket, "[ が閉じていません")
                return .list(items)
            case .name(let n):
                if tokens[safe: pos] == .lparen {
                    pos += 1
                    var args: [Value] = []
                    if tokens[safe: pos] != .rparen {
                        repeat { args.append(try nest { try $0.parseExpression() }) } while try consumeComma()
                    }
                    try expect(.rparen, "\(n)( のかっこが閉じていません")
                    return .number(try check(Calculator.call(n, args)))
                }
                switch n {
                case "pi": return .number(Double.pi)
                case "e": return .number(M_E)
                default: throw fail("使えない名前です: \(n)")
                }
            default:
                throw fail("使えない書き方です: \(t)")
            }
        }

        mutating func consumeComma() throws -> Bool {
            guard tokens[safe: pos] == .comma else { return false }
            pos += 1
            return true
        }
    }

    // MARK: 関数

    private static func call(_ name: String, _ args: [Value]) throws -> Double {
        func one() throws -> Double {
            guard args.count == 1 else { throw fail("\(name) には数を1つ渡してください") }
            return try args[0].number()
        }
        func all() throws -> [Double] {
            let v = args.flatMap(\.flattened)
            guard !v.isEmpty else { throw fail("\(name) に数が渡されていません") }
            return v
        }
        func positive(_ v: Double) throws -> Double {
            guard v > 0 else { throw fail("\(name) には正の数を渡してください") }
            return v
        }
        switch name {
        case "abs": return abs(try one())
        case "round":
            guard (1...2).contains(args.count) else { throw fail("round には数と桁数を渡してください") }
            let v = try args[0].number()
            let digits = args.count == 2 ? try args[1].number() : 0
            guard abs(digits) <= 15 else { throw fail("桁数が大きすぎます") }
            let scale = pow(10, digits.rounded())
            return (v * scale).rounded(.toNearestOrEven) / scale  // Python の round と同じく、ちょうど半分は偶数側へ
        case "min": return try all().min()!
        case "max": return try all().max()!
        case "sum": return args.flatMap(\.flattened).reduce(0, +)
        case "int": return try one().rounded(.towardZero)
        case "float": return try one()
        case "sqrt":
            let v = try one()
            guard v >= 0 else { throw fail("負の数の平方根は計算できません") }
            return v.squareRoot()
        case "floor": return try one().rounded(.down)
        case "ceil": return try one().rounded(.up)
        case "log":
            guard (1...2).contains(args.count) else { throw fail("log には数を1つか2つ渡してください") }
            let v = try positive(args[0].number())
            if args.count == 2 { return Foundation.log(v) / Foundation.log(try positive(args[1].number())) }
            return Foundation.log(v)
        case "log10": return log10(try positive(one()))
        case "log2": return log2(try positive(one()))
        case "exp": return exp(try one())
        case "sin": return sin(try one())
        case "cos": return cos(try one())
        case "tan": return tan(try one())
        case "radians": return try one() * .pi / 180
        case "degrees": return try one() * 180 / .pi
        case "factorial":
            let n = try one()
            guard n >= 0, n == n.rounded() else { throw fail("factorial には 0 以上の整数を渡してください") }
            guard n <= 170 else { throw fail("大きすぎます") }
            return n < 2 ? 1 : (2...Int(n)).reduce(1.0) { $0 * Double($1) }
        case "gcd":
            let v = try all()
            guard v.allSatisfy({ $0 == $0.rounded() && abs($0) < 1e15 }) else { throw fail("gcd には整数を渡してください") }
            return Double(v.map { abs(Int64($0)) }.reduce(Int64(0)) { a, b in
                var (x, y) = (a, b)
                while y != 0 { (x, y) = (y, x % y) }
                return x
            })
        default:
            throw fail("使えない関数です: \(name)")
        }
    }

    private static func fail(_ message: String) -> Tools.ToolError { Tools.ToolError(message: message) }

    fileprivate static func check(_ v: Double) throws -> Double {
        guard v.isFinite else { throw fail("結果が大きすぎるか、計算できません") }
        return v
    }
}
