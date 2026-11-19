import Foundation

/// Pairs XMLParser's element callbacks with the original character-data spans.
/// XMLParser remains responsible for validation, decoding, and synthesis text.
final class XMLSourceCursor {
    // Comments, processing instructions and quoted '>' must not expose tag
    // contents as speech. CDATA is delivered to a separate XMLParser callback,
    // which this provider does not synthesize.
    private static let markup = try! NSRegularExpression(pattern: #"""
        <!-- .*? --> | <\? .*? \?> | <!\[CDATA\[ .*? \]\]>
        | <!DOCTYPE \s+ (?: [^>"'\[] | "[^"]*" | '[^']*'
            | \[ (?: <!-- .*? --> | <\? .*? \?> | "[^"]*" | '[^']*' | [^\]"'] )*? \] )* >
        | < (?: [^<>"'] | "[^"]*" | '[^']*' )+ >
        """#, options: [.allowCommentsAndWhitespace, .dotMatchesLineSeparators])

    private let raw: NSString
    private let markup: [NSTextCheckingResult]
    private var tagIndex = 0
    private var previousEnd = 0
    private var pendingEnd: String?

    init(_ xml: String) {
        raw = xml as NSString
        markup = Self.markup.matches(in: xml, range: NSRange(location: 0, length: raw.length))
    }

    func beforeElement(_ name: String, closing: Bool, text: String) -> XMLTextSourceMap? {
        if let pendingEnd {
            self.pendingEnd = nil
            if !closing || name != pendingEnd { tagIndex = markup.count }
            return nil
        }

        var spans: [NSRange] = []
        while tagIndex < markup.count {
            let tag = markup[tagIndex].range
            tagIndex += 1
            if !text.isEmpty, previousEnd < tag.location {
                spans.append(NSRange(location: previousEnd, length: tag.location - previousEnd))
            }
            previousEnd = NSMaxRange(tag)
            let kind = raw.character(at: tag.location + 1)
            if kind == 0x21 || kind == 0x3F { continue }  // <! ... or <? ...
            let isEnd = kind == 0x2F
            let begin = tag.location + (isEnd ? 2 : 1)
            let nameRange = NSRange(location: begin, length: name.utf16.count)
            let afterName = NSMaxRange(nameRange)
            guard isEnd == closing, afterName < previousEnd,
                  raw.compare(name, options: .literal, range: nameRange) == .orderedSame,
                  [9, 10, 13, 32, 47, 62].contains(raw.character(at: afterName)) else {
                tagIndex = markup.count
                return nil
            }
            if !isEnd, raw.character(at: previousEnd - 2) == 0x2F { pendingEnd = name }
            guard !text.isEmpty else { return nil }
            return XMLTextSourceMap(raw: raw, spans: spans, matching: text)
        }
        return nil
    }
}

/// A long ordinary paragraph occupies one run. Escapes need only one extra
/// run each, even when a numeric reference represents two UTF-16 units.
struct XMLTextSourceMap {
    private struct Run {
        var decoded: NSRange
        var source: NSRange
    }
    private static let escapes = try! NSRegularExpression(pattern: #"&([^;<&\s]+);|\r\n?"#)
    private static let entities = ["amp": "&", "apos": "'", "lt": "<", "gt": ">", "quot": "\""]


    private var length = 0
    private var runs: [Run] = []

    fileprivate init?(raw: NSString, spans: [NSRange], matching text: String) {
        let expected = text as NSString
        for span in spans {
            let part = raw.substring(with: span) as NSString
            let partRange = NSRange(location: 0, length: part.length)
            var end = 0
            for match in Self.escapes.matches(in: part as String, range: partRange) {
                let literal = NSRange(location: end, length: match.range.location - end)
                guard append(part.substring(with: literal), at: NSRange(location: span.location + end, length: literal.length),
                             matching: expected) else { return nil }
                let name = match.range(at: 1)
                let value: String
                if name.location == NSNotFound {
                    value = "\n"  // XML line-end normalization
                } else if let replacement = Self.decode(part.substring(with: name)) {
                    value = replacement
                } else {
                    return nil
                }
                guard append(value, at: NSRange(location: span.location + match.range.location, length: match.range.length),
                             matching: expected) else { return nil }
                end = NSMaxRange(match.range)
            }
            let tail = NSRange(location: end, length: part.length - end)
            guard append(part.substring(with: tail), at: NSRange(location: span.location + end, length: tail.length),
                         matching: expected) else { return nil }
        }
        guard length > 0, length == expected.length else { return nil }
    }

    private static func decode(_ name: String) -> String? {
        if let value = entities[name] { return value }
        guard name.hasPrefix("#") else { return nil }
        let hex = name.hasPrefix("#x")
        guard let number = UInt32(name.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
              let scalar = UnicodeScalar(number) else { return nil }
        return String(scalar)
    }

    private mutating func append(_ value: String, at source: NSRange, matching expected: NSString) -> Bool {
        let count = value.utf16.count
        guard count > 0 else { return true }
        let span = NSRange(location: length, length: count)
        guard count <= expected.length - length,
              expected.compare(value, options: .literal, range: span) == .orderedSame else { return false }
        if let last = runs.last, count == source.length,
           last.decoded.length == last.source.length, NSMaxRange(last.source) == source.location {
            runs[runs.count - 1].decoded.length += count
            runs[runs.count - 1].source.length += source.length
        } else {
            runs.append(Run(decoded: span, source: source))
        }
        length += count
        return true
    }

    func sourceRange(for span: NSRange) -> NSRange? {
        guard span.location >= 0, span.location < length,
              span.length > 0, span.length <= length - span.location else { return nil }
        let first = run(at: span.location)
        let last = run(at: NSMaxRange(span) - 1)
        let start = first.decoded.length == first.source.length
            ? first.source.location + span.location - first.decoded.location : first.source.location
        let end = last.decoded.length == last.source.length
            ? last.source.location + NSMaxRange(span) - last.decoded.location : NSMaxRange(last.source)
        return NSRange(location: start, length: end - start)
    }

    private func run(at offset: Int) -> Run {
        var low = 0
        var high = runs.count - 1
        while low < high {
            let middle = low + (high - low) / 2
            if offset < NSMaxRange(runs[middle].decoded) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return runs[low]
    }
}
