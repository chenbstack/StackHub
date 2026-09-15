import SwiftUI

/// A small ANSI/VT100 SGR renderer for process output. Service logs are not
/// terminal emulators, but preserving colors makes common Node, Go and CLI
/// output considerably easier to scan.
enum ANSILogColor: Equatable {
    case standard(Int)
    case indexed(Int)
    case rgb(Int, Int, Int)

    var swiftUIColor: Color {
        switch self {
        case .standard(let index):
            let colors: [Color] = [
                Color(red: 0.52, green: 0.55, blue: 0.61),
                Color(red: 0.96, green: 0.38, blue: 0.38),
                Color(red: 0.54, green: 0.84, blue: 0.38),
                Color(red: 0.96, green: 0.78, blue: 0.32),
                Color(red: 0.42, green: 0.67, blue: 1.0),
                Color(red: 0.89, green: 0.48, blue: 0.95),
                Color(red: 0.30, green: 0.86, blue: 0.89),
                Color(red: 0.88, green: 0.90, blue: 0.94),
                Color(red: 0.63, green: 0.66, blue: 0.72),
                Color(red: 1.0, green: 0.52, blue: 0.50),
                Color(red: 0.66, green: 0.96, blue: 0.48),
                Color(red: 1.0, green: 0.88, blue: 0.48),
                Color(red: 0.54, green: 0.76, blue: 1.0),
                Color(red: 0.96, green: 0.62, blue: 1.0),
                Color(red: 0.47, green: 0.94, blue: 0.96),
                Color.white
            ]
            return colors[Swift.min(Swift.max(index, 0), colors.count - 1)]

        case .indexed(let index) where index < 16:
            return ANSILogColor.standard(index).swiftUIColor

        case .indexed(let index) where (16...231).contains(index):
            let levels = [0, 95, 135, 175, 215, 255]
            let value = index - 16
            return Color(
                red: Double(levels[value / 36]) / 255,
                green: Double(levels[(value / 6) % 6]) / 255,
                blue: Double(levels[value % 6]) / 255
            )

        case .indexed(let index) where (232...255).contains(index):
            let channel = Double(8 + (index - 232) * 10) / 255
            return Color(red: channel, green: channel, blue: channel)

        case .indexed:
            return .white

        case .rgb(let red, let green, let blue):
            return Color(
                red: Double(Swift.min(Swift.max(red, 0), 255)) / 255,
                green: Double(Swift.min(Swift.max(green, 0), 255)) / 255,
                blue: Double(Swift.min(Swift.max(blue, 0), 255)) / 255
            )
        }
    }
}

struct ANSILogSegment: Equatable {
    var text: String
    var foreground: ANSILogColor?
}

enum ANSILogRenderer {
    static func attributedString(from source: String) -> AttributedString {
        segments(from: source).reduce(into: AttributedString()) { result, segment in
            var text = AttributedString(segment.text)
            if let foreground = segment.foreground {
                text.foregroundColor = foreground.swiftUIColor
            }
            result += text
        }
    }

    static func segments(from source: String) -> [ANSILogSegment] {
        var result: [ANSILogSegment] = []
        var text = ""
        var foreground: ANSILogColor?
        var index = source.startIndex

        func appendText() {
            guard !text.isEmpty else { return }
            if let lastIndex = result.indices.last, result[lastIndex].foreground == foreground {
                result[lastIndex].text += text
            } else {
                result.append(ANSILogSegment(text: text, foreground: foreground))
            }
            text = ""
        }

        while index < source.endIndex {
            guard source[index] == "\u{001B}" else {
                text.append(source[index])
                index = source.index(after: index)
                continue
            }

            let afterEscape = source.index(after: index)
            guard afterEscape < source.endIndex, source[afterEscape] == "[" else {
                text.append(source[index])
                index = afterEscape
                continue
            }

            var end = source.index(after: afterEscape)
            while end < source.endIndex, !isCSIFinalByte(source[end]) {
                end = source.index(after: end)
            }
            guard end < source.endIndex else {
                text.append(source[index])
                index = afterEscape
                continue
            }

            appendText()
            if source[end] == "m" {
                applySGR(String(source[source.index(after: afterEscape)..<end]), foreground: &foreground)
            }
            // Unsupported ANSI controls (cursor movement, title changes, etc.)
            // are deliberately discarded rather than rendered as gibberish.
            index = source.index(after: end)
        }
        appendText()
        return result
    }

    private static func isCSIFinalByte(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.only else { return false }
        return (0x40...0x7E).contains(scalar.value)
    }

    private static func applySGR(_ parameterString: String, foreground: inout ANSILogColor?) {
        let parameters: [Int]
        if parameterString.isEmpty {
            parameters = [0]
        } else {
            let fields = parameterString.split(separator: ";", omittingEmptySubsequences: false)
            parameters = fields.map { Int($0) ?? 0 }
        }

        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]
            switch parameter {
            case 0, 39:
                foreground = nil
            case 30...37:
                foreground = .standard(parameter - 30)
            case 90...97:
                foreground = .standard(parameter - 90 + 8)
            case 38 where index + 2 < parameters.count && parameters[index + 1] == 5:
                foreground = .indexed(parameters[index + 2])
                index += 2
            case 38 where index + 4 < parameters.count && parameters[index + 1] == 2:
                foreground = .rgb(parameters[index + 2], parameters[index + 3], parameters[index + 4])
                index += 4
            default:
                break
            }
            index += 1
        }
    }
}

private extension Collection where Element == Unicode.Scalar {
    var only: Unicode.Scalar? {
        count == 1 ? first : nil
    }
}
