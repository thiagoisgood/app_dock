import SwiftUI

/// 轻量级 Markdown → AttributedString 转换器
/// 支持：## 标题、- 列表、**粗体**、`代码`
enum MarkdownTextBuilder {
    static func build(from markdown: String) -> AttributedString {
        var result = AttributedString()
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            var segment: AttributedString

            if trimmed.hasPrefix("### ") {
                segment = processInline(text)
                segment.font = .system(size: 14, weight: .semibold)
                segment.foregroundColor = .secondary
            } else if trimmed.hasPrefix("## ") {
                segment = processInline(text)
                segment.font = .system(size: 18, weight: .bold)
                segment.foregroundColor = .blue
            } else if trimmed.hasPrefix("# ") {
                segment = processInline(text)
                segment.font = .system(size: 22, weight: .bold)
                segment.foregroundColor = .blue
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") {
                var item = AttributedString("    • ")
                let content = String(text.drop(while: { $0 == "-" || $0 == "•" || $0 == " " }))
                item.append(processInline(content))
                segment = item
            } else if trimmed.isEmpty {
                segment = AttributedString("\n")
            } else {
                segment = processInline(text)
            }
            segment.append(AttributedString("\n"))
            result.append(segment)
        }

        return result
    }

    private static func processInline(_ text: String) -> AttributedString {
        var result = AttributedString()
        let scanner = text
        var pos = scanner.startIndex

        while pos < scanner.endIndex {
            // Try **bold**
            if scanner[pos...].hasPrefix("**") {
                let afterOpen = scanner.index(pos, offsetBy: 2)
                if let closePos = scanner[afterOpen...].range(of: "**")?.lowerBound {
                    let boldText = String(scanner[afterOpen..<closePos])
                    var attr = AttributedString(boldText)
                    attr.font = .system(.body, weight: .bold)
                    result.append(attr)
                    pos = scanner.index(closePos, offsetBy: 2)
                    continue
                }
            }

            // Try `code`
            if scanner[pos...].hasPrefix("`") {
                let afterOpen = scanner.index(after: pos)
                if let closePos = scanner[afterOpen...].range(of: "`")?.lowerBound {
                    let codeText = String(scanner[afterOpen..<closePos])
                    var attr = AttributedString(codeText)
                    attr.font = .system(.body, design: .monospaced)
                    result.append(attr)
                    pos = scanner.index(after: closePos)
                    continue
                }
            }

            // Plain character
            var end = pos
            while end < scanner.endIndex {
                if scanner[end...].hasPrefix("**") || scanner[end...].hasPrefix("`") {
                    break
                }
                end = scanner.index(after: end)
            }
            let plain = String(scanner[pos..<end])
            if !plain.isEmpty {
                result.append(AttributedString(plain))
            }
            pos = end
        }

        return result
    }
}
