import Foundation

/// One block of a rendered message: either prose (which may contain inline
/// markdown like **bold**) or a fenced code block.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case code(code: String, language: String?)
}

/// Splits message text into paragraphs and fenced code blocks.
///
/// Deliberately small: full CommonMark is overkill for chat, and the split
/// that actually matters visually is "code vs. not code". Inline markdown
/// inside paragraphs is left for `AttributedString` to interpret at render
/// time (see `MarkdownText`).
enum MarkdownBlocks {

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCode = false

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphLines.removeAll()
        }

        func flushCode() {
            blocks.append(.code(code: codeLines.joined(separator: "\n"),
                                 language: codeLanguage))
            codeLines.removeAll()
            codeLanguage = nil
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushParagraph()
                    let language = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    inCode = true
                }
            } else if inCode {
                codeLines.append(line)
            } else if trimmed.isEmpty {
                flushParagraph()
            } else {
                paragraphLines.append(line)
            }
        }

        // An unterminated fence still renders as code — while a response is
        // streaming in, the closing fence simply hasn't arrived yet.
        if inCode {
            flushCode()
        } else {
            flushParagraph()
        }
        return blocks
    }
}
