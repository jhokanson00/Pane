import Foundation

/// A teleprompter script: lines to say, with stage directions in square brackets.
///
///     Welcome to Brightline. [Point at the stats]
///     [Click Priya Duarte]
///     Card numbers and ID numbers are blurred too.
///
/// A bracketed part is a cue, shown but not read; it can sit alone on a line or inside one.
/// Blank lines only space the script out. Markdown headings ("# Share a Project") aren't
/// read either; the first one names the video.
public struct PrompterScript: Sendable, Equatable {
    public struct Word: Sendable, Equatable {
        /// As written, with its punctuation.
        public let text: String
        /// What it's matched on: see `PrompterScript.key(_:)`.
        public let key: String
        public let line: Int
    }

    public struct Cue: Sendable, Equatable {
        public let text: String
        public let line: Int
        /// The index of the first word after the cue (`words.count` at the very end). The cue
        /// is up next once every word before it has been said.
        public let beforeWord: Int
    }

    public struct Line: Sendable, Equatable {
        /// Its spoken words, as indices into `words` (empty for a cue-only line).
        public let words: Range<Int>
        /// Its cues, as indices into `cues`.
        public let cues: Range<Int>
    }

    public private(set) var words: [Word] = []
    public private(set) var cues: [Cue] = []
    public private(set) var lines: [Line] = []

    public init(_ text: String) {
        for raw in text.components(separatedBy: .newlines) {
            let source = raw.trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, !Self.isHeading(source) else { continue }
            let line = lines.count
            let firstWord = words.count, firstCue = cues.count
            var rest = Substring(source)
            while !rest.isEmpty {
                if rest.first == "[", let close = rest.firstIndex(of: "]") {
                    let cue = rest[rest.index(after: rest.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                    if !cue.isEmpty { cues.append(Cue(text: cue, line: line, beforeWord: words.count)) }
                    rest = rest[rest.index(after: close)...]
                } else {
                    let end = rest.dropFirst().firstIndex(of: "[") ?? rest.endIndex
                    for token in rest[..<end].split(whereSeparator: \.isWhitespace) {
                        let key = Self.key(String(token))
                        guard !key.isEmpty else { continue }
                        words.append(Word(text: String(token), key: key, line: line))
                    }
                    rest = rest[end...]
                }
            }
            lines.append(Line(words: firstWord..<words.count, cues: firstCue..<cues.count))
        }
    }

    /// The script's title: its first "# " heading, if it has one.
    public static func title(in text: String) -> String? {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("# ") else { continue }
            let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// "# Title", "## Part two": Markdown headings, which aren't said.
    static func isHeading(_ line: String) -> Bool {
        let marks = line.prefix { $0 == "#" }
        return !marks.isEmpty && marks.count <= 6 && line.dropFirst(marks.count).first == " "
    }

    /// Where each sentence starts, as word indices: after a word ending in . ! or ?, and at
    /// the start of every line.
    public var sentenceStarts: [Int] {
        var starts: [Int] = []
        var previousLine = -1
        var endedSentence = true
        for (index, word) in words.enumerated() {
            if endedSentence || word.line != previousLine { starts.append(index) }
            previousLine = word.line
            let bare = word.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
            endedSentence = bare.hasSuffix(".") || bare.hasSuffix("!") || bare.hasSuffix("?")
        }
        return starts
    }

    /// The spoken words, for the recognizer's list of words to expect.
    public var vocabulary: [String] {
        var seen = Set<String>()
        return words.compactMap { word in
            let bare = word.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            return bare.count > 2 && seen.insert(bare.lowercased()).inserted ? bare : nil
        }
    }

    /// Lower case without accents or punctuation, with small numbers as digits, so "Two,"
    /// and "2" match: speech recognition writes numbers either way.
    public static func key(_ token: String) -> String {
        let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
        let bare = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return numberWords[bare].map(String.init) ?? bare
    }

    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20,
    ]
}

extension PrompterScript {
    /// The script a recording was made with, stored in the video file's extended
    /// attributes like the pointer log, so retakes can be found later.
    static let attributeName = "com.jacobhokanson.pane.script"

    public static func save(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        let result = data.withUnsafeBytes { bytes in
            setxattr(url.path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    /// The script recorded with `url`, or nil if it wasn't recorded with the teleprompter.
    public static func load(from url: URL) -> String? {
        let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in
            getxattr(url.path, attributeName, bytes.baseAddress, size, 0, 0)
        }
        guard read == size else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
