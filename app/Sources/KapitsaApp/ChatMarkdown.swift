import SwiftUI
import AppKit

struct ChatMarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph, heading(Int), code(String), quote, list, rule, table
    }
    let id: Int
    let kind: Kind
    let lines: [String]

    static func parse(_ source: String) -> [Self] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [Self] = []
        var index = 0
        func emit(_ kind: Kind, _ text: [String], _ start: Int) {
            blocks.append(Self(id: start, kind: kind, lines: text))
        }
        while index < lines.count {
            let start = index
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index]); index += 1
                }
                if index < lines.count { index += 1 }
                emit(.code(language), code, start)
            } else if let heading = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
                emit(.heading(trimmed[heading].count - 1), [String(trimmed[heading.upperBound...])], start)
                index += 1
            } else if trimmed.range(of: #"^([-*_])(?:\s*\1){2,}$"#, options: .regularExpression) != nil {
                emit(.rule, [], start); index += 1
            } else if index + 1 < lines.count, line.contains("|"), isTableDivider(lines[index + 1]) {
                var rows = [line]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].isEmpty {
                    rows.append(lines[index]); index += 1
                }
                emit(.table, rows, start)
            } else if trimmed.hasPrefix(">") {
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                emit(.quote, quote, start)
            } else if isList(line) {
                var items: [String] = []
                while index < lines.count, isList(lines[index]) {
                    items.append(lines[index]); index += 1
                }
                emit(.list, items, start)
            } else {
                var paragraph = [line]
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    if next.hasPrefix("```") || next.hasPrefix("~~~") || next.hasPrefix("#") ||
                        next.hasPrefix(">") || isList(next) { break }
                    paragraph.append(lines[index]); index += 1
                }
                emit(.paragraph, paragraph, start)
            }
        }
        return blocks
    }

    private static func isList(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:[-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct ChatMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ChatMarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .paragraph: inline(block.lines.joined(separator: "\n"))
                case .heading(let level):
                    inline(block.lines.joined(separator: "\n"))
                        .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                case .code(let language):
                    ChatCodeBlock(language: language, code: block.lines.joined(separator: "\n"))
                case .quote:
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)).frame(width: 3)
                        inline(block.lines.joined(separator: "\n")).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                case .list:
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(block.lines.enumerated()), id: \.offset) { _, line in
                            if let marker = line.range(of: #"^\s*(?:[-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                                HStack(alignment: .top, spacing: 8) {
                                    let label = line[marker].trimmingCharacters(in: .whitespaces)
                                    Text(["-", "*", "+"].contains(label) ? "•" : label).frame(minWidth: 16)
                                    inline(String(line[marker.upperBound...]))
                                }
                            }
                        }
                    }
                case .rule: Divider()
                case .table:
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                            ForEach(Array(block.lines.enumerated()), id: \.offset) { row, line in
                                GridRow {
                                    ForEach(Array(ChatMarkdownBlock.tableCells(line).enumerated()), id: \.offset) { _, cell in
                                        inline(cell).fontWeight(row == 0 ? .semibold : .regular)
                                    }
                                }
                                if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(12)
                    }.background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
            return .systemAction
        })
    }

    private func inline(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value,
             options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}

private struct ChatCodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }.buttonStyle(.borderless).font(.caption)
                    .accessibilityLabel(copied ? "Code copié" : "Copier le code")
            }.padding(10)
            Divider()
            ScrollView(.horizontal) {
                Text(code).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).padding(12).fixedSize(horizontal: true, vertical: false)
            }
        }.background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: code) { _, _ in copied = false }
    }
}
