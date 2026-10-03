import Foundation

public enum SensitiveKind: String, Codable, CaseIterable, Sendable {
    case email, phone, secret, cardNumber, governmentID, customWord, manual

    public var label: String {
        switch self {
        case .email: "Email"
        case .phone: "Phone number"
        case .secret: "Key or secret"
        case .cardNumber: "Card number"
        case .governmentID: "ID number"
        case .customWord: "Your word list"
        case .manual: "Manual blur"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .email: "envelope"
        case .phone: "phone"
        case .secret: "key"
        case .cardNumber: "creditcard"
        case .governmentID: "person.text.rectangle"
        case .customWord: "text.word.spacing"
        case .manual: "rectangle.dashed"
        }
    }
}

/// One sensitive piece of text found inside a line.
public struct TextMatch: Equatable, Sendable {
    public let kind: SensitiveKind
    public let range: Range<String.Index>
    public var text: Substring { line[range] }
    let line: String
}

/// Finds sensitive text in a single line of recognized text.
public struct SensitiveDetector: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        public var kinds: Set<SensitiveKind>
        public var customWords: [String]

        public init(kinds: Set<SensitiveKind> = Set(SensitiveKind.allCases), customWords: [String] = []) {
            self.kinds = kinds
            self.customWords = customWords
        }
    }

    private let options: Options
    private let customPattern: NSRegularExpression?

    public init(options: Options) {
        self.options = options
        let words = options.customWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(NSRegularExpression.escapedPattern(for:))
        customPattern = words.isEmpty ? nil : try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])(?:"# + words.joined(separator: "|") + #")(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        )
    }

    public func matches(in line: String) -> [TextMatch] {
        // Earlier categories win when matches overlap (e.g. a key that looks like a number).
        var found: [(SensitiveKind, NSRange)] = []
        func add(_ kind: SensitiveKind, _ ranges: [NSRange]) {
            guard options.kinds.contains(kind) else { return }
            for range in ranges where !found.contains(where: { NSIntersectionRange($0.1, range).length > 0 }) {
                found.append((kind, range))
            }
        }

        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        func ranges(_ regex: NSRegularExpression, group: Int = 0, where valid: (String) -> Bool = { _ in true }) -> [NSRange] {
            regex.matches(in: line, range: all).compactMap { result in
                let range = result.range(at: group)
                guard range.location != NSNotFound, valid(ns.substring(with: range)) else { return nil }
                return range
            }
        }

        add(.secret, Patterns.secrets.flatMap { ranges($0) })
        add(.secret, ranges(Patterns.assignment, group: 1))
        add(.secret, ranges(Patterns.highEntropy, where: Self.looksRandom))
        add(.email, ranges(Patterns.email))
        add(.cardNumber, ranges(Patterns.card, where: Self.isCardNumber))
        add(.governmentID, ranges(Patterns.ssn))
        add(.phone, ranges(Patterns.phone, where: Self.isPhoneNumber))
        if let customPattern {
            add(.customWord, ranges(customPattern))
        }

        return found
            .sorted { $0.1.location < $1.1.location }
            .compactMap { kind, range in
                Range(range, in: line).map { TextMatch(kind: kind, range: $0, line: line) }
            }
    }

    // MARK: - Validation

    static func digits(_ s: String) -> [Int] {
        s.compactMap { $0.wholeNumberValue }
    }

    static func isPhoneNumber(_ s: String) -> Bool {
        (10...15).contains(digits(s).count)
    }

    /// 13–19 digits passing the Luhn checksum that card numbers use.
    static func isCardNumber(_ s: String) -> Bool {
        let d = digits(s)
        guard (13...19).contains(d.count) else { return false }
        let sum = d.reversed().enumerated().reduce(0) { total, item in
            let (i, digit) = item
            guard i % 2 == 1 else { return total + digit }
            let doubled = digit * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    /// Long tokens mixing upper case, lower case and digits, like most generated keys.
    static func looksRandom(_ s: String) -> Bool {
        s.contains(where: \.isUppercase) && s.contains(where: \.isLowercase) && s.contains(where: \.isNumber)
    }
}

private enum Patterns {
    static func make(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let email = make(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, [.caseInsensitive])

    static let phone = make(#"(?<![\w+])(?:\+\d{1,3}[\s.\-]?)?(?:\(\d{2,4}\)|\d{2,4})[\s.\-]?\d{3,4}[\s.\-]?\d{3,4}(?!\w)"#)

    static let card = make(#"(?<!\d)(?:\d[ \-]?){12,18}\d(?!\d)"#)

    static let ssn = make(#"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#)

    /// Well-known key formats.
    static let secrets = [
        #"sk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_\-]{16,}"#,      // OpenAI, Anthropic and similar
        #"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,              // GitHub tokens
        #"github_pat_[A-Za-z0-9_]{20,}"#,                          // GitHub fine-grained tokens
        #"(?:AKIA|ASIA)[0-9A-Z]{16}"#,                             // AWS access keys
        #"xox[abporsc]-[A-Za-z0-9\-]{10,}"#,                       // Slack tokens
        #"AIza[0-9A-Za-z_\-]{30,}"#,                               // Google API keys
        #"(?:pk|sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#,           // Stripe keys
        #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, // JWTs
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ].map { make($0) }

    /// `password: hunter2`, `API_KEY="…"` and similar. Group 1 is the value.
    static let assignment = make(
        #"\b(?:password|passwd|pwd|pass|secret|token|api[_\-]?key|access[_\-]?key|auth)\b["']?\s*[:=]\s*["']?([^\s"',;]{4,})"#,
        [.caseInsensitive])

    /// Long random-looking tokens (checked with `looksRandom`).
    static let highEntropy = make(#"(?<![A-Za-z0-9_\-+/=])[A-Za-z0-9_\-+/=]{24,}(?![A-Za-z0-9_\-+/=])"#)
}
