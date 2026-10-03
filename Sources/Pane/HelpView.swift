import AppKit
import SwiftUI

/// The how-to guide (HOWTO.md, copied into the app by scripts/build-app.sh), shown from
/// Help ▸ Pane Help. Only the bits of Markdown the guide uses are understood: a title,
/// headings, numbered and bulleted lines, and bold or italic words.
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
        }
    }

    enum Block {
        case title(String)
        case heading(String)
        case paragraph(String)
        case item(marker: String, text: String)
    }

    static func parse(_ markdown: String) -> [Block] {
        markdown.components(separatedBy: .newlines).compactMap { line in
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
