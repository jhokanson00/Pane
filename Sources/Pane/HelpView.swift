import AppKit
import SwiftUI

/// The how-to guide (HOWTO.md, copied into the app by scripts/build-app.sh), shown from
/// Help ▸ Pane Help. Only the bits of Markdown the guide uses are understood: a title,
/// headings, numbered and bulleted lines, bold or italic words, and ``` blocks, shown as
/// text to copy (the guide for AI assistants).
struct HelpView: View {
    private let blocks = HelpView.parse(HelpView.guide)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(blocks.indices, id: \.self) { index in
                    view(for: blocks[index])
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .frame(minWidth: 420, minHeight: 400)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .title(let text):
            Text(text).font(.largeTitle.weight(.bold))
        case .heading(let text):
            Text(text).font(.title2.weight(.semibold)).padding(.top, 14)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            CopyableText(text: text)
        }
    }

    enum Block {
        case title(String)
        case heading(String)
        case paragraph(String)
        case item(marker: String, text: String)
        /// A ``` block: shown as is, with a Copy button.
        case code(String)
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var code: [String]?
        for line in markdown.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
            } else if code != nil {
                code!.append(line)
            } else if let block = parse(line: line) {
                blocks.append(block)
            }
        }
        return blocks
    }

    private static func parse(line: String) -> Block? {
        let line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return nil }
        if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
        if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
        if line.hasPrefix("- ") { return .item(marker: "•", text: String(line.dropFirst(2))) }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
           line[line.index(after: dot)...].hasPrefix(" ") {
            return .item(marker: String(line[...dot]), text: String(line[line.index(dot, offsetBy: 2)...]))
        }
        return .paragraph(line)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The guide inside the app, or a pointer to it when running outside the app bundle.
    static var guide: String {
        Bundle.main.url(forResource: "HOWTO", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "# How to use Pane\n\nThe guide is in HOWTO.md, next to Pane's source code."
    }
}

/// Text to hand on, such as the guide for AI assistants: shown in a box, with a button that
/// copies all of it.
private struct CopyableText: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 260)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }
}
