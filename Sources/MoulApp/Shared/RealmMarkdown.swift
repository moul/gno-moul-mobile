import SwiftUI

/// Renders what a realm's `Render` returns.
///
/// Gno markdown is markdown plus gnoweb's own block tags (`<gno-columns>`,
/// `<gno-form>`), which mean nothing outside a browser. They are dropped rather
/// than shown: a reader should see the realm's text, not gnoweb's layout
/// instructions.
struct RealmMarkdown: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [Block] {
        Block.parse(source)
    }
}

private struct Block: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)
        case code(String)
        case rule
    }

    let id = UUID()
    let kind: Kind

    @ViewBuilder var view: some View {
        switch kind {
        case let .heading(level, text):
            Text(inline(text))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text))
            }
        case let .paragraph(text):
            Text(inline(text))
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.caption, design: .monospaced))
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    /// SwiftUI parses inline markdown (bold, links, code spans) on its own; only
    /// the block structure has to be done here.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(Block(kind: .paragraph(text)))
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(Block(kind: .code(code.joined(separator: "\n"))))
                    code.removeAll()
                }
                inCode.toggle()
                continue
            }
            if inCode {
                code.append(rawLine)
                continue
            }

            // gnoweb's own tags carry no meaning here.
            if line.hasPrefix("<gno-") || line == "</gno-columns>" || line.hasPrefix("</gno-") {
                flushParagraph()
                continue
            }

            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix { $0 == "#" }.count
                blocks.append(Block(kind: .heading(
                    level: level,
                    text: String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                )))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(Block(kind: .bullet(String(line.dropFirst(2)))))
            } else if rawLine.first?.isWhitespace == true,
                      case .bullet(let started)? = blocks.last?.kind,
                      paragraph.isEmpty {
                // An indented line under a bullet continues it. Treating it as a
                // new paragraph splits every wrapped list item in two, which is
                // most of them: realms wrap their markdown at 80 columns.
                blocks[blocks.count - 1] = Block(kind: .bullet(started + " " + line))
            } else if line.hasPrefix("---") {
                flushParagraph()
                blocks.append(Block(kind: .rule))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if inCode, !code.isEmpty {
            blocks.append(Block(kind: .code(code.joined(separator: "\n"))))
        }
        return blocks
    }
}
