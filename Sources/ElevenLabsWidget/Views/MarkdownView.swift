#if canImport(UIKit)
import SwiftUI

/// A lightweight, dependency-free block-level markdown renderer for agent chat
/// responses (and anywhere else we show rich text). It splits the source into
/// block elements – headings, paragraphs, lists, blockquotes, fenced code and
/// horizontal rules – and renders each as its own SwiftUI view, while reusing
/// `WidgetMarkdown.inlineAttributed` for inline styling (bold, italic,
/// strikethrough, inline code, links) inside each block.
///
/// Intentionally out of scope: tables and embedded images. Agents rarely emit
/// those and they are expensive to render well.
struct MarkdownView: View {
    let content: String
    var baseFont: Font = .subheadline

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(content) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(WidgetMarkdown.inlineAttributed(text))
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            Text(WidgetMarkdown.inlineAttributed(text))
                .font(baseFont)
                .fixedSize(horizontal: false, vertical: true)

        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker(for: item))
                            .font(baseFont)
                            .monospacedDigit()
                        Text(WidgetMarkdown.inlineAttributed(item.text))
                            .font(baseFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }

        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(WidgetMarkdown.inlineAttributed(text))
                    .font(baseFont)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
            }
            .background(
                Color.secondary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )

        case .rule:
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func marker(for item: MarkdownListItem) -> String {
        if let ordinal = item.ordinal {
            return "\(ordinal)."
        }
        return "\u{2022}"
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return baseFont.weight(.bold)
        }
    }
}

// MARK: - Model

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case list(items: [MarkdownListItem])
    case quote(text: String)
    case code(text: String)
    case rule
}

struct MarkdownListItem: Identifiable {
    let id = UUID()
    let text: String
    /// Nesting depth (0 = top level). Two leading spaces (or one tab) per level.
    let indent: Int
    /// `nil` renders a bullet; a value renders that number followed by a dot.
    let ordinal: Int?
}

// MARK: - Parser

enum MarkdownParser {
    static func parse(_ content: String) -> [MarkdownBlock] {
        let lines = content.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
            paragraph = []
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block: ``` ... ```
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // consume the closing fence
                blocks.append(.code(text: code.joined(separator: "\n")))
                continue
            }

            // Blank line ends the current paragraph.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule: ---, ***, ___ (3 or more).
            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Heading: # .. ###### followed by a space.
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }

            // Blockquote: one or more consecutive `>` lines.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var body = String(t.dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    quote.append(body)
                    i += 1
                }
                blocks.append(.quote(text: quote.joined(separator: "\n")))
                continue
            }

            // List: consecutive bullet or ordered items.
            if parseListItem(raw) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                while i < lines.count, let item = parseListItem(lines[i]) {
                    items.append(item)
                    i += 1
                }
                blocks.append(.list(items: items))
                continue
            }

            // Otherwise it's a paragraph line; soft-wrap into the current paragraph.
            paragraph.append(trimmed)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        for marker in ["-", "*", "_"] where trimmed.allSatisfy({ String($0) == marker }) {
            return true
        }
        return false
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        let hashes = trimmed.prefix { $0 == "#" }
        let level = hashes.count
        guard level >= 1, level <= 6 else { return nil }
        let rest = trimmed[hashes.endIndex...]
        guard rest.first == " " else { return nil }
        return (level, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ raw: String) -> MarkdownListItem? {
        let leading = raw.prefix { $0 == " " || $0 == "\t" }
        let indentWidth = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let indent = indentWidth / 2
        let rest = raw[leading.endIndex...]

        // Unordered: -, *, + followed by a space.
        if let first = rest.first, "-*+".contains(first) {
            let after = rest.dropFirst()
            if after.first == " " {
                return MarkdownListItem(
                    text: String(after.dropFirst()).trimmingCharacters(in: .whitespaces),
                    indent: indent,
                    ordinal: nil
                )
            }
        }

        // Ordered: digits followed by `.` or `)` and a space.
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = rest[digits.endIndex...]
            if let separator = afterDigits.first, separator == "." || separator == ")" {
                let afterSeparator = afterDigits.dropFirst()
                if afterSeparator.first == " " {
                    return MarkdownListItem(
                        text: String(afterSeparator.dropFirst()).trimmingCharacters(in: .whitespaces),
                        indent: indent,
                        ordinal: Int(digits) ?? 1
                    )
                }
            }
        }

        return nil
    }
}

#endif
