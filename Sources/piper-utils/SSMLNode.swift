//
//  SSMLNode.swift
//  piper-objc
//
//  Created by Ihor Shevchuk on 2026-03-08.
//

import Foundation

public enum SSMLNodeKind {
    case text
    case pause
    case phoneme
}

public struct SSMLNode {
    public let text: String
    /// Rate as parsed. For legacy nodes this is an AV-style rate where
    /// 0.5 is normal (VoiceOver ssmlRepresentation) or a percent/float
    /// multiplier that Piper.getOptions interprets via its dual path.
    /// For named-rate nodes (`usesMultiplierPath` true) this is a rate
    /// multiplier (1.0 normal, <1 slower, >1 faster) that getOptions
    /// converts as 1/rate, bypassing the AV curve. See Piper.getOptions.
    public let lengthScale: Float
    public let ssmlRange: NSRange
    public let kind: SSMLNodeKind
    /// Pause duration in milliseconds. Only meaningful when kind == .pause.
    public let pauseMs: Int
    /// Post-synthesis gain, 1.0 is unchanged. Only SSML-lite prosody
    /// volume sets this; legacy nodes are always 1.0.
    public let volume: Float
    /// IPA / espeak phoneme string for kind == .phoneme. Not injected
    /// into libpiper in v1 - Piper synthesizes `text` (the fallback)
    /// instead. See SSMLParser for the reason.
    public let phonemes: String?
    /// True when lengthScale is a rate multiplier from an SSML-lite
    /// named rate (x-slow..x-fast, piper-objc's existing keyword values).
    /// False for the legacy AV/percent path.
    public let usesMultiplierPath: Bool
    /// Emphasis rate factor (1.0 = none, 0.85 = strong, 0.95 = moderate,
    /// 1.10 = reduced). Piper.getOptions divides length_scale by this.
    public let emphasisFactor: Float

    public init(text: String, lengthScale: Float,
                ssmlRange: NSRange = NSRange(location: 0, length: 0)) {
        self.init(text: text, lengthScale: lengthScale, ssmlRange: ssmlRange,
                  kind: .text, pauseMs: 0, volume: 1.0, phonemes: nil,
                  usesMultiplierPath: false, emphasisFactor: 1.0)
    }

    public init(text: String, lengthScale: Float, ssmlRange: NSRange,
                kind: SSMLNodeKind, pauseMs: Int, volume: Float,
                phonemes: String?, usesMultiplierPath: Bool,
                emphasisFactor: Float) {
        self.text = text
        self.lengthScale = lengthScale
        self.ssmlRange = ssmlRange
        self.kind = kind
        self.pauseMs = pauseMs
        self.volume = volume
        self.phonemes = phonemes
        self.usesMultiplierPath = usesMultiplierPath
        self.emphasisFactor = emphasisFactor
    }

    public static func pause(milliseconds: Int) -> SSMLNode {
        SSMLNode(text: "", lengthScale: 1.0,
                 ssmlRange: NSRange(location: 0, length: 0),
                 kind: .pause, pauseMs: milliseconds, volume: 1.0,
                 phonemes: nil, usesMultiplierPath: false, emphasisFactor: 1.0)
    }
}
