import AppKit
import CoreText
import SwiftUI

// MARK: - Manrope

/// Registers the bundled Manrope static-weight fonts (extracted from the
/// variable font used in the design mockup) so `Font.manrope` resolves.
/// Must run once, before any view renders — called from
/// `AppDelegate.applicationDidFinishLaunching`.
enum FontLoader {
    /// Only the weights the interface actually sets. ExtraLight, Light
    /// and ExtraBold were registered and shipped in the bundle without a
    /// single call site between them.
    private static let weights = ["Regular", "Medium", "SemiBold", "Bold"]

    static func registerManrope() {
        for weight in weights {
            let name = "Manrope-\(weight)"
            // Packaged .app: files live under Contents/Resources/Fonts —
            // Bundle.main resolves that correctly. SwiftPM's Bundle.module
            // accessor instead looks for a `Chirp_Chirp.bundle` at the
            // app's top level, which trips codesign's resource sealing, so
            // the shipped app doesn't use it. `swift run` during
            // development has no such Resources folder, so it falls back
            // to Bundle.module there.
            let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }
}

enum ManropeWeight {
    case regular, medium, semibold, bold

    fileprivate var postScriptName: String {
        switch self {
        case .regular: return "Manrope-Regular"
        case .medium: return "Manrope-Medium"
        case .semibold: return "Manrope-SemiBold"
        case .bold: return "Manrope-Bold"
        }
    }
}

extension Font {
    /// Manrope at the given size/weight. Falls back to the system font
    /// automatically if registration ever fails — `Font.custom` degrades
    /// gracefully rather than crashing on a missing PostScript name.
    ///
    /// Manrope carries the interface: rows, labels, controls, body copy.
    /// Page and section titles use `chirpDisplay` instead — see there.
    static func manrope(_ size: CGFloat, _ weight: ManropeWeight = .regular) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    /// Titles, in New York — Apple's system serif, reached through
    /// `design: .serif` rather than by name so it resolves on any macOS
    /// without anything to bundle or license.
    ///
    /// A serif for titles against Manrope for everything else is the
    /// whole typographic idea here: the app should read warm and
    /// human-made rather than like another all-sans AI product. New York
    /// specifically because it's a *modern* humanist serif — drawn for
    /// screens, at text sizes, by people solving this exact problem —
    /// so it stays crisp at 15pt section heads instead of going
    /// bookish and fussy the way a print face would.
    static func chirpDisplay(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Palette (Chirp: cream/ink/cobalt-blue, sampled from the wren pet)

/// The app's colours.
///
/// Every value is a plain, fixed `Color`. There used to be a
/// `dynamic(light:dark:)` helper here that took a pair and unconditionally
/// returned the light one — dark mode was removed (`NSApp.appearance` is
/// pinned to aqua at launch), so ~30 dark values sat in this file being
/// passed to a function that threw them away. The duplicate aliases that
/// grew alongside it are gone too: `sunset`/`sunsetDeep` and
/// `sunsetPale`/`sunsetSoft` were the same literal under two names, and
/// three separate tokens all resolved to the one paper cream.
enum Palette {
    // MARK: Ground

    /// The single paper ground: titlebar, rail and page, one continuous
    /// surface with nothing floating on anything.
    static let paper = Color(red: 0.969, green: 0.957, blue: 0.933)
    /// Card fill — a warm off-white, not pure white. Pure white against
    /// the paper reads as a cold hole punched in it; pulling the fill a
    /// few points toward the paper's own hue keeps a card reading as a
    /// raised sheet of the same stock.
    static let surface = Color(red: 0.996, green: 0.992, blue: 0.984)
    static let shell = Color(red: 0.965, green: 0.954, blue: 0.930)
    static let panel = Color(red: 0.988, green: 0.980, blue: 0.960)
    static let card = Color(red: 0.945, green: 0.932, blue: 0.898)
    static let cardHover = Color(red: 0.905, green: 0.888, blue: 0.845)

    // MARK: Ink — warm charcoal, never pure black

    static let ink = Color(red: 0.145, green: 0.138, blue: 0.126)
    static let inkSoft = Color(red: 0.416, green: 0.416, blue: 0.424)
    static let inkFaint = Color(red: 0.604, green: 0.620, blue: 0.608)
    static let onInk = Color.white
    static let warmInk = Color(red: 0.145, green: 0.138, blue: 0.126)
    static let warmInkSoft = Color(red: 0.416, green: 0.404, blue: 0.373)
    static let warmInkFaint = Color(red: 0.573, green: 0.561, blue: 0.529)
    static let warmInkFainter = Color(red: 0.663, green: 0.651, blue: 0.616)

    // MARK: Lines

    static let border = Color(red: 0.882, green: 0.865, blue: 0.822)
    static let warmDivider = Color(red: 0.878, green: 0.861, blue: 0.816)
    static let warmRowBorder = Color(red: 0.941, green: 0.930, blue: 0.898)
    /// Translucent rather than a fixed near-white, so it keeps working
    /// whatever it happens to sit on.
    static let glassDivider = Color.black.opacity(0.08)

    // MARK: Accent — cobalt, from the fairy-wren's own breeding plumage

    static let accent = Color(red: 0.769, green: 0.851, blue: 0.965)
    static let accentInk = Color.black
    static let accentText = Color(red: 0.145, green: 0.322, blue: 0.663)
    static let accentSoft = Color(red: 0.373, green: 0.545, blue: 0.898, opacity: 0.22)
    /// The same cobalt as `accentText`, kept under its own name because
    /// the warm-palette pages address it as a fill rather than as text.
    static let sunsetDeep = Color(red: 0.145, green: 0.322, blue: 0.663)
    static let sunsetSoft = Color(red: 0.373, green: 0.545, blue: 0.898, opacity: 0.22)

    static let danger = Color(red: 0.678, green: 0.235, blue: 0.165)
    /// The one near-black in the app: a solid pill for primary actions.
    static let navActivePill = Color(red: 0.086, green: 0.086, blue: 0.082)
}

// MARK: - Radii & motion

/// Tightened across the board — the old 20/28 on full-width cards is
/// what gave the app its soft, bubbly, slightly toy-like feel. Smaller
/// radii read as more precise and more modern at these sizes, and stop
/// large surfaces from looking like lozenges.
enum Radius {
    static let sm: CGFloat = 7
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
}

extension Animation {
    /// Matches the mockup's cubic-bezier(0.4, 0, 0.2, 1) easing.
    static func chirpEase(_ duration: Double = 0.2) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: duration)
    }
}
