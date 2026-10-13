import AppKit
import CoreText
import SwiftUI

/// Colors, fonts and paragraph metrics of the writing surface.
enum Theme {
    // MARK: Colors

    static let background = dynamic(light: rgb(0xF7F7F5), dark: rgb(0x1A1A1A))
    static let sidebarBackground = dynamic(light: rgb(0xECECEA), dark: rgb(0x232323))
    static let fileListBackground = dynamic(light: rgb(0xF2F2F0), dark: rgb(0x1F1F1F))
    static let text = dynamic(light: rgb(0x1E1E1E), dark: rgb(0xD2D2D2))
    static let marker = dynamic(light: rgb(0xB4B4B0), dark: rgb(0x5E5E5E))
    static let secondary = dynamic(light: rgb(0x7A7A76), dark: rgb(0x8C8C8C))
    static let dimmed = dynamic(light: rgb(0xC8C8C4), dark: rgb(0x4A4A4A))
    static let caret = rgb(0x19A6F2)
    static let selection = dynamic(light: rgb(0xC6E6FB), dark: rgb(0x1D4964))
    static let link = dynamic(light: rgb(0x2E83C4), dark: rgb(0x58A9E6))
    static let chrome = dynamic(light: rgb(0x9A9A96), dark: rgb(0x767676))

    static func highlight(_ color: HighlightColor) -> NSColor {
        switch color {
        case .yellow: dynamic(light: rgb(0xFFF09A), dark: rgb(0x6B5F12))
        case .orange: dynamic(light: rgb(0xFFD3A1), dark: rgb(0x6E4316))
        case .pink: dynamic(light: rgb(0xFFC9DE), dark: rgb(0x6B2843))
        case .purple: dynamic(light: rgb(0xE2CCFF), dark: rgb(0x4A2E6E))
        case .blue: dynamic(light: rgb(0xC4E3FF), dark: rgb(0x1E4569))
        case .green: dynamic(light: rgb(0xC9F2C2), dark: rgb(0x2A5A27))
        }
    }

    /// Syntax Highlight colors: adjectives brown, nouns red, adverbs purple, verbs blue, conjunctions green.
    static func partOfSpeech(_ part: PartOfSpeech) -> NSColor {
        switch part {
        case .adjectives: dynamic(light: rgb(0xA1652E), dark: rgb(0xD39A5E))
        case .nouns: dynamic(light: rgb(0xD0383E), dark: rgb(0xF0686C))
        case .adverbs: dynamic(light: rgb(0x9A3FC4), dark: rgb(0xC07EE6))
        case .verbs: dynamic(light: rgb(0x1E7FD0), dark: rgb(0x5AACF0))
        case .conjunctions: dynamic(light: rgb(0x2E9A4B), dark: rgb(0x5CC97A))
        }
    }

    static let styleCheckStrike = dynamic(light: rgb(0x8C8C88), dark: rgb(0x9A9A9A))

    /// Hues an AI-attributed run of text cycles through, giving it a soft gradient.
    static func aiGradient(at fraction: CGFloat) -> NSColor {
        let hue = 0.55 + 0.35 * fraction
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hue: hue.truncatingRemainder(dividingBy: 1), saturation: dark ? 0.45 : 0.65,
                           brightness: dark ? 0.95 : 0.72, alpha: 1)
        }
    }

    // MARK: Fonts

    /// Plex fonts ship with the app; iA's own fonts are used instead when the user has installed them.
    static func registerBundledFonts() {
        guard let directory = resourceURL("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let fonts = files.filter { $0.pathExtension == "ttf" } as CFArray
        CTFontManagerRegisterFontURLs(fonts, .process, true, nil)
    }

    /// Resources live in the app bundle, or next to the sources when run from `swift run`.
    static func resourceURL(_ name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../Resources/\(name)").standardizedFileURL,
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static let familyNames: [Typeface: [String]] = [
        .mono: ["iA Writer Mono S", "iA Writer Mono V", "IBM Plex Mono"],
        .duo: ["iA Writer Duo S", "iA Writer Duo V", "IBM Plex Mono"],
        .quattro: ["iA Writer Quattro S", "iA Writer Quattro V", "IBM Plex Sans"],
    ]

    static func font(_ typeface: Typeface, size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        for family in familyNames[typeface] ?? [] {
            if let font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size) {
                return font
            }
        }
        let fallback = NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        return italic ? NSFontManager.shared.convert(fallback, toHaveTrait: .italicFontMask) : fallback
    }

    static func codeFont(size: CGFloat) -> NSFont {
        font(.mono, size: size)
    }

    /// Width of one character of the monospaced face, the unit for line length and gutters.
    static func characterWidth(size: CGFloat) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font(.mono, size: size)]).width
    }

    static func lineHeight(size: CGFloat) -> CGFloat {
        (size * 1.6).rounded()
    }

    // MARK: Helpers

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension Color {
    static let editorBackground = Color(nsColor: Theme.background)
    static let sidebarBackground = Color(nsColor: Theme.sidebarBackground)
    static let fileListBackground = Color(nsColor: Theme.fileListBackground)
    static let chrome = Color(nsColor: Theme.chrome)
    static let accentBlue = Color(nsColor: Theme.caret)
}
