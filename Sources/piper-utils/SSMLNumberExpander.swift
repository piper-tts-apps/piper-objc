//
//  SSMLNumberExpander.swift
//  piper-objc
//
//  SSML-lite number, date, and time expansion, ported from the Python
//  prototype in workspace/ssml-lite (ssml_lite.py). English-first.
//  Unparseable input is returned unchanged, so a bad <say-as> never
//  silences a word - it just falls back to the original text.
//

import Foundation

public enum SSMLNumberExpander {

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety",
    ]
    private static let ordinals: [String: String] = [
        "one": "first", "two": "second", "three": "third", "five": "fifth",
        "eight": "eighth", "nine": "ninth", "twelve": "twelfth",
        "twenty": "twentieth", "thirty": "thirtieth", "forty": "fortieth",
        "fifty": "fiftieth", "sixty": "sixtieth", "seventy": "seventieth",
        "eighty": "eightieth", "ninety": "ninetieth",
    ]
    private static let months = [
        "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December",
    ]

    public static func cardinal(_ n: Int) -> String? {
        guard n >= 0, n <= 999_999_999 else { return nil }
        if n < 20 { return ones[n] }
        if n < 100 {
            let (t, o) = (n / 10, n % 10)
            return o == 0 ? tens[t] : "\(tens[t]) \(ones[o])"
        }
        if n < 1000 {
            let (h, r) = (n / 100, n % 100)
            return r == 0 ? "\(ones[h]) hundred" : "\(ones[h]) hundred \(cardinal(r)!)"
        }
        if n < 1_000_000 {
            let (t, r) = (n / 1000, n % 1000)
            return r == 0 ? "\(cardinal(t)!) thousand" : "\(cardinal(t)!) thousand \(cardinal(r)!)"
        }
        let (m, r) = (n / 1_000_000, n % 1_000_000)
        return r == 0 ? "\(cardinal(m)!) million" : "\(cardinal(m)!) million \(cardinal(r)!)"
    }

    public static func ordinal(_ n: Int) -> String? {
        guard var words = cardinal(n)?.split(separator: " ").map(String.init),
              !words.isEmpty else { return nil }
        let last = words[words.count - 1]
        if let mapped = ordinals[last] {
            words[words.count - 1] = mapped
        } else if last.hasSuffix("y") {
            words[words.count - 1] = String(last.dropLast()) + "ieth"
        } else {
            words[words.count - 1] = last + "th"
        }
        return words.joined(separator: " ")
    }

    public static func digits(_ text: String) -> String {
        text.filter { $0.isNumber }.map { ones[Int(String($0))!] }.joined(separator: " ")
    }

    public static func year(_ year: Int) -> String? {
        guard year >= 1000, year <= 9999 else { return cardinal(year) }
        if year % 100 == 0 { return "\(cardinal(year / 100)!) hundred" }
        let (first, second) = (year / 100, year % 100)
        let secondWord = second < 10 ? "oh \(ones[second])" : cardinal(second)!
        return "\(cardinal(first)!) \(secondWord)"
    }

    public static func expandDate(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        // YYYY-MM-DD
        if let m = match(t, pattern: #"^(\d{4})-(\d{1,2})-(\d{1,2})$"#),
           let year = Int(m[0]), let month = Int(m[1]), let day = Int(m[2]) {
            return dateWords(year: year, month: month, day: day)
        }
        // MM/DD/YYYY (US order, matching the prototype)
        if let m = match(t, pattern: #"^(\d{1,2})/(\d{1,2})/(\d{4})$"#),
           let month = Int(m[0]), let day = Int(m[1]), let year = Int(m[2]) {
            return dateWords(year: year, month: month, day: day)
        }
        return nil
    }

    private static func dateWords(year yr: Int, month: Int, day: Int) -> String? {
        guard (1...12).contains(month), (1...31).contains(day),
              (1000...9999).contains(yr),
              let dayWord = ordinal(day), let yearWord = year(yr) else { return nil }
        return "\(months[month - 1]) \(dayWord), \(yearWord)"
    }

    public static func expandTime(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let m = match(t, pattern: #"^(\d{1,2}):(\d{2})(?::\d{2})?\s*([AaPp][Mm])?$"#),
              let hour = Int(m[0]), let minute = Int(m[1]) else { return nil }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        var out: String
        if minute == 0 {
            out = "\(cardinal(hour12)!) o'clock"
        } else if minute < 10 {
            out = "\(cardinal(hour12)!) oh \(ones[minute])"
        } else {
            out = "\(cardinal(hour12)!) \(cardinal(minute)!)"
        }
        if m.count > 2, !m[2].isEmpty {
            out += " " + m[2].uppercased().map { String($0) }.joined(separator: " ")
        }
        return out
    }

    public static func expandSayAs(_ text: String, interpretAs: String?) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch (interpretAs ?? "").lowercased() {
        case "characters":
            return t.filter { !$0.isWhitespace }.map { String($0) }.joined(separator: " ")
        case "digits", "telephone":
            // Drop separators; keep a trailing "ext 123" / "x123" as words.
            var body = t
            var ext = ""
            if let range = body.range(of: #"\b(?:ext\.?|x)\s*(\d+)\s*$"#, options: .regularExpression) {
                let extDigits = body[range].filter { $0.isNumber }
                ext = " extension " + digits(String(extDigits))
                body = String(body[..<range.lowerBound])
            }
            return digits(body) + ext
        case "cardinal":
            if let n = Int(t.replacingOccurrences(of: ",", with: "")),
               let word = cardinal(n) { return word }
            return t
        case "ordinal":
            let cleaned = t.replacingOccurrences(of: ",", with: "")
            let numberPart = cleaned.replacingOccurrences(
                of: "(st|nd|rd|th)$", with: "", options: .regularExpression)
            if let n = Int(numberPart), let word = ordinal(n) { return word }
            return t
        case "date":
            return expandDate(t) ?? t
        case "time":
            return expandTime(t) ?? t
        default:
            return t
        }
    }

    // MARK: - Helpers

    /// Returns capture groups (excluding the full match) or nil.
    private static func match(_ text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        var groups: [String] = []
        for i in 1..<result.numberOfRanges {
            let range = result.range(at: i)
            if range.location == NSNotFound {
                groups.append("")
            } else if let swiftRange = Range(range, in: text) {
                groups.append(String(text[swiftRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
