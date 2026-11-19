//
//  SSMLNode.swift
//  piper-objc
//
//  Created by Ihor Shevchuk on 2026-03-08.
//
import Foundation

public struct SSMLNode {
    public let text: String
    public let lengthScale: Float
    public let ssmlRange: NSRange
    fileprivate let decoded: NSString
    private let index: XMLTextSourceMap?
    private static let nonWhitespace = CharacterSet.whitespacesAndNewlines.inverted

    public init(text: String, lengthScale: Float, ssmlRange: NSRange = NSRange(location: 0, length: 0)) {
        self.text = text
        self.lengthScale = lengthScale
        self.ssmlRange = ssmlRange
        self.decoded = text as NSString
        self.index = nil
    }

    init(decoded: String, lengthScale: Float, index: XMLTextSourceMap?) {
        self.text = decoded.precomposedStringWithCanonicalMapping
        self.decoded = decoded as NSString
        self.lengthScale = lengthScale
        self.index = index
        self.ssmlRange = index?.sourceRange(for: NSRange(location: 0, length: decoded.utf16.count))
            ?? NSRange(location: NSNotFound, length: 0)
    }

    fileprivate func project(_ range: NSRange) -> NSRange? {
        guard ssmlRange.location >= 0, ssmlRange.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= decoded.length, range.length <= decoded.length - range.location else { return nil }
        if let index {
            return index.sourceRange(for: range)
        }
        guard NSMaxRange(range) <= ssmlRange.length, NSMaxRange(range) <= Int.max - ssmlRange.location else { return nil }
        return NSRange(location: ssmlRange.location + range.location, length: range.length)
    }

    /// Locate each extracted chunk once, in order. The extractor can collapse
    /// whitespace, and speech uses NFC while the request can be decomposed.
    public func locateChunk(_ chunk: String, from cursor: inout Int) -> SSMLChunk? {
        guard ssmlRange.location != NSNotFound, let start = nextText(at: cursor) else { return nil }
        let rest = NSRange(location: start, length: decoded.length - start)
        let exact = decoded.range(of: chunk, options: [.anchored, .literal], range: rest)
        let span: NSRange
        if exact.location != NSNotFound {
            span = exact
        } else {
            var end = start
            for token in chunk.split(whereSeparator: \.isWhitespace) {
                guard let next = nextText(at: end) else {
                    cursor = NSNotFound
                    return nil
                }
                let remaining = NSRange(location: next, length: decoded.length - next)
                let matched = decoded.range(of: String(token), options: .anchored, range: remaining)
                guard matched.location != NSNotFound else {
                    cursor = NSNotFound
                    return nil
                }
                end = NSMaxRange(matched)
            }
            span = NSRange(location: start, length: end - start)
        }
        guard let source = project(span) else { return nil }
        cursor = NSMaxRange(span)
        return SSMLChunk(node: self, text: chunk as NSString, decodedRange: span,
                         sourceRange: source, exact: exact.location != NSNotFound)
    }

    private func nextText(at position: Int) -> Int? {
        guard position >= 0, position < decoded.length else { return nil }
        let rest = NSRange(location: position, length: decoded.length - position)
        let location = decoded.rangeOfCharacter(from: Self.nonWhitespace,
                                               options: [], range: rest).location
        return location == NSNotFound ? nil : location
    }
}

/// Maps ordered word markers for one chunk into the original request.
public struct SSMLChunk {
    public let sourceRange: NSRange
    private let node: SSMLNode
    private let text: NSString
    private let decodedRange: NSRange
    private let exact: Bool
    private var nextWord: Int

    fileprivate init(node: SSMLNode, text: NSString, decodedRange: NSRange, sourceRange: NSRange, exact: Bool) {
        self.node = node
        self.text = text
        self.decodedRange = decodedRange
        self.sourceRange = sourceRange
        self.exact = exact
        self.nextWord = decodedRange.location
    }

    public mutating func wordRange(for local: NSRange) -> NSRange? {
        guard local.location >= 0, local.location < text.length, local.length > 0,
              local.length <= text.length - local.location else { return nil }
        if exact {
            return node.project(NSRange(location: decodedRange.location + local.location, length: local.length))
        }
        let rest = NSRange(location: nextWord, length: NSMaxRange(decodedRange) - nextWord)
        let match = node.decoded.range(of: text.substring(with: local), options: [], range: rest)
        guard match.location != NSNotFound else { return nil }
        nextWord = NSMaxRange(match)
        return node.project(match)
    }
}
