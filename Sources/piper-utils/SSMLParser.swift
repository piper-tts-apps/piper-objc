//
//  SSMLParser.swift
//  piper-objc
//
//  Created by Ihor Shevchuk on 2026-03-08.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public final class SSMLParser: NSObject {
    
    // MARK: - Context
    
    private struct SSMLContext {
        var text: String
        var rate: Float
    }
    
    // MARK: - State
    
    private var stack: [SSMLContext] = []
    private var onNode: ((SSMLNode) -> Void)?
    private var sourceCursor: XMLSourceCursor?
    
    // MARK: - Public API
    
    public func parse(ssml: String, onNode: @escaping (SSMLNode) -> Void) {
        self.onNode = onNode
        defer {
            self.onNode = nil
            self.sourceCursor = nil
        }
        
        guard !ssml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = ssml.data(using: .utf8) else {
            return
        }
        
        sourceCursor = XMLSourceCursor(ssml)
        
        stack = [
            SSMLContext(text: "", rate: 0.5)
        ]
        
        let parser = XMLParser(data: data)
        parser.delegate = self
        
        if !parser.parse() {
            // If parsing fails, treat the whole string as a single text node if it's not just tags.
            if !ssml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onNode(SSMLNode(text: ssml, lengthScale: 1.0, ssmlRange: NSRange(location: 0, length: ssml.utf16.count)))
            }
            return
        }

        flushCurrentText()
    }
}

// MARK: - XMLParserDelegate

extension SSMLParser: XMLParserDelegate {
    
    public func parser(_ parser: XMLParser,
                       didStartElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?,
                       attributes attributeDict: [String : String] = [:]) {
        
        flushCurrentText(before: qName ?? elementName, closing: false)

        let parent = stack.last ?? SSMLContext(text: "", rate: 0.5)
        
        var newContext = SSMLContext(
            text: "",
            rate: parent.rate
        )
        
        if elementName == "prosody",
           let rateStr = attributeDict["rate"] {
            newContext.rate = parseRate(rateStr)
        }
        stack.append(newContext)
    }
    
    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }
    
    public func parser(_ parser: XMLParser,
                       didEndElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?) {
        
        flushCurrentText(before: qName ?? elementName, closing: true)
        
        if stack.count > 1 {
            stack.removeLast()
        }
    }
}

// MARK: - Helpers

private extension SSMLParser {
    
    func flushCurrentText(before element: String? = nil, closing: Bool = false) {
        guard !stack.isEmpty else { return }
        
        let context = stack[stack.count - 1]
        stack[stack.count - 1].text = ""
        let index = element.flatMap { sourceCursor?.beforeElement($0, closing: closing, text: context.text) }
        guard !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let node = SSMLNode(decoded: context.text, lengthScale: context.rate, index: index)
        onNode?(node)
    }
    
    func parseRate(_ value: String) -> Float {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%") {
            let rateStr = trimmed.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let rate = Double(rateStr) {
                return Float(rate / 100.0)
            }
        } else {
            // Handle float multiplier like "1.0", "0.5", "2.0", "1"
            if let rate = Float(trimmed) {
                return rate
            }
            // Handle keywords – map to multiplier approximating Apple normal 0.5
            // For fast follow-up, unknown -> 0.5 (AV normal) which maps to length 1.0
            let lower = trimmed.lowercased()
            switch lower {
            case "x-slow": return 0.5  // slow multiplier
            case "slow": return 0.75
            case "medium": return 1.0
            case "fast": return 1.5
            case "x-fast": return 2.0
            default: break
            }
        }
        return 0.5
    }
}
