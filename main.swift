// Pullcord — flip any Spotlight panel on from anywhere.
//
// Pullcord gives every Spotlight panel its own keyboard shortcut.
//
// macOS 26 gave Spotlight four panels — Apps ⌘1, Files ⌘2, Actions ⌘3,
// Clipboard ⌘4 — reachable only after opening Spotlight itself. Pullcord lets
// you assign a global shortcut to each panel directly.
//
// How panels open:
//   • Apps      — launches the system stub /System/Applications/Apps.app
//                 (public API, no permissions, works even if ⌘Space is
//                 remapped). Falls back to synthesis if the stub is missing.
//   • Files / Actions / Clipboard — synthesizes ⌘Space then ⌘2/⌘3/⌘4, the
//                 documented gesture. Needs Accessibility to post keystrokes.
//
// A group of "System Utilities" ride alongside the panels, none needing any
// permission: open System Settings (with a smart toggle back); a Color Picker
// (NSColorSampler → clipboard); Capture Text (screencapture -i region → Vision
// OCR → clipboard); Keep Awake (an IOKit power assertion that blocks sleep); and
// Speak Text — which doesn't re-implement speech at all: it mirrors macOS's own
// "Speak selection" (Accessibility → Read & Speak), showing the shortcut that
// feature is assigned, with a Configure… window walking through switching it on.
// Measured, not assumed: the Siri voices worth having are reachable from no
// public speech API, so macOS is the only thing that can read to you in them.
//
// Same construction as Key54 (github.com/grokcodile/key54): one file, no
// dependencies, compiled with swiftc. Runs as a background agent — launching
// it by hand opens Settings.

import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import Vision
import IOKit.pwr_mgt
import CoreGraphics
import UniformTypeIdentifiers
import FoundationModels

// MARK: - Panels

struct Panel {
    let name: String
    let symbol: String            // SF Symbol shown beside the row (fallback)
    let glyphPath: String?        // system template glyph (.icns) to load + tint instead
    let detail: String            // the icon's one-line tooltip
    let spotlightKey: CGKeyCode   // the ⌘N that selects it inside Spotlight
    let defaultsKey: String
}

// Icons mirror the glyphs macOS Spotlight shows for each panel, all
// monochrome. The Applications tools-"A" isn't an SF Symbol, but it ships as
// the Finder-sidebar template glyph in CoreTypes.bundle — loaded from that
// system path at runtime and tinted like the others (falls back to the
// square.grid.2x2 symbol if the path ever moves). The other three are SF
// Symbols: folder, the two-layer Actions stack, and doc.on.doc for Clipboard
// (Spotlight uses the copy glyph, not a clip).
let sidebarApplications = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarApplicationsFolder.icns"
let panels: [Panel] = [
    Panel(name: "Applications", symbol: "square.grid.2x2", glyphPath: sidebarApplications, detail: "Launch anything you've got installed by typing a few letters of its name.", spotlightKey: CGKeyCode(kVK_ANSI_1), defaultsKey: "apps"),
    Panel(name: "Files", symbol: "folder", glyphPath: nil, detail: "Find a document or folder by its name, or by a phrase somewhere inside it.", spotlightKey: CGKeyCode(kVK_ANSI_2), defaultsKey: "files"),
    Panel(name: "Actions", symbol: "square.2.layers.3d", glyphPath: nil, detail: "Run any Shortcut or system action by name — a command palette for your Mac.", spotlightKey: CGKeyCode(kVK_ANSI_3), defaultsKey: "actions"),
    Panel(name: "Clipboard", symbol: "doc.on.doc", glyphPath: nil, detail: "Reach back through what you've copied and paste something from earlier.", spotlightKey: CGKeyCode(kVK_ANSI_4), defaultsKey: "clipboard"),
    Panel(name: "System Settings", symbol: "gear", glyphPath: nil, detail: "Jump to System Settings and, with Smart Toggle, land in its search field — then straight back again.", spotlightKey: 0, defaultsKey: "settings"),
    Panel(name: "Keep Awake", symbol: "mug.fill", glyphPath: nil, detail: "Hold your Mac awake through a long render, a download, or a presentation.", spotlightKey: 0, defaultsKey: "keepawake"),
    Panel(name: "Color Picker", symbol: "eyedropper", glyphPath: nil, detail: "Magnify any pixel on screen and copy its exact color as code.", spotlightKey: 0, defaultsKey: "colorpicker"),
    Panel(name: "Color History", symbol: "paintpalette", glyphPath: nil, detail: "Your last twenty picks, ready to copy again, drag out as a swatch, or pin.", spotlightKey: 0, defaultsKey: "colorhistory"),
    Panel(name: "Capture Text", symbol: "text.viewfinder", glyphPath: nil, detail: "Pull the text off anything on screen — a screenshot, a PDF, a paused video.", spotlightKey: 0, defaultsKey: "textcapture"),
    Panel(name: "Dictate Text", symbol: "waveform.badge.microphone", glyphPath: nil, detail: "Hold a key and speak; let go and what you said is typed where the cursor is.", spotlightKey: 0, defaultsKey: "dictation"),
    Panel(name: "Rewrite Text", symbol: "text.badge.checkmark", glyphPath: nil, detail: "Clean up, restyle, shorten or translate what you've selected, on your Mac.", spotlightKey: 0, defaultsKey: "rewrite"),
    Panel(name: "Speak Text", symbol: "text.bubble", glyphPath: nil, detail: "Have your Mac read the text you've selected out loud, in a Siri voice.", spotlightKey: 0, defaultsKey: "speakclipboard"),
]

/// Panels shown in the "System Utilities" group rather than the "Spotlight" group,
/// and — like Applications — driven without needing Accessibility.
let utilityKeys: Set<String> = ["settings", "colorpicker", "colorhistory", "textcapture", "keepawake", "dictation", "speakclipboard", "rewrite"]
func isUtility(_ panel: Panel) -> Bool { utilityKeys.contains(panel.defaultsKey) }
/// The tools that work on text, grouped apart from the system ones — they read
/// as a set (capture it, speak it, dictate it, tidy it) and it keeps each group
/// to a single row.
let textKeys: Set<String> = ["textcapture", "speakclipboard", "dictation", "rewrite"]
func isTextTool(_ panel: Panel) -> Bool { textKeys.contains(panel.defaultsKey) }
/// Rows of option controls a card shows below its shortcut field: every System
/// Tool has one (a checkbox or select menu); Spotlight panels have none.
func optionRows(_ panel: Panel) -> Int { isUtility(panel) ? 1 : 0 }
/// Panels that work without Accessibility (no keystroke synthesis).
func worksWithoutAX(_ panel: Panel) -> Bool {
    ["apps", "colorpicker", "colorhistory", "textcapture", "keepawake"].contains(panel.defaultsKey)
}
/// Speak Text owns no Pullcord shortcut — it mirrors macOS's built-in "Speak
/// selection" hotkey — so it registers nothing and its card shows a read-only
/// field plus a Configure… button explaining how to switch that feature on.
func mirrorsMacOSHotkey(_ panel: Panel) -> Bool { panel.defaultsKey == "speakclipboard" }
/// Rewrite Text is triggered by double-tapping ⌃ (see `syncRewriteTapMonitor`)
/// rather than a recorded shortcut, so it registers no hotkey and its card
/// reads out the tap instead of offering a field.
func usesTapKey(_ panel: Panel) -> Bool { panel.defaultsKey == "rewrite" }

/// What a fresh install starts with: ⌃⌥⌘ plus a key under your right hand.
///
/// Three modifiers look heavy written down, but the left hand takes them as one
/// shape and never moves, which leaves every trigger key on the right — no chord
/// crosses the keyboard. It's also the one combination nothing else claims: ⌃
/// alone hits the text-editing bindings macOS puts in every field (⌃A, ⌃K, ⌃H),
/// ⌥ alone eats the character it would otherwise type, and ⌘ belongs to whatever
/// app is frontmost.
///
/// Every key earns its place. The four panels run left to right in the order
/// Spotlight numbers them. `/` finds and `\` does — mirrored symbols for paths and
/// for escapes. `,` is the preferences key every Mac app already uses. `'` is
/// quoted text. The rest are initials: Loupe, History, Keep awake, OCR.
///
/// Only ever applied to a tool with no shortcut of its own — see
/// `seedDefaultShortcutsIfNeeded`.
let rightHandChord = UInt32(controlKey | optionKey | cmdKey)

let defaultShortcuts: [String: (code: UInt32, modifiers: UInt32)] = [   // virtual key codes
    "apps": (47, rightHandChord),           // .        panel 1
    "files": (44, rightHandChord),          // /        panel 2 — the path separator: finding
    "actions": (42, rightHandChord),        // \        panel 3 — the escape: doing
    "clipboard": (9, rightHandChord),       // V        the paste key, for the paste history
    "settings": (43, rightHandChord),       // ,        the preferences key
    "colorpicker": (35, rightHandChord),    // P        Picker
    "colorhistory": (4, rightHandChord),    // H        History
    "keepawake": (40, rightHandChord),      // K        Keep awake
    "textcapture": (31, rightHandChord),    // O        OCR
    // Rewrite Text deliberately has no default: it is triggered by double-tapping
    // ⌃ (see `syncRewriteTapMonitor`), and every rewrite action can carry a
    // shortcut of its own.
]

/// Dictation is push-to-talk: it needs the key's release as well as its press,
/// which a Carbon hotkey never reports, so it watches a modifier instead of
/// registering a shortcut.
func usesHoldKey(_ panel: Panel) -> Bool { panel.defaultsKey == "dictation" }

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The modifier held down to talk. Only the right-hand ⌘ and ⌥ are offered:
/// Apple keyboards have no right Control, and Fn/Globe is claimed by the system
/// before it reaches us. Raw values are persisted — only append.
enum HoldKey: Int, CaseIterable {
    case off = 0, rightCommand = 1, rightOption = 2

    /// Menu order — deliberately not the raw order, which is fixed by what's
    /// already stored in defaults.
    static let menuOrder: [HoldKey] = [.off, .rightOption, .rightCommand]

    var label: String {
        switch self {
        case .off:           return "Off"
        case .rightCommand:  return "Hold Right ⌘"
        case .rightOption:   return "Hold Right ⌥"
        }
    }
    /// The physical key, and the flag that tells press from release.
    var keyCode: UInt16? {
        switch self {
        case .off: return nil
        case .rightCommand: return 54
        case .rightOption: return 61
        }
    }
    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .off: return nil
        case .rightCommand: return .command
        case .rightOption: return .option
        }
    }
}

/// One named rewrite action: a title, the instructions behind it, and an
/// optional shortcut of its own.
///
/// More than one turns the tool's own shortcut into a chooser; a set can also
/// carry a shortcut of its own, which skips the chooser and runs it directly.
struct RewriteAction: Equatable {
    var title: String
    var instructions: String
    var shortcut: Shortcut?
    /// Off means inert: not offered in the chooser, and its own shortcut is not
    /// registered. The starter sets ship off, so a fresh install behaves exactly
    /// as it did before any of them existed.
    var enabled: Bool

    /// A starter set with no shortcut of its own. `enabled` decides whether it
    /// shows up in the chooser; the ones that ship off are the two that change
    /// the text into something else rather than tidying it.
    init(title: String, shortcutless instructions: String) {
        self.init(title: title, instructions: instructions, shortcut: nil, enabled: false)
    }
    init(title: String, enabled: Bool, instructions: String) {
        self.init(title: title, instructions: instructions, shortcut: nil, enabled: enabled)
    }
    init(title: String, instructions: String, shortcut: Shortcut?, enabled: Bool) {
        self.title = title; self.instructions = instructions
        self.shortcut = shortcut; self.enabled = enabled
    }
}

extension UserDefaults {
    /// The sets a fresh install starts with, beyond the built-in Clean Dictation.
    ///
    /// Every wording here was measured against the on-device model rather than
    /// written by eye — see the notes on each. The model over-applies anything
    /// that tells it to transform, so each one names what to keep as well as
    /// what to change.
    static let starterActions: [RewriteAction] = [
        RewriteAction(title: "Proofread", instructions: proofreadInstructions,
                      shortcut: Shortcut(keyCode: 17, modifiers: rightHandChord), enabled: true),
        RewriteAction(title: "Professional", enabled: true, instructions:
            "Rewrite the text in a professional tone suitable for workplace correspondence. "
            + "Keep every line of the original, including any heading or introductory line. "
            + "Keep every fact, name, number and request exactly as given. "
            + "Do not add information and do not remove information."),
        // "Keep every line" is load-bearing: without it the model dropped a
        // list's heading outright.
        RewriteAction(title: "Friendly", enabled: true, instructions:
            "Rewrite the text in a warm, casual tone, as if writing to someone you know well. "
            + "Keep every fact, name, number and request exactly as given. "
            + "Do not add information and do not remove information."),
        RewriteAction(title: "Shorten", enabled: true, instructions:
            "Rewrite the text so it can be read and answered in a few seconds: shorter "
            + "sentences, no filler, the main point first. Keep every fact, name, number, "
            + "request, heading and list item that is present. Do not add a subject line, "
            + "a greeting, a sign-off, or any information that is not already there."),
        // Without the "do not add a subject line" clause it invented one every
        // time, including for text that was not an email.
        RewriteAction(title: "Translate to Spanish", shortcutless:
            "Translate the text into Spanish. Translate everything, including headings and "
            + "list items. Keep names, numbers, URLs, email addresses and code exactly as "
            + "they appear. Do not add a note about the translation."),
        RewriteAction(title: "Wrap in HTML", shortcutless:
            "Convert the text into HTML. Wrap each paragraph in <p> tags and each list in "
            + "<ul> with <li> items. Do not add a document structure, <html> or <body> "
            + "elements, styles, or classes. Keep the wording exactly as given."),
    ]

    /// Rewrite Text's actions, in the order the user put them.
    ///
    /// Migrated on read from the single string that preceded them, so an upgrade
    /// keeps whatever was written there rather than resetting it. Nothing is
    /// persisted until a set is actually edited.
    var rewriteActions: [RewriteAction] {
        get {
            guard let raw = array(forKey: "rewriteActions") as? [[String: Any]], !raw.isEmpty else {
                return [RewriteAction(title: UserDefaults.cleanDictationTitle,
                                       instructions: rewriteInstructions,
                                       shortcut: Shortcut(keyCode: 2, modifiers: rightHandChord),
                                       enabled: true)]
                     + UserDefaults.starterActions
            }
            var decoded = raw.compactMap { d -> RewriteAction? in
                guard let t = d["t"] as? String, let i = d["i"] as? String else { return nil }
                let sc = (d["k"] as? Int).map {
                    Shortcut(keyCode: UInt32($0), modifiers: UInt32(d["m"] as? Int ?? 0))
                }
                return RewriteAction(title: t, instructions: i, shortcut: sc,
                                      enabled: d["e"] as? Bool ?? true)
            }
            // Self-heal: the first set is the built-in one and can never be
            // empty. An earlier build could blank it on opening the window, and
            // an empty first set means the fallback has nothing to run.
            if decoded.isEmpty || decoded[0].instructions.isEmpty {
                let builtIn = RewriteAction(title: UserDefaults.cleanDictationTitle,
                                             instructions: UserDefaults.defaultRewriteInstructions,
                                             shortcut: decoded.first?.shortcut, enabled: true)
                if decoded.isEmpty { decoded = [builtIn] } else { decoded[0] = builtIn }
            }
            return decoded
        }
        set {
            let raw = newValue.map { s -> [String: Any] in
                var d: [String: Any] = ["t": s.title, "i": s.instructions, "e": s.enabled]
                if let sc = s.shortcut { d["k"] = Int(sc.keyCode); d["m"] = Int(sc.modifiers) }
                return d
            }
            self.set(raw, forKey: "rewriteActions")
        }
    }
    var settingsToggle: Bool {
        get { object(forKey: "settingsToggle") as? Bool ?? true }
        set { set(newValue, forKey: "settingsToggle") }
    }
    var colorFormat: ColorFormat {
        get { ColorFormat(rawValue: integer(forKey: "colorFormat")) ?? .hex }
        set { set(newValue.rawValue, forKey: "colorFormat") }
    }
    /// Capture Text: keep the OCR line breaks, or flow it onto one line.
    /// Off by default — captured text is usually wanted as prose, not with the
    /// wrapping of wherever it was scraped from.
    var ocrKeepLineBreaks: Bool {
        get { object(forKey: "ocrKeepLineBreaks") as? Bool ?? false }
        set { set(newValue, forKey: "ocrKeepLineBreaks") }
    }
    /// Keep Awake: let the display sleep while the system stays awake. On by
    /// default — the usual reason to block sleep is to let work finish, not to
    /// burn the screen.
    var keepAwakeAllowDisplaySleep: Bool {
        get { object(forKey: "keepAwakeAllowDisplaySleep") as? Bool ?? true }
        set { set(newValue, forKey: "keepAwakeAllowDisplaySleep") }
    }
    /// Rewrite Text: what to tell the on-device model. Two sets, because rewriting
    /// text you typed and cleaning up speech are different jobs.
    /// Spelled out deliberately. "Correct spelling, grammar, capitalization and
    /// punctuation" on its own reads to this model as permission to fix only the
    /// safe, local thing — it would mend a misspelling and hand back a sentence
    /// with no capital and no full stop, and sometimes answer a question instead
    /// of rewriting it. Naming the mechanics fixes both, consistently.
    ///
    /// Naming them is also as far as it should go. Three drafts that lost, so
    /// they don't get tried again:
    ///
    /// - "A question takes a question mark" put question marks on flat statements
    ///   and appended "— is that correct?".
    /// - "Leave contractions as they are" changed nothing whatsoever.
    /// - Spelling the contractions out ("dont becomes don't") did work — and cost
    ///   grammar to get it. Over 12 samples against 12 for this wording, it fixed
    ///   the grammar in 9 rather than 11, left "We was" and "it don't" standing,
    ///   and reordered "him and me" into "I and him" three times, which this very
    ///   instruction forbids. Leaving "it's" as "it is" is a style nit; leaving
    ///   "we was" is a failure to do the job, so the nit stays.
    ///
    /// Simpler wordings lose differently. "Fix spelling, grammar, and make any
    /// corrections needed" keeps contractions properly, but answers instead of
    /// rewriting, rewrites "the thing is" into "The issue is", drops openers
    /// entirely, and leaks "Sure, here's the rewritten text:" into the output —
    /// which then gets pasted into the document. The mechanical framing here is
    /// what stops the model reading this as a chat request.
    ///
    /// The second paragraph is not decoration either — dropping it and keeping
    /// only the mechanics above was tried, and over 24 samples it deleted the
    /// whole second clause of "him and me was going to the shop but it dont open
    /// till ten", and turned "can you send me the file thanks" into "I can send
    /// you the file" — a request inverted into an offer. One is data loss and the
    /// other reverses the meaning; this wording did neither.
    ///
    /// The pattern behind all of it, stated carefully: it over-applies rules that
    /// tell it to transform, and ignores NARROW rules that tell it to hold back —
    /// but the broad "keep the wording" guard is load-bearing, which the
    /// contraction result on its own would have wrongly suggested it wasn't.
    static let proofreadInstructions = """
        Fix every spelling, grammar, capitalization and punctuation error. \
        Capitalize the first word of every sentence and the pronoun I. End every \
        sentence with the punctuation it needs. Split run-on sentences.

        Keep the original wording, tone and meaning — do not rephrase, shorten, \
        reorder or add anything.

        Emoji, symbols, bullets, indents and line breaks are part of the text, \
        not errors in it — keep them all exactly as they appear.

        Never change how a line begins. Whatever a line starts with — a tab, \
        spaces, a bullet, a dash, a number and a dot — reproduce it character for \
        character. Do not swap one list marker for another, and do not add or \
        remove list markers.
        """
    /// The "those removals are the only ones" paragraph is doing specific work.
    /// Without it, three sentences here tell the model to remove things and the
    /// guard only forbade *adding* — so "remove filler" read as a general license
    /// to trim, and it cut words the speaker meant. "I'm not sure if anybody else
    /// can get this working well or not" came back without the "or not" every
    /// time; "worth it or not honestly" lost the "or not" and moved the
    /// "honestly".
    ///
    /// Adding "or leave anything out" to the guard alone barely helped — 1 case in
    /// 3. Closing the list is what fixed it: 3 in 3, on both, while still
    /// stripping the um and uh. The lesson matches the one on the set above: this
    /// model needs the *scope* of an instruction bounded, or it generalises it.
    static let cleanDictationTitle = "Clean Dictation"

    /// The built-in set — the one at the top, which can't be removed and is what
    /// runs when nothing is ticked. It is Clean Dictation, because dictating and
    /// then tidying what you said is the pairing this app is actually for; the
    /// proofreader is a starter set below it, with a key of its own.
    static let defaultRewriteInstructions = cleanDictationInstructions

    /// What Auto-Correct used to apply on its own, now a rewrite action you aim
    /// yourself. Every clause was measured against the on-device model — the
    /// "those removals are the only ones" paragraph is what stopped it quietly
    /// dropping words it judged redundant.
    static let cleanDictationInstructions = """
        Turn dictated speech into clean written text.

        Remove filler words and vocalized pauses — um, uh, er, like, you know, \
        I mean, sort of, and trailing "so yeah". Drop false starts, repeated \
        words, and self-corrections, keeping only what the speaker settled on \
        ("I went to the— I drove to the office" becomes "I drove to the office").

        Add capitalization and punctuation, and break run-on speech into \
        sentences and paragraphs where the sense changes. Fix obvious \
        misrecognized words only when the intended word is unmistakable from \
        context.

        Those removals are the only ones. Every other word the speaker said \
        stays, including words that add no new information.

        Keep the speaker's own words, voice and meaning. Do not summarize, \
        expand, reorder the ideas, make it more formal, add anything that \
        wasn't said, or leave anything out.
        """
    /// Storing text identical to the default would quietly pin it. Opening the
    /// Instructions window and clicking Save without typing anything is enough to
    /// do that, and from then on the saved copy wins and every later improvement
    /// to the default silently never arrives — which is exactly what happened
    /// when Auto-Correct kept dropping words after the wording was supposedly fixed.
    /// Nothing stored means "follow the default", so store nothing unless it
    /// genuinely differs.
    var rewriteInstructions: String {
        get { string(forKey: "rewriteInstructions") ?? UserDefaults.defaultRewriteInstructions }
        set {
            if newValue == UserDefaults.defaultRewriteInstructions {
                removeObject(forKey: "rewriteInstructions")
            } else {
                set(newValue, forKey: "rewriteInstructions")
            }
        }
    }
    /// Dictation: which modifier is held to talk (Off = the tool is idle).
    /// Right ⌥ by default — nothing else claims it, so the tool works out of the
    /// box rather than sitting inert until someone finds the menu.
    var dictationHoldKey: HoldKey {
        get { HoldKey(rawValue: object(forKey: "dictationHoldKey") as? Int ?? HoldKey.rightOption.rawValue) ?? .rightOption }
        set { set(newValue.rawValue, forKey: "dictationHoldKey") }
    }
}

/// The text form a sampled color is copied in. The raw values are stable
/// (persisted in defaults), so only ever append new cases.
enum ColorFormat: Int, CaseIterable {
    case hex = 0, rgb = 1, hsl = 2, swiftUI = 3

    var label: String {
        switch self {
        case .hex: return "Hex"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        case .swiftUI: return "SwiftUI"
        }
    }

    /// Render `color` in this format (always via sRGB for stable numbers).
    func string(for color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let R = Int((r * 255).rounded()), G = Int((g * 255).rounded()), B = Int((b * 255).rounded())
        switch self {
        case .hex: return String(format: "#%02X%02X%02X", R, G, B)
        case .rgb: return "rgb(\(R), \(G), \(B))"
        case .hsl:
            let (h, s, l) = ColorFormat.hsl(r, g, b)
            return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        case .swiftUI:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b)
        }
    }

    /// sRGB → HSL. Hue in degrees [0,360), saturation/lightness in [0,1].
    private static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        return (h * 60, s, l)
    }
}

// MARK: - Color history

/// A remembered color: an sRGB hex plus whether it's a pinned keeper.
struct ColorEntry: Equatable {
    var hex: String
    var pinned: Bool
    var color: NSColor { NSColor.fromSrgbHex(hex) ?? .gray }
}

/// The Color History store — the last `maxRecent` picks plus any pinned keepers,
/// persisted in UserDefaults. Every color pick records here (fast picker too).
enum ColorHistory {
    private static let key = "colorHistory"
    static let maxRecent = 20

    static func load() -> [ColorEntry] {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
        return arr.compactMap {
            guard let hex = $0["hex"] as? String else { return nil }
            return ColorEntry(hex: hex, pinned: ($0["pinned"] as? Bool) ?? false)
        }
    }

    private static func save(_ entries: [ColorEntry]) {
        UserDefaults.standard.set(entries.map { ["hex": $0.hex, "pinned": $0.pinned] }, forKey: key)
    }

    /// Record a pick: it lands at the END (newest last). An existing unpinned
    /// match is refreshed to the end; a pinned match is left where it is. Then the
    /// oldest unpinned beyond the cap are evicted. Pinned entries stay grouped at
    /// the front, so the display reads pinned-first, then recents oldest→newest.
    static func add(_ color: NSColor) {
        let hex = color.srgbHexString
        var entries = load()
        if let i = entries.firstIndex(where: { $0.hex == hex }) {
            if !entries[i].pinned { entries.append(entries.remove(at: i)) }
        } else {
            entries.append(ColorEntry(hex: hex, pinned: false))
        }
        while entries.filter({ !$0.pinned }).count > maxRecent,
              let i = entries.firstIndex(where: { !$0.pinned }) {
            entries.remove(at: i)
        }
        save(entries)
    }

    /// Pinning moves a color to the TOP; unpinning drops it to the bottom as a
    /// fresh recent — keeping pinned entries grouped above the recents.
    static func togglePin(_ hex: String) {
        var entries = load()
        guard let i = entries.firstIndex(where: { $0.hex == hex }) else { return }
        var e = entries.remove(at: i)
        e.pinned.toggle()
        if e.pinned { entries.insert(e, at: 0) } else { entries.append(e) }
        save(entries)
    }

    /// Clear the unpinned recents; pinned keepers stay.
    static func clearRecents() { save(load().filter { $0.pinned }) }
}

extension NSColor {
    /// "#RRGGBB" in sRGB — the canonical form Color History stores.
    var srgbHexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
    static func fromSrgbHex(_ hex: String) -> NSColor? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Render a swatch of `color` to PNG — the image you get by dragging a color out
/// of the palette. Deliberately a full-bleed OPAQUE square: rounded corners would
/// leave transparent gaps, which Finder and Quick Look back with white, so the
/// file reads as a color chip stuck on a white card.
enum ColorSwatch {
    static func png(_ color: NSColor, px: Int = 256) -> Data? {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        // Draw straight into an sRGB context: a deviceRGB bitmap color-converts
        // the fill (a #117AF9 pick exported as #0690FA), and CoreGraphics can't
        // back a 24-bit context at all (that renders black) — so use 32-bit with
        // the alpha channel skipped, filled edge to edge. Fully opaque means no
        // transparency for Finder/Quick Look to back with white.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: rgb.redComponent, green: rgb.greenComponent,
                         blue: rgb.blueComponent, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Color naming for the palette: each color shows its hex unless the user types
/// a custom name. Custom names are stored by hex, so they survive a color rolling
/// out of history and coming back.
enum ColorNames {
    private static let customKey = "colorNames"   // [hex: custom name]

    static func custom(_ hex: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: customKey) as? [String: String])?[hex]
    }
    static func setCustom(_ hex: String, _ name: String?) {
        var d = (UserDefaults.standard.dictionary(forKey: customKey) as? [String: String]) ?? [:]
        d[hex] = (name?.isEmpty == false) ? name : nil
        UserDefaults.standard.set(d, forKey: customKey)
    }
    /// The shown name: a custom one if set, else the hex itself.
    static func display(_ hex: String) -> String { custom(hex) ?? hex }
}

/// Virtual keycodes for F1–F20 — the one family allowed as modifier-less
/// hotkeys (they exist to be bare; a bare letter would hijack typing).
let fKeyCodes: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                              103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

/// A recorded shortcut: virtual keycode + Carbon modifier mask.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon mask (cmdKey | shiftKey | optionKey | controlKey)

    /// The one shortcut bound to a panel, if any. Reads the current single-slot
    /// storage, the earlier multi-binding array (taking its first entry), or the
    /// oldest legacy KeyCode/Modifiers layout — migrating forward on save.
    static func load(_ panel: Panel) -> Shortcut? {
        let d = UserDefaults.standard
        if let arr = d.array(forKey: panel.defaultsKey + "Shortcuts") as? [[String: Int]],
           let first = arr.first, let k = first["k"], let m = first["m"] {
            return Shortcut(keyCode: UInt32(k), modifiers: UInt32(m))
        }
        if let code = d.object(forKey: panel.defaultsKey + "KeyCode") as? Int, code >= 0 {
            return Shortcut(keyCode: UInt32(code),
                            modifiers: UInt32(d.integer(forKey: panel.defaultsKey + "Modifiers")))
        }
        return nil
    }

    /// Save (or clear, with nil) a panel's single shortcut.
    static func save(_ shortcut: Shortcut?, _ panel: Panel) {
        let d = UserDefaults.standard
        if let sc = shortcut {
            d.set([["k": Int(sc.keyCode), "m": Int(sc.modifiers)]], forKey: panel.defaultsKey + "Shortcuts")
        } else {
            d.removeObject(forKey: panel.defaultsKey + "Shortcuts")
        }
        d.removeObject(forKey: panel.defaultsKey + "KeyCode")     // drop legacy keys
        d.removeObject(forKey: panel.defaultsKey + "Modifiers")
    }

    /// "⌃ ⌥ ⇧ ⌘ X" for display — Apple's modifier order, glyphs spaced like the
    /// macOS menu bar (a plain space between each). No "+": that's the
    /// Windows/text convention; native macOS uses bare glyphs.
    var label: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Shortcut.keyName(keyCode))
        return parts.joined(separator: " ")
    }

    static func keyName(_ code: UInt32) -> String {
        let names: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
            9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
            34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`", 49: "Space",
            36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 76: "⌤",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            116: "⇞", 121: "⇟", 115: "↖", 119: "↘", 117: "⌦",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20",
        ]
        return names[code] ?? "key\(code)"
    }
}

/// A read-only view of macOS's built-in "Speak selection" hotkey (System
/// Settings → Accessibility → Read & Speak). Pullcord doesn't own this
/// shortcut; the Speak Text card only reflects whatever macOS has assigned.
struct SpokenSelection: Equatable {
    let enabled: Bool
    let shortcut: String?   // e.g. "⌘⎋"; nil when no combo is stored

    static var current: SpokenSelection {
        let d = UserDefaults(suiteName: "com.apple.speech.synthesis.general.prefs")
        let enabled = d?.bool(forKey: "SpokenUIUseSpeakingHotKeyFlag") ?? false
        let combo = (d?.object(forKey: "SpokenUIUseSpeakingHotKeyCombo") as? NSNumber)?.intValue
        return SpokenSelection(enabled: enabled, shortcut: combo.map(describe))
    }

    /// The combo integer is exactly Pullcord's own Shortcut layout — Carbon
    /// modifier masks OR'd onto the virtual key code (cmdKey 0x100, shiftKey
    /// 0x200, optionKey 0x800, controlKey 0x1000) — so build a Shortcut and reuse
    /// its label, keeping one formatter. e.g. 4149 = 0x1035 → ⌃ esc.
    private static func describe(_ combo: Int) -> String {
        Shortcut(keyCode: UInt32(combo & 0xFF),
                 modifiers: UInt32(combo & (cmdKey | shiftKey | optionKey | controlKey))).label
    }
}

// MARK: - App delegate

/// Where the settings footer's update indicator is in its lifecycle.
/// An NSButton that shows the pointing-hand cursor, so a bare label that happens
/// to be clickable reads as clickable.
final class LinkButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

enum UpdateState {
    case upToDate      // running the latest release
    case available     // a newer release exists (DMG install → manual Update button)
    case downloading   // DMG: fetching the disk image before opening it and quitting
    case updating      // a Homebrew upgrade is running (helper quits + relaunches us)
    case failed        // Homebrew upgrade couldn't start — offer the manual download
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var idToPanel: [UInt32: Int] = [:]   // EventHotKeyID.id → panel index
    private var idToSet: [UInt32: Int] = [:]     // EventHotKeyID.id → instruction-set index
    private var hotKeyHandler: EventHandlerRef?
    private var settings: SettingsWindow?
    private var colorHistoryPanel: ColorHistoryPanel?
    private let hud = HUD()
    private var keepAwakeAssertion: IOPMAssertionID = 0
    // Push-to-talk dictation: monitors on the chosen modifier, and whether we
    // have dictation running right now.
    private var holdMonitors: [Any] = []
    private var dictating = false
    /// True for the length of a rewrite's round trip — select, copy, run the
    /// model, paste — which keeps running for seconds after the shortcut. It
    /// blocks a second rewrite, and it blocks dictation arming: start talking
    /// mid-rewrite and the pending paste lands in the middle of the new
    /// utterance, which is how text came back doubled and jumbled.
    /// No watchdog alongside it any more. There used to be one here — a 20s
    /// timer insuring against `rewriteText` never calling back at all — but
    /// `rewriteText` now guarantees that itself (see `rewriteTimeout`), and having
    /// both was worse than having one: the 20s figure was invisible to the HUD
    /// and, measured directly, too short for a real rewrite besides, so it could
    /// silently reset this flag while a legitimate request was still in flight.
    private var rewriting = false
    /// Which set the chooser landed on, read straight after the menu closes.
    private var pendingActionChoice: Int?
    /// Dictation lags speech, so the stop is deferred — this is the pending one,
    /// canceled if the key goes back down within the grace period.
    private var pendingDictationStop: DispatchWorkItem?
    /// Counts down the dead zone before dictation engages, so holding the key as
    /// an ordinary modifier doesn't start talking.
    private var dictationArmTimer: Timer?
    /// Rewrite Text's trigger — a double-tap of left ⌃ — and the state the
    /// detector keeps. A "tap" is a press and release of ⌃ with no other input
    /// in between; two bare taps within the window fire a rewrite.
    private var rewriteTapMonitors: [Any] = []
    private var rewriteTapDown = false       // ⌃ is currently down
    private var rewriteTapChord = false      // another event interrupted the press
    private var rewriteTapFirst: Date?       // when the first bare tap landed

    private var keepAwakeStatusItem: NSStatusItem?
    private var axPollTimer: Timer?
    private(set) var hasAccessibility = AXIsProcessTrusted()

    /// Panels whose saved shortcut failed to register (another app owns the
    /// combo) — surfaced in the settings banner.
    private(set) var conflicted: [String] = []

    /// True while the recorder is capturing — all hotkeys are parked so the
    /// combo being recorded can't fire the old binding mid-keystroke.
    var recording = false { didSet { syncHotkeys() } }

    /// True while we're posting the ⌘Space→⌘N sequence. Parking the hotkeys
    /// here too is what makes ⌘1–⌘4 usable AS the global shortcuts (the
    /// natural choice, mirroring Spotlight's own keys): Carbon captures
    /// matching combos even when synthesized, so without parking, our own
    /// posted ⌘N would be eaten by our own registration — and re-trigger it.
    private var synthesizing = false
    private var previousApp: NSRunningApplication?

    var appEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "appEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "appEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything registers: hand over to the copy already running, if
        // there is one. Has to come first, since the damage a second instance
        // does is done by the very things below this line.
        if yieldToRunningInstance() { return }
        // A duplicate that quit needs somewhere to send the user, and this is it.
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(showSettingsForDuplicateLaunch),
            name: Self.showSettingsNotification, object: nil)
        seedDefaultShortcutsIfNeeded()
        // Rewrite Text is tap-driven now; drop any shortcut saved before that,
        // so a stale binding can't keep firing or linger in the settings card.
        if let rewrite = panels.first(where: { usesTapKey($0) }), Shortcut.load(rewrite) != nil {
            Shortcut.save(nil, rewrite)
        }
        // The system broadcasts this when Appearance changes (including on the
        // automatic light/dark schedule). A view-level callback isn't dependable
        // here — this app has no Dock presence and its windows are usually not
        // frontmost — so listen for the broadcast instead.
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(systemThemeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        // Tooltips here are quick labels, not asides — show them promptly rather
        // than after AppKit's ~1.5 s dwell.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])
        NSApp.setActivationPolicy(.accessory)
        if appEnabled, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        // No shortcuts are seeded — a fresh install starts blank, and the user
        // records the ones they want. (Format defaults to Hex, Smart Toggle to
        // On, via their UserDefaults getters.)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        installHandler()
        syncHotkeys()
        watchAccessibility()
        // A user-initiated launch (Finder / Spotlight / Launchpad / Dock / `open`)
        // opens straight to settings. A login auto-launch by launchd stays silent
        // in the background; `applicationShouldHandleReopen` shows the window when
        // the user opens the already-running app again. (Key54 pattern.)
        if !launchedAsLoginItem {
            showSettings()   // checks for an update on its way in
        } else {
            // Starting silently at login is the one time nothing will ever bring
            // the answer to you: no window now, and possibly not for weeks. So
            // check once here, and raise the window only if something is actually
            // pending — the update strip is the whole reason for showing it.
            //
            // Delayed so it lands *after* the login rush. Showing a window while
            // other login items are still starting means whichever one activates
            // next buries it, and the point is that this one is seen.
            //
            // This is the only place Pullcord opens a window you didn't ask for,
            // and it's confined to login on purpose: the same behaviour on a timer
            // would interrupt work mid-session, which is why there's no polling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.checkForUpdate { [weak self] _ in
                    guard let self, self.updateState != .upToDate else { return }
                    self.showSettings(checkingForUpdate: false)   // just checked
                }
            }
        }
    }

    // MARK: - Updates

    /// Marketing version, stamped from the release tag by CI.
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private(set) var updateState: UpdateState = .upToDate
    /// Newest release (no leading "v") when it's newer than ours, else nil.
    private(set) var latestVersion: String?
    private var updateStarting = false             // guards against a double Update click
    private var updateWatchdog: Timer?
    let dmgURL = "https://github.com/grokcodile/pullcord/releases/latest/download/Pullcord.dmg"
    /// Installed via the Homebrew cask? Its metadata lives in the Caskroom — but
    /// the Caskroom existing only says *a* Homebrew copy is around, not that it's
    /// the one running. A build launched from anywhere but /Applications is a dev
    /// build, and handing it to `brew upgrade` would overwrite the /Applications
    /// copy (a different app) and then reopen this one — clobbering an install for
    /// nothing.
    lazy var isHomebrewManaged: Bool = {
        let fm = FileManager.default
        let caskroom = fm.fileExists(atPath: "/opt/homebrew/Caskroom/pullcord")
                    || fm.fileExists(atPath: "/usr/local/Caskroom/pullcord")
        return caskroom && Bundle.main.bundlePath == "/Applications/Pullcord.app"
    }()

    /// Ask GitHub for the latest release. Only ever fires where the answer is
    /// visible or about to be: opening the settings window, the once-at-login
    /// check, and the on-demand check in the About popover — there is no polling.
    /// On a newer version the footer surfaces an Update button; it never updates
    /// itself unasked.
    ///
    /// This is the app's only network request. Nothing is sent but the GET.
    /// `completion` reports whether GitHub actually answered, and always runs on
    /// the main queue — the on-demand check needs to say "couldn't check" rather
    /// than sit on "Checking…" forever, and `handleLatest` deliberately stays
    /// silent when nothing changed, so it can't be used as the signal.
    func checkForUpdate(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "https://api.github.com/repos/grokcodile/pullcord/releases/latest")
        else { completion?(false); return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let self else {
                await MainActor.run { completion?(false) }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            // Only a release that actually carries the DMG counts. CI publishes the
            // release a moment before its upload lands, and both update paths (the
            // download and the Homebrew cask) fetch that file — offering a release
            // without it would send the Update button straight at a 404.
            let dmgName = URL(string: self.dmgURL)?.lastPathComponent
            let assets = json["assets"] as? [[String: Any]] ?? []
            let installable = assets.contains { $0["name"] as? String == dmgName }
            await MainActor.run {
                self.handleLatest(latest, installable: installable)
                completion?(true)
            }
        }
    }

    private func handleLatest(_ latest: String, installable: Bool) {
        // Never interrupt an update already in flight.
        guard updateState != .updating, updateState != .downloading else { return }
        let newState: UpdateState =
            installable && AppDelegate.isVersion(latest, newerThan: appVersion) ? .available : .upToDate
        let newLatest = newState == .available ? latest : nil
        // Only touch the window on a real transition — refreshUpdateFooter
        // rebuilds it, which must not happen on a routine "no news" check.
        guard newState != updateState || newLatest != latestVersion else { return }
        latestVersion = newLatest
        updateState = newState
        settings?.refreshUpdateFooter()
    }

    /// The footer's Update button. Runs the right update for how Pullcord was
    /// installed: the Homebrew helper, or the DMG download.
    @objc func performUpdate() {
        if isHomebrewManaged { startHomebrewUpdate() } else { downloadUpdate() }
    }

    /// Numeric, component-wise compare so "1.26" > "1.9" > "1.17".
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Homebrew update (user-triggered from the footer button)

    private func startHomebrewUpdate() {
        guard !updateStarting, let brew = brewPath() else {
            updateState = .available          // can't run brew — offer the manual path
            settings?.refreshUpdateFooter()
            return
        }
        updateStarting = true
        updateState = .updating
        settings?.refreshUpdateFooter()

        // Run the upgrade from a DETACHED helper, not in-process: brew quits the
        // app it's replacing — which would be us — killing the upgrade
        // mid-flight. The helper does the slow work (index refresh + download)
        // FIRST, while we're still alive showing "Updating…", then quits us,
        // swaps in the pre-fetched build, and reopens the app. We never
        // terminate ourselves: quitting early leaves a long "is it done?" gap
        // that invites reopening the app mid-upgrade, and brew then kills that
        // instance too. The relaunch is unconditional, so even a failed upgrade
        // brings the app back (and the footer just offers the update again).
        let brewBin = (brew as NSString).deletingLastPathComponent
        let bundle = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        // We're quit by PID, before the upgrade, and both halves matter. By name
        // (`pkill -x Pullcord`) matched nothing: pkill and pgrep skip their own
        // ancestors, and this helper is our child. That left the quit to brew,
        // and Homebrew (since 53ca353, Aug 2026) won't quit an app that brew is
        // running inside — which, walking up from this helper, is us. So brew
        // swapped the bundle under a live copy, `open` just re-focused it, and
        // the strip sat on "Updating…". Once we've exited, this helper belongs
        // to launchd, brew isn't inside Pullcord any more, and any other copy
        // gets quit the normal way.
        let script = """
        #!/bin/sh
        export PATH="\(brewBin):/usr/bin:/bin:/usr/sbin:/sbin"
        "\(brew)" update >/dev/null 2>&1
        "\(brew)" fetch --cask pullcord >/dev/null 2>&1
        kill \(pid) 2>/dev/null
        for i in $(seq 1 20); do kill -0 \(pid) 2>/dev/null || break; sleep 0.5; done
        kill -0 \(pid) 2>/dev/null && kill -9 \(pid) 2>/dev/null
        "\(brew)" upgrade --cask pullcord >/dev/null 2>&1
        # Homebrew tags cask installs with com.apple.quarantine, and a quarantined
        # app needs an interactive first launch to be approved. Pullcord's first
        # launch after a restart is launchd starting the login item — no user, no
        # approval — so Gatekeeper refuses it with "Apple could not verify
        # Pullcord is free of malware" and the agent never comes back. Clearing
        # the tag is what `brew install --cask --no-quarantine` does; the bundle is
        # still signed, notarized and stapled. Must happen here rather than inside
        # the app: macOS refuses the write for a bundle that's running.
        xattr -dr com.apple.quarantine "\(bundle)" 2>/dev/null
        open "\(bundle)"
        """
        let path = NSTemporaryDirectory() + "pullcord-update.sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [path]
            try p.run()
            armUpdateWatchdog()
        } catch {
            updateStarting = false            // let the user try again
            updateState = .failed
            settings?.refreshUpdateFooter()
        }
    }

    /// A successful upgrade ends with this process being killed, so reaching the
    /// end of this timer means it didn't happen: brew found nothing to do, or
    /// the helper died. Without it the strip sits on "Updating…" forever with no
    /// button and no way back — which is what a no-op upgrade looks like from
    /// the outside. Generous, because `brew update` on a cold index is slow.
    private func armUpdateWatchdog() {
        updateWatchdog?.invalidate()
        updateWatchdog = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) {
            [weak self] _ in
            guard let self, self.updateState == .updating else { return }
            self.updateStarting = false       // let them try again
            self.updateState = .failed        // shows the button, with the manual path behind it
            self.settings?.refreshUpdateFooter()
            // Re-check: if brew quietly did replace us, this corrects to upToDate.
            self.checkForUpdate()
        }
    }

    private func brewPath() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    // MARK: DMG assisted update

    /// Download the latest DMG, open (mount) it, then quit — so the user can drag
    /// the new build straight over this one without the "app is in use" block.
    @objc func downloadUpdate() {
        guard let url = URL(string: dmgURL) else { return }
        updateState = .downloading
        settings?.refreshUpdateFooter()
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Pullcord.dmg")
        Task { [weak self] in
            do {
                let (tmp, response) = try await URLSession.shared.download(from: url)
                // download(from:) doesn't throw on an HTTP error: a missing asset
                // arrives as GitHub's 404 page, which must not replace the user's
                // ~/Downloads/Pullcord.dmg, get "mounted", or quit us.
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: tmp)
                    throw URLError(.fileDoesNotExist)
                }
                // Claim the temp file here, in the same context — it isn't
                // guaranteed to survive an actor hop.
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                await MainActor.run {
                    NSWorkspace.shared.open(dest)   // mount it → Finder shows the drag window
                    // Quit once the mount request is out, so nothing holds the old app.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                // Couldn't download — hand it to the browser and stay open. If GitHub
                // answered without the file, the release page beats a link that
                // would only 404 again there.
                guard let self else { return }
                let fallback = (error as? URLError)?.code == .fileDoesNotExist
                    ? URL(string: "https://github.com/grokcodile/pullcord/releases/latest") ?? url
                    : url
                await MainActor.run {
                    NSWorkspace.shared.open(fallback)
                    self.updateState = .available
                    self.settings?.refreshUpdateFooter()
                }
            }
        }
    }

    /// Sent by a duplicate on its way out, so the copy that's staying brings up
    /// settings — otherwise opening the app would look like nothing happened.
    private static let showSettingsNotification =
        NSNotification.Name("com.ethan.pullcord.showSettings")

    @objc private func showSettingsForDuplicateLaunch() { showSettings() }

    /// Quit if another copy is already running, after pointing the user at it.
    /// Returns true when this instance is the one that should go away.
    ///
    /// Two copies do not share nicely. Each registers the same global hotkeys and
    /// installs its own dictation monitor, so one keypress fires twice and two
    /// rewrites run over the same sentence while the other is pasting into it —
    /// which reads as text coming back mangled and repeated.
    ///
    /// This asks which processes are running rather than setting
    /// LSMultipleInstancesProhibited, because LaunchServices keys that on the
    /// bundle it finds on disk. The way copies actually stacked up here was a
    /// rebuild replacing the bundle underneath a running instance: the new bundle
    /// looks like a different app to LaunchServices, so it would happily launch
    /// it — but the orphan still answers to this bundle id, so it is caught here.
    private func yieldToRunningInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
        guard !others.isEmpty else { return false }

        // Launched together, each would see the other and both would quit. So the
        // one that started first stays, and an identical timestamp is settled by
        // the lower pid — any rule works as long as both sides reach the same one.
        //
        // The two fallbacks lean opposite ways on purpose, and both lean towards
        // yielding. A process launched by running the executable directly has no
        // launchDate at all, so dating ourselves `.distantPast` would make the
        // newcomer believe it was the incumbent and stay — which is exactly how
        // copies used to stack. Unknown self means "just started"; unknown other
        // means "already here".
        let launched = NSRunningApplication.current.launchDate ?? Date()
        let incumbent = others.first {
            let theirs = $0.launchDate ?? .distantPast
            return theirs == launched ? $0.processIdentifier < mine : theirs < launched
        }
        guard let incumbent else { return false }

        // A login launch that finds a copy running just goes quietly. A launch the
        // user asked for means they wanted the window, so the incumbent shows it.
        if !launchedAsLoginItem {
            DistributedNotificationCenter.default().postNotificationName(
                Self.showSettingsNotification, object: nil, userInfo: nil,
                deliverImmediately: true)
            incumbent.activate()
        }
        // exit() rather than NSApp.terminate: nothing has been registered yet, so
        // there is nothing to unwind, and this cannot be delayed by the usual
        // should-terminate path. deliverImmediately above has already handed the
        // notification over.
        exit(0)
    }

    /// Whether launchd auto-started us at login (vs. the user opening the app).
    /// The launch Apple Event carries `keyAELaunchedAsLogInItem` only on a login
    /// launch; a user open sends `kAEOpenApplication` without it. MUST be read in
    /// `applicationDidFinishLaunching` — `currentAppleEvent` is nil any earlier.
    private var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
                .enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func seedDefaultShortcutsIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didSeedShortcuts") else { return }
        d.set(true, forKey: "didSeedShortcuts")
        for panel in panels where Shortcut.load(panel) == nil {
            guard let def = defaultShortcuts[panel.defaultsKey] else { continue }
            Shortcut.save(Shortcut(keyCode: def.code, modifiers: def.modifiers), panel)
        }
    }

    func setAppEnabled(_ on: Bool) {
        appEnabled = on
        defer { syncDictationMonitor(); syncRewriteTapMonitor() }
        if on {
            if SMAppService.mainApp.status != .enabled {
                try? SMAppService.mainApp.register()
            }
        } else {
            try? SMAppService.mainApp.unregister()
        }
        syncHotkeys()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    /// `checkingForUpdate` is only false when the caller has just checked — the
    /// login-launch path, which opens this window precisely *because* it found
    /// something. Re-asking there would be a second request for an answer already
    /// in hand.
    func showSettings(checkingForUpdate: Bool = true) {
        if settings == nil { settings = SettingsWindow(delegate: self) }
        settings?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if checkingForUpdate {
            checkForUpdate()   // the strip shows fresh state whenever it's seen
        }
    }

    // MARK: App tracking

    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        if bundleID == "com.apple.systempreferences" || bundleID == Bundle.main.bundleIdentifier { return }
        previousApp = app
    }

    // MARK: Accessibility

    /// Synthesis panels need posting rights. Mirror Key54's approach: track
    /// trust, reconcile hotkeys when it flips, poll while untrusted.
    private func watchAccessibility() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(axChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
        axChanged()
        syncDictationMonitor()
        syncRewriteTapMonitor()
    }

    /// Redraw anything holding baked layer colors. The notification can arrive
    /// a beat before the new appearance resolves, hence the short delay.
    @objc private func systemThemeChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.settings?.appearanceChanged()
            self?.colorHistoryPanel?.appearanceChanged()
        }
    }

    @objc private func axChanged() {
        // The notification can arrive slightly before TCC settles; re-check on
        // a short delay, then keep polling while untrusted (Key54 pattern).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.hasAccessibility {
                self.hasAccessibility = trusted
                self.syncHotkeys()
                // Global NSEvent monitors need trust too, and they were being
                // left behind: granting Accessibility while running brought the
                // hotkeys back but not the dictation hold key or the ⌃ tap —
                // which is now Rewrite Text's only trigger.
                self.syncDictationMonitor()
                self.syncRewriteTapMonitor()
            }
            self.axPollTimer?.invalidate()
            if !trusted {
                self.axPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self, AXIsProcessTrusted() else { return }
                    self.axPollTimer?.invalidate()
                    self.hasAccessibility = true
                    self.syncHotkeys()
                    self.syncDictationMonitor()
                    self.syncRewriteTapMonitor()
                }
            }
        }
    }

    func promptForAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Hotkeys

    private func installHandler() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userInfo -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<AppDelegate>.fromOpaque(userInfo!).takeUnretainedValue()
            if let set = me.idToSet[id.id] {
                DispatchQueue.main.async { me.rewriteSelection(setIndex: set) }
                return noErr
            }
            if let index = me.idToPanel[id.id] {
                DispatchQueue.main.async { me.openPanel(index) }
            }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    /// Reconcile registered hotkeys with saved shortcuts. A registered hotkey
    /// eats its combo system-wide, so only register what can actually work:
    /// Apps and Color Picker always can (no keystroke synthesis, no
    /// permissions); the synthesis panels only when Accessibility is granted.
    /// Nothing while recording. Registration failures (another app owns the
    /// combo) are collected for the settings banner rather than silently ignored.
    func syncHotkeys() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs = []
        idToPanel = [:]
        idToSet = [:]
        conflicted = []
        defer { settings?.refreshBanner() }
        guard appEnabled && !recording && !synthesizing else { return }
        var nextId: UInt32 = 1
        for (i, panel) in panels.enumerated() {
            if mirrorsMacOSHotkey(panel) { continue }   // macOS owns Speak Text's hotkey
            if usesHoldKey(panel) { continue }          // watched by a monitor, not a hotkey
            if usesTapKey(panel) { continue }           // double-tap ⌃, not a hotkey
            guard worksWithoutAX(panel) || hasAccessibility else { continue }
            guard let sc = Shortcut.load(panel) else { continue }
            let id = EventHotKeyID(signature: OSType(0x4B_4C_49_54) /* 'KLIT' */, id: nextId)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(sc.keyCode, sc.modifiers, id,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {   // else eventHotKeyExistsErr: Raycast/Alfred owns it
                hotKeyRefs.append(ref)
                idToPanel[nextId] = i
            } else {
                conflicted.append("\(panel.name) (\(sc.label))")
            }
            nextId += 1
        }

        // Instruction sets that carry a shortcut of their own, so they can be run
        // without stopping at the chooser. They need the same Accessibility as
        // Rewrite Text itself, since they read and replace the selection.
        guard hasAccessibility else { return }
        for (i, set) in UserDefaults.standard.rewriteActions.enumerated() {
            // Not gated on `enabled`: that only decides whether the action is
            // offered in the menu. A shortcut you set deliberately should fire.
            guard let sc = set.shortcut else { continue }
            let id = EventHotKeyID(signature: OSType(0x4B_4C_49_54) /* 'KLIT' */, id: nextId)
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(sc.keyCode, sc.modifiers, id,
                                   GetEventDispatcherTarget(), 0, &ref) == noErr, let ref {
                hotKeyRefs.append(ref)
                idToSet[nextId] = i
            } else {
                conflicted.append("\(set.title) (\(sc.label))")
            }
            nextId += 1
        }
    }

    // MARK: Opening panels

    func openPanel(_ index: Int) {
        guard panels.indices.contains(index) else { return }
        let panel = panels[index]

        if panel.defaultsKey == "colorpicker" {
            sampleColor()
            return
        }

        if panel.defaultsKey == "colorhistory" {
            showColorHistory()
            return
        }

        if panel.defaultsKey == "rewrite" {
            rewriteSelection()
            return
        }

        if panel.defaultsKey == "textcapture" {
            captureText()
            return
        }

        if panel.defaultsKey == "keepawake" {
            toggleKeepAwake()
            return
        }

        if panel.defaultsKey == "settings" {
            let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
            let frontmost = NSWorkspace.shared.frontmostApplication
            if UserDefaults.standard.settingsToggle,
               frontmost?.bundleIdentifier == "com.apple.systempreferences" {
                frontmost?.hide()
                if let prev = previousApp, !prev.isTerminated {
                    prev.activate()
                }
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            // Smart Toggle is the "get me there and back" switch, so it also
            // decides whether you arrive ready to type. Opening onto whichever
            // pane you left behind is fine when you went looking for that pane;
            // it is a dead end when you came for a setting you'd have to hunt.
            let wantsSearch = UserDefaults.standard.settingsToggle
            NSWorkspace.shared.openApplication(at: settingsURL, configuration: config) { [weak self] app, _ in
                guard wantsSearch, let app else { return }
                DispatchQueue.main.async { self?.focusSettingsSearch(in: app) }
            }
            return
        }

        if panel.defaultsKey == "apps" {
            let stub = URL(fileURLWithPath: "/System/Applications/Apps.app")
            if FileManager.default.fileExists(atPath: stub.path) {
                let config = NSWorkspace.OpenConfiguration()
                config.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: stub, configuration: config) { [weak self] _, error in
                    guard error != nil else { return }
                    DispatchQueue.main.async {
                        self?.synthesizeSpotlight(then: panel.spotlightKey,
                                                  trigger: Shortcut.load(panel).map { CGKeyCode($0.keyCode) })
                    }
                }
                return
            }
        }

        synthesizeSpotlight(then: panel.spotlightKey,
                            trigger: Shortcut.load(panel).map { CGKeyCode($0.keyCode) })
    }

    // MARK: Rewrite Text

    /// Rewrite the selection in place: copy it, run it through the on-device
    /// model with the user's instructions, and paste the result back.
    ///
    /// The clipboard is borrowed for the round trip, and put back only on the
    /// paths that give up. When the rewrite lands, the rewritten text stays on
    /// the clipboard: it is the thing the user just asked to be made, the paste
    /// has collapsed the selection so ⌘C cannot reach it, and the edit itself is
    /// undoable either way. Restoring the old text there was tidy and useless.
    ///
    /// With nothing selected it asks rather than guessing. Taking the whole field
    /// used to happen here and is what made this unsafe: apps that publish no
    /// accessibility element hand over the field's text whether or not anything
    /// is selected, so a deliberate select-all could not be told from an empty
    /// caret — and pasting into the second appends instead of replacing.
    func rewriteSelection(known: String? = nil, setIndex: Int? = nil) {
        // One round trip at a time. Two overlapping ones race over the clipboard
        // and the selection, and the loser's paste lands wherever the caret has
        // got to by then — the same failure as dictating again mid-rewrite, just
        // reached by pressing the shortcut twice. The dictated path claimed this
        // back in stopDictation; a manual press hasn't.
        if rewriting { NSSound.beep(); return }
        beginRewriting()
        guard hasAccessibility else { endRewriting(); promptForAccessibility(); return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        // Three ways to learn what's selected, cheapest first. Only the last one
        // touches the clipboard, and it's the only one that leaves a trace there.
        if let known {
            resolveThenRun(known, restoring: saved, setIndex: setIndex)
            return
        }
        if let viaAX = selectedTextViaAX() {
            resolveThenRun(viaAX, restoring: saved, setIndex: setIndex)
            return
        }

        copySelectionText { [weak self] text in
            guard let self else { return }
            if let text {
                self.resolveThenRun(text, restoring: saved, setIndex: setIndex)   // ends it
            } else {
                // No selection, and nothing to fall back on. Taking the whole
                // field used to happen here, and it is what made this unsafe:
                // apps that publish no accessibility element hand over the
                // field's text whether or not anything is selected, so there was
                // no way to tell a deliberate select-all from an empty caret —
                // and pasting into the second appends instead of replacing.
                // Asking is honest, and it can't corrupt anything.
                self.endRewriting()
                self.hud.showMessage("Select some text first", symbol: "text.cursor",
                                     tint: nil)
                Self.restoreClipboard(saved, on: pb)
            }
        }
    }

    /// Which instructions to run, decided once the text is in hand.
    ///
    /// The text is gathered before the chooser opens, deliberately: the menu
    /// takes key events, and reading the selection afterwards would be reading
    /// it through whatever the menu did to focus.
    private func resolveThenRun(_ text: String,
                                restoring saved: String?, setIndex: Int?) {
        let sets = UserDefaults.standard.rewriteActions
        if let i = setIndex, let set = sets[safe: i] {            // a set's own shortcut
            runRewrite(text, action: set, restoring: saved)
            return
        }
        // Nothing enabled falls back to the built-in Clean Up, so the shortcut
        // always does something; one enabled runs straight through; more than
        // one is the only case worth interrupting for.
        let active = sets.filter(\.enabled)
        if active.count <= 1 {
            let only = active.first ?? sets.first
            runRewrite(text,
                       action: only ?? RewriteAction(title: UserDefaults.cleanDictationTitle,
                                                     shortcutless: UserDefaults.defaultRewriteInstructions),
                       restoring: saved)
            return
        }
        guard let chosen = chooseRewriteAction(active) else {    // Esc, or clicked away
            endRewriting()
            hud.hide()
            Self.restoreClipboard(saved, on: NSPasteboard.general)
            return
        }
        runRewrite(text, action: chosen, restoring: saved)
    }

    /// The chooser: a plain menu at the pointer, numbered so a set is one
    /// keypress away. `popUp` runs its own event loop and returns when the menu
    /// closes, so the answer is ready on the next line.
    private func chooseRewriteAction(_ sets: [RewriteAction]) -> RewriteAction? {
        pendingActionChoice = nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (i, set) in sets.enumerated() {
            let item = NSMenuItem(title: set.title, action: #selector(pickRewriteAction(_:)),
                                  keyEquivalent: i < 9 ? String(i + 1) : "")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        // The tail is the way to grow the list without a detour through Settings:
        // it opens the editor with a new set already dropped in, ready to name.
        menu.addItem(.separator())
        let newItem = NSMenuItem(title: "New Action…", action: #selector(pickRewriteAction(_:)),
                                 keyEquivalent: "")
        newItem.keyEquivalentModifierMask = []
        newItem.target = self
        newItem.tag = newRewriteActionTag
        menu.addItem(newItem)
        // Highlight the first item, so Return runs it without touching the mouse
        // — and so the highlight itself shows the arrow keys are live. NSMenu
        // exposes no selection API, so this hands its tracking loop a Down arrow
        // to consume as it opens.
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        if let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: 0, context: nil,
                                        characters: down, charactersIgnoringModifiers: down,
                                        isARepeat: false, keyCode: UInt16(kVK_DownArrow)) {
            NSApp.postEvent(arrow, atStart: true)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return pendingActionChoice.flatMap { sets[safe: $0] }
    }

    /// Set indices are non-negative, so this is unambiguous.
    private let newRewriteActionTag = -1

    @objc private func pickRewriteAction(_ sender: NSMenuItem) {
        guard sender.tag != newRewriteActionTag else {
            // The popup is still closing; hand the rest to the next runloop pass
            // so nothing fights its dismissal.
            DispatchQueue.main.async { [weak self] in self?.newRewriteAction() }
            return
        }
        pendingActionChoice = sender.tag
    }

    /// The picker's tail: open Settings' Rewrite editor with a fresh set inside,
    /// named and waiting for instructions. The rewrite that raised the picker is
    /// abandoned, exactly as if nothing had been chosen.
    private func newRewriteAction() {
        showSettings()
        settings?.addRewriteAction()
    }

    private func runRewrite(_ text: String, action: RewriteAction,
                               restoring saved: String?) {
        let instructions = action.instructions
        // Clean Dictation keeps the prose path. Everything else fills a field.
        // Measured when this was Auto-Correct and the choice was made per-caller:
        // the same speech came back through the field as "I drove to the office
        // and it was really busy so yeah", no final stop and a quarter of the
        // commas, where prose punctuated it properly. Punctuation is most of what
        // cleaning up dictation is, so that one action keeps the path that does
        // it. Matched on the title, so renaming the action opts out — and a
        // renamed one is no longer the thing this was measured on.
        let prose = action.title == UserDefaults.cleanDictationTitle
        let pb = NSPasteboard.general
        // A selection with no letters in it — a lone arrow, a bullet, a number —
        // has no spelling or grammar to fix, and asking anyway invites the model
        // to explain itself instead: "I cannot rewrite this text because it only
        // contains a symbol." That sentence then lands on top of the symbol.
        guard text.contains(where: { $0.isLetter }) else {
            endRewriting()
            hud.showMessage("Nothing to rewrite", symbol: "questionmark.circle.fill",
                            tint: nil)
            Self.restoreClipboard(saved, on: pb)
            return
        }
        hud.showProcessing()
        rewriteText(text, instructions: instructions, prose: prose) { [weak self] result, timedOut in
            guard let self else { return }
            guard let result else {
                self.endRewriting()
                // You pressed a key and are owed an answer about why the text
                // didn't move.
                //
                // Not the red warning triangle the other failures use either.
                // Those are things you have to go and fix; this one is the model
                // shrugging, and your text is exactly where you left it. A
                // timeout gets its own honest label rather than folding into
                // that: nothing was refused, this app just stopped waiting.
                if timedOut {
                    self.hud.showMessage("Took Too Long", symbol: "clock.badge.exclamationmark",
                                         tint: nil)
                } else {
                    self.hud.showMessage("Unchanged", symbol: "questionmark.circle.fill",
                                         tint: nil)
                }
                Self.restoreClipboard(saved, on: pb)
                return
            }
            let outgoing = Self.rewrap(result, like: text)
            Self.setClipboardQuietly(outgoing, on: pb)
            // Take the field again right before pasting rather than trusting the
            // selection to have survived the model call. It often doesn't: apps
            // that publish no accessibility element drop it while they're not
            // being typed into, and ⌘V then inserts instead of replacing —
            // which appended the rewrite to the text it was meant to replace.
            // This is what the dictation path has always done, and why that one
            // never had the bug.
            //
            // Nothing after this call: pasteOverVerifiedSelection owns the HUD
            // message, the clipboard and endRewriting() completely, for both of
            // its outcomes. This used to also show "Rewritten" and schedule its
            // own restore-and-end unconditionally, racing whatever that function
            // decided — so a selection that had moved got "Rewritten" shown for
            // a paste that never happened, and a successful one could have its
            // clipboard restored to the old text before the ⌘V it just posted
            // had actually landed in the target app.
            self.pasteOverVerifiedSelection(outgoing, matching: text, on: pb, saved: saved)
        }
    }

    /// Confirm the selection is still there, without disturbing it.
    ///
    /// A selection can vanish while the model is thinking — apps that publish no
    /// accessibility element let go whenever the field isn't being typed into —
    /// and ⌘V then inserts instead of replacing, appending the rewrite to the
    /// text it was meant to overwrite.
    ///
    /// Accessibility answers it for free where it can. Otherwise a bare ⌘C
    /// answers it too: the same text back means the selection held. Anything
    /// else and this stops, because a rewrite that lands in the wrong place is
    /// worse than one that doesn't land.
    ///
    /// Asking Accessibility first is not just cheaper. A synthesised ⌘C here is
    /// a real copy in the frontmost app — indistinguishable from the user
    /// pressing it — so macOS files the *old* text in the system clipboard
    /// history, and no transient marker can prevent that, because this app is
    /// not the one doing the writing. It happened even when the text had already
    /// been read over Accessibility and no copy was needed at all.
    private func pasteOverVerifiedSelection(_ outgoing: String, matching original: String,
                                            on pb: NSPasteboard, saved: String?) {
        func held(_ live: String?) -> Bool {
            live?.trimmingCharacters(in: .whitespacesAndNewlines)
                == original.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let live = selectedTextViaAX() {
            if held(live) { pasteRewrite(outgoing, on: pb) }
            else { abandonRewrite(restoring: saved, on: pb) }
            return
        }

        let before = pb.changeCount
        post(CGKeyCode(kVK_ANSI_C), .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let live = pb.changeCount != before ? Self.selectedText(from: pb) : nil
            guard held(live) else { self.abandonRewrite(restoring: saved, on: pb); return }
            self.pasteRewrite(outgoing, on: pb)
        }
    }

    /// The selection moved or vanished while the model was thinking. Say so and
    /// change nothing — the app's own verification copy is all that touched the
    /// clipboard, so that goes back.
    private func abandonRewrite(restoring saved: String?, on pb: NSPasteboard) {
        hud.showMessage("Select the text again", symbol: "text.cursor", tint: nil)
        Self.restoreClipboard(saved, on: pb)
        endRewriting()
    }

    /// The rewritten text stays on the clipboard. Putting the old text back was
    /// tidy while the paste was only a means to an end, but it threw away the one
    /// piece of text the user had just asked to be made — and the paste collapses
    /// the selection, so ⌘C cannot reach it. The edit is undoable either way.
    ///
    /// Written through setClipboardQuietly, so it carries the transient markers
    /// clipboard managers watch for: there to paste, not filed as a copy.
    private func pasteRewrite(_ outgoing: String, on pb: NSPasteboard) {
        hud.showMessage("Rewritten", symbol: "checkmark.circle.fill", tint: nil)
        Self.setClipboardQuietly(outgoing, on: pb)
        post(CGKeyCode(kVK_ANSI_V), .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.endRewriting()
        }
    }

    /// Copy whatever is selected and hand it back, or nil if nothing came.
    private func copySelectionText(then: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        post(CGKeyCode(kVK_ANSI_C), .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pb.changeCount != before, let text = Self.selectedText(from: pb),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { then(nil); return }
            then(text)
        }
    }

    /// What was actually selected, in characters.
    ///
    /// The plain-text flavor can't be trusted for this, because a rich editor
    /// flattens structure into it. Copy a checklist item in Notes and the plain
    /// flavor reads "- [ ] Buy milk" — but the checkbox is a paragraph attribute
    /// (an NSTextList), and the only characters selected are "Buy milk". Feed the
    /// flattened version to the model and paste the result back and the marker
    /// arrives as literal text in a paragraph that still draws its own checkbox,
    /// so the bullet appears twice: once drawn, once spelled out.
    ///
    /// The rich flavor is the honest one — its attributed string holds exactly the
    /// characters, with the list left as an attribute where it belongs. So prefer
    /// it whenever it's there, and take its absence as the signal that the source
    /// is a plain-text editor, where "- [ ]" really is content and has to survive
    /// untouched. That distinction is the whole point: the two cases need opposite
    /// handling, and which flavors the app offers is what tells them apart.
    private static func selectedText(from pb: NSPasteboard) -> String? {
        let plain = pb.string(forType: .string)
        for (type, doc) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd),
                            (NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf)] {
            guard let data = pb.data(forType: type),
                  let attr = try? NSAttributedString(data: data, options: [.documentType: doc],
                                                     documentAttributes: nil),
                  !attr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            var rich = attr.string
            // The rich flavor carries the paragraph's terminating newline where the
            // plain one doesn't; pasting that back would open a second list item.
            while rich.hasSuffix("\n") && plain?.hasSuffix("\n") != true { rich.removeLast() }
            return rich
        }
        return plain
    }

    /// Put back the whitespace the model trimmed off the ends.
    ///
    /// The model is asked to rewrite a sentence and returns exactly that, trimmed
    /// — which is right for the words and wrong for what surrounds them. The space
    /// on either side of a selection belongs to the document, not the sentence:
    /// when the line didn't already end in one, macOS dictation puts a space at
    /// the front of what it inserts, and the exact-selection diff quite correctly
    /// includes it. Trim that away on the way back and the new sentence lands
    /// flush against the previous one.
    private static func rewrap(_ rewritten: String, like original: String) -> String {
        // Can't happen — a blank selection is rejected before the model sees it —
        // but if it did, lead and trail would both be the whole string.
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rewritten
        }
        let lead = String(original.prefix { $0.isWhitespace })
        let trail = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return lead + rewritten + trail
    }

    /// Put text on the clipboard without it turning up in clipboard history.
    ///
    /// Rewrite Text only uses the clipboard as a courier: the rewritten text goes on
    /// it so ⌘V can carry it into the app, and the original goes straight back
    /// after. Neither is something you copied, and both used to land in the very
    /// history the Clipboard panel shows — so one tidy left two stray entries.
    ///
    /// Which marker to use was measured against macOS 26's own history rather
    /// than assumed: it honors org.nspasteboard's TransientType, ConcealedType
    /// and AutoGeneratedType, and ignores com.apple.is-sensitive. Transient and
    /// AutoGenerated are the two that are actually true here. Concealed is not —
    /// it means "secret", and managers that honor it may expire or redact the
    /// entry, which would be a lie about what this is.
    private static func setClipboardQuietly(_ text: String, on pb: NSPasteboard) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in ["org.nspasteboard.TransientType",
                       "org.nspasteboard.AutoGeneratedType"] {
            item.setString("", forType: NSPasteboard.PasteboardType(rawValue: marker))
        }
        pb.writeObjects([item])
    }

    /// Hand the clipboard back as it was found. Quietly, because putting it back
    /// isn't a fresh copy — recording it again would duplicate an entry that is
    /// already in the history from when it was really copied.
    /// Put back the clipboard the rewrite borrowed.
    ///
    /// Only for the paths that give up. A rewrite that lands leaves its own text
    /// on the clipboard instead — see `rewriteSelection`.
    private static func restoreClipboard(_ saved: String?, on pb: NSPasteboard) {
        guard let saved else { return }
        setClipboardQuietly(saved, on: pb)
    }

    /// One field, holding the rewrite. Built once, at runtime rather than with
    /// the @Generable macro, so the whole app still compiles with a bare swiftc.
    private static let rewriteSchema: GenerationSchema? = {
        let text = DynamicGenerationSchema.Property(
            name: "text", description: "The rewritten text, and nothing else",
            schema: DynamicGenerationSchema(type: String.self))
        let root = DynamicGenerationSchema(name: "Rewritten",
                                           description: "A rewrite of the text",
                                           properties: [text])
        return try? GenerationSchema(root: root, dependencies: [])
    }()

    /// Whether the model handed back its own output format instead of a rewrite.
    ///
    /// Guided generation puts the schema in the prompt as text, so an instruction
    /// broad enough to cover everything in view covers that too. Reported against
    /// "Translate to Spanish": one selected word came back as the translated word
    /// followed by a Spanish rendering of this app's own schema — "Una reescritura
    /// del texto" is the root description at `rewriteSchema`, "El texto reescrito,
    /// y nada más" is the property's.
    ///
    /// Matched on the JSON keys rather than the descriptions, because the keys are
    /// the part that survives: the model translated every value it saw and left
    /// `properties`, `required` and `additionalProperties` in English. Matching
    /// this app's own description strings would work in English and nowhere else.
    ///
    /// `isRefusal` does not catch it. Its length test is deliberately limited to
    /// dictation, since a rewrite action is allowed to expand — translating and
    /// wrapping in HTML both do — which is exactly the licence this abuses.
    private static func leakedScaffolding(_ output: String) -> Bool {
        let keys = ["additionalProperties", "\"properties\"", "\"$schema\""]
        return keys.contains { output.contains($0) }
    }

    /// Whether the model talked *about* the text instead of rewriting it.
    ///
    /// Given something it can't make sense of, it doesn't fail — it explains:
    /// "I cannot rewrite this text because it appears to be a typo or corrupted
    /// input." That sentence was then pasted into the document in place of what
    /// was there, which is worse than doing nothing.
    ///
    /// Guessing at this from the text is unsatisfying, so the two principled
    /// routes were tried first and both lost.
    ///
    /// The framework does define `GenerationError.refusal` and
    /// `.guardrailViolation`, but they are for safety-policy blocks, not for
    /// this: over a run of deliberately unreadable inputs, zero errors were
    /// thrown and five refusals arrived as ordinary, successful content. As far
    /// as the API is concerned the model did its job.
    ///
    /// Guided generation does give a real typed flag — reachable on this
    /// toolchain via DynamicGenerationSchema, since the @Generable macro needs
    /// Xcode's plugin and build.sh uses plain swiftc. The flag is not worth
    /// having: it fired on one of six unreadable inputs and disagreed with itself
    /// across passes on the same input, "scasdassdfsadone" came back silently
    /// truncated to "sadone" with the flag clear, and forcing the schema lost the
    /// full stop off the end of most sentences — the very thing the instructions
    /// above exist to get right.
    ///
    /// Both signals are required, because either alone gets it wrong. Refusal
    /// phrasing catches real writing — "i cannot make it tomorrow sorry" tidies
    /// quite properly to "I cannot make it tomorrow. Sorry.", and so do "I am
    /// unable to attend the meeting" and "unfortunately the original message was
    /// lost". Low overlap catches real work too — "teh" becoming "the" keeps
    /// nothing, and stripping filler out of dictation keeps little. Together they
    /// separate cleanly: over the collected outputs, refusals kept none of the
    /// input's words while rewrites kept nearly all of them.
    private static func isRefusal(_ output: String, for input: String,
                                  ) -> Bool {
        let markers = ["cannot rewrite", "can't rewrite", "cannot assist", "can't assist",
                       "cannot process", "can't process", "cannot help", "can't help",
                       "unable to rewrite", "unable to process", "cannot determine",
                       "can't determine", "please provide", "different request",
                       "ready to assist", "does not contain", "no meaningful",
                       "random characters", "random sequence", "corrupted input",
                       "cannot fulfill", "can't fulfill", "does not correspond",
                       "recognized term", "not a word", "no recognized"]
        let lower = output.lowercased()
        guard markers.contains(where: { lower.contains($0) }) else { return false }

        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        // A refusal sometimes quotes the text back at you — "I cannot rewrite the
        // text "xkcd flurb wozzle" as it does not contain meaningful content" —
        // and the quoted copy would otherwise read as the input having survived,
        // which let exactly that one through. Quoted material is the model citing,
        // not rewriting, so it doesn't count towards survival.
        func unquoted(_ s: String) -> String {
            var out = "", inside = false
            for c in s {
                if c == "\"" || c == "\u{201C}" || c == "\u{201D}" { inside.toggle(); continue }
                if !inside { out.append(c) }
            }
            return out
        }
        let before = words(input)
        // No words to compare against — the input was symbols or punctuation. The
        // old guard called that "not a refusal", which is backwards: prose coming
        // back from an input with no words in it can only be the model talking
        // about it, and that sentence was pasted over the symbol.
        guard !before.isEmpty else { return true }
        let after = words(unquoted(output))
        return Double(before.filter { after.contains($0) }.count) / Double(before.count) < 0.5
    }

    /// How long a rewrite gets before this app gives up on it and says so.
    ///
    /// The model call has no timeout of its own, so before this existed the only
    /// backstop was a 20s watchdog that reset the reentrancy flag without telling
    /// the HUD anything — the pill just sat on "processing" until something else
    /// happened to supersede it. Worse, that watchdog's own doc comment called
    /// 20s "long enough not to fire during a normal rewrite," and that turned out
    /// to be false: measured directly against this machine's on-device model, a
    /// short selection answers in under a second, but a ~3,600-character one took
    /// 27s in one run against 14s for a ~6,600-character one in another. The
    /// spread is real, not an artifact of size alone, so the number has to be
    /// generous rather than tight. Forty-five seconds clears everything measured
    /// with real headroom, while still being a wait a person notices rather than
    /// nothing happening forever.
    ///
    /// Verified directly, not assumed: cancelling the Task mid-flight throws
    /// CancellationError out of `session.respond` and the call actually stops —
    /// this is a real cancellation, not a timeout that walks away while the
    /// model keeps working unseen. Racing a task and only ever *reading* its
    /// result without cancelling it does not stop it; a stray success from that
    /// abandoned work arriving later and pasting into whatever is now focused was
    /// the failure mode worth designing out here, not just the visible hang.
    private static let rewriteTimeout: TimeInterval = 45

    /// Run `text` through Apple Intelligence's on-device model with the saved
    /// instructions. Nothing leaves the Mac. `done` is called on the main queue,
    /// with nil if the model is unavailable or refuses, and `timedOut` true only
    /// when `rewriteTimeout` above is what ended it.
    /// By default the model is asked to fill a field rather than answer in
    /// prose, which is what stops refusals: there is nowhere in a `text` field to
    /// say "I cannot rewrite this". `prose` opts back out, and Clean Dictation is
    /// the one action that does. Measured: the same speech came back through the
    /// field as "I drove to the office and it was really busy so yeah", with no
    /// final stop and a quarter of the commas, where prose punctuated it
    /// properly. Punctuation is most of what cleaning up dictation is.
    func rewriteText(_ text: String, instructions: String, prose: Bool = false,
                     done: @escaping (_ result: String?, _ timedOut: Bool) -> Void) {
        guard case .available = SystemLanguageModel.default.availability else {
            DispatchQueue.main.async { done(nil, false) }
            return
        }
        let work = Task<String?, Never> {
            var output: String?
            do {
                // Firm framing: without it the model tends to answer the text
                // rather than rewrite it.
                //
                // Asked for a filled-in field rather than bare prose, which is
                // what stops the refusals: there is nowhere in a `text` field to
                // say "I cannot rewrite this". Measured over two passes, the same
                // input that used to come back as "I cannot rewrite this text
                // because it appears to be corrupted" is simply rewritten, and
                // bullets survive where they were being flattened to dashes.
                // Handy (github.com/cjpais/Handy) uses @Generable for this; the
                // schema is built at runtime here instead, because that macro
                // needs a plugin that ships with Xcode and this builds with the
                // Command Line Tools alone.
                //
                // Wrapping the text in <text> tags was also tried and measured
                // worse — "100°F" came back as "I cannot fulfill this request…
                // unsafe instructions involving extreme temperatures".
                let framing = instructions +
                    "\n\nOutput only the rewritten text. Do not answer it, explain, or comment on it."
                let prompt = "Rewrite this text:\n\n" + text

                var filled: String?
                if !prose, let schema = Self.rewriteSchema {
                    let session = LanguageModelSession(instructions: framing)
                    if let answer = try? await session.respond(to: prompt, schema: schema) {
                        filled = try? answer.content.value(String.self, forProperty: "text")
                    }
                }
                // A filled field is not necessarily a clean one. The framework
                // renders the schema into the prompt as text, and an instruction
                // that applies to everything in view — "translate to Spanish" is
                // the one that found this — applies to that text too. The model
                // then translates its own output format and puts the result in
                // the field, which is structurally valid and useless. Fall
                // through to the prose path, which has no schema to leak.
                if let leak = filled, Self.leakedScaffolding(leak) { filled = nil }
                if let filled {
                    output = filled.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    // Older behaviour, kept as a fallback: if the schema can't be
                    // built or the model won't fill it, a plain answer is better
                    // than none — isRefusal still guards what comes back.
                    //
                    // On its own session, always. A session keeps a transcript,
                    // and asking for a schema puts the framework's own scaffolding
                    // in it — "Response using compact JSON in a single line…
                    // Adhere to the following format: {…}". Reusing the session
                    // here let the model answer from that context instead of the
                    // instructions: measured on the same input, the reused session
                    // returned {"text": "I believe I can dictate here"} where a
                    // fresh one returned the sentence. In Zed it pasted the
                    // scaffolding itself into the document, after the rewrite.
                    let session = LanguageModelSession(instructions: framing)
                    output = try await session.respond(to: prompt).content
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                output = nil
            }
            // A refusal is a valid-looking string, so it has to be caught here or
            // it gets pasted over the user's text as though it were the rewrite.
            // nil is the existing "couldn't do it" signal: the HUD says so and the
            // text is left alone.
            var result = output
            if let out = result, Self.isRefusal(out, for: text) { result = nil }
            return result?.isEmpty == false ? result : nil
        }

        // Cancel the real work at the deadline rather than merely stop waiting on
        // it — see the doc comment above for why that distinction is the whole
        // point. Cancelled outright, not raced with a plain sleep, so a result
        // that does slip through late is unambiguous: `work.isCancelled` is only
        // ever true when this timer, specifically, is what ended it.
        let giveUp = DispatchWorkItem { work.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rewriteTimeout, execute: giveUp)

        Task {
            let result = await work.value
            giveUp.cancel()   // no-op if it already fired; stops it firing late otherwise
            await MainActor.run { done(result, work.isCancelled && result == nil) }
        }
    }

    // MARK: Push-to-talk dictation

    /// Watch the chosen modifier so dictation runs only while it's held. Carbon
    /// hotkeys never report a release, so this uses flagsChanged monitors — the
    /// global one covers other apps, the local one covers our own windows.
    func syncDictationMonitor() {
        for m in holdMonitors { NSEvent.removeMonitor(m) }
        holdMonitors = []
        if dictating { stopDictation() }

        let hold = UserDefaults.standard.dictationHoldKey
        guard appEnabled,
              hold != .off, let code = hold.keyCode, let flag = hold.flag else { return }

        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == code else { return }
            // The flag is set while the key is down, clear once it's released.
            let down = event.modifierFlags.contains(flag)
            if down {
                // Back down inside the buffer: you let go too early, so carry on
                // as though you hadn't. See `scheduleDictationStop`.
                if let pending = self.pendingDictationStop {
                    pending.cancel()
                    self.pendingDictationStop = nil
                    // No HUD call: the meter never stopped, so there is nothing
                    // to restore and rebuilding the pill would only make it
                    // flicker at the moment you are trying to keep talking.
                    return
                }
                // Not while a rewrite still has the text: starting again here is
                // what let a pending paste land inside the new sentence.
                if !self.dictating && !self.rewriting { self.armDictation() }
            } else {
                self.disarmDictation()          // let go inside the dead zone: nothing happened
                if self.dictating { self.scheduleDictationStop() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: handle) {
            holdMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { e in handle(e); return e }) {
            holdMonitors.append(l)
        }
        // A key pressed during the dead zone means the modifier was part of a
        // chord, so stand down rather than starting to dictate.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] _ in
            self?.disarmDictation()
        }) { holdMonitors.append(g) }
    }

    // MARK: Rewrite Text — double-tap ⌃

    /// Watch for a double-tap of left ⌃, Rewrite Text's trigger. Tapping a
    /// modifier is an unusual gesture, so the detector errs on the side of not
    /// firing: a "tap" is a press and release of ⌃ with no other key, mouse or
    /// scroll event in between, and two taps must land within 0.4s. Any other
    /// input anywhere in that window breaks the sequence, so chords (⌃C, and
    /// ⌃A ⌃C in a row) and ⌃-clicks never fire a rewrite by accident.
    ///
    /// Global monitors only: taps while Pullcord's own windows are in front
    /// are ignored, since there is no foreign selection to rewrite.
    func syncRewriteTapMonitor() {
        for m in rewriteTapMonitors { NSEvent.removeMonitor(m) }
        rewriteTapMonitors = []
        rewriteTapDown = false
        rewriteTapChord = false
        rewriteTapFirst = nil
        guard appEnabled else { return }

        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == CGKeyCode(kVK_Control) else { return }
            let down = event.modifierFlags.contains(.control)
            if down {
                self.rewriteTapDown = true
                self.rewriteTapChord = false
            } else {
                guard self.rewriteTapDown else { return }
                self.rewriteTapDown = false
                guard !self.rewriteTapChord else { self.rewriteTapChord = false; return }
                let now = Date()
                if let first = self.rewriteTapFirst,
                   now.timeIntervalSince(first) <= 0.4 {
                    self.rewriteTapFirst = nil
                    self.triggerRewriteTap()
                } else {
                    self.rewriteTapFirst = now
                }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: handle) {
            rewriteTapMonitors.append(g)
        }
        // Any other input breaks a tap in progress (a chord key like ⌃C, a
        // ⌃-click, a ⌃-scroll) — and un-pairs a waiting first tap, so two
        // chords in quick succession don't read as a double-tap.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown,
                                                                .otherMouseDown, .scrollWheel],
                                                     handler: { [weak self] _ in
            guard let self else { return }
            if self.rewriteTapDown { self.rewriteTapChord = true }
            self.rewriteTapFirst = nil
        }) { rewriteTapMonitors.append(g) }
    }

    private func triggerRewriteTap() {
        // Same gates as the hotkeys the tap replaces: not while recording a
        // shortcut, not while synthesizing, and not while dictation or another
        // rewrite owns the field. rewriteSelection itself checks Accessibility.
        guard !recording, !synthesizing, !rewriting, !dictating else { return }
        rewriteSelection()
    }

    /// Press the frontmost app's Edit ▸ Start/Stop Dictation item over the
    /// Accessibility API. The mic key itself can't be synthesized — macOS takes it
    /// at the HID layer, so it never becomes an event we can post — and by default
    /// dictation has no ordinary shortcut to send either. Driving the menu item
    /// leaves your own dictation setup exactly as it is.
    @discardableResult
    private func pressDictationMenuItem(starting: Bool) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef, CFGetTypeID(menuBar) == AXUIElementGetTypeID()
        else { return false }

        // Depth-first through the menu bar for the dictation item. Matching on a
        // "dictation" substring keeps it working when the wording shifts.
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 4 { return nil }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return nil }
            for child in children {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String)?.lowercased() ?? ""
                if title.contains("dictation") {
                    let wantsStop = title.contains("stop")
                    if wantsStop != starting { return child }
                }
                if let hit = search(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        guard let item = search(menuBar as! AXUIElement, depth: 0) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Puts the cursor in System Settings' search field by pressing that app's
    /// own View ▸ Search item.
    ///
    /// Not a synthesised ⌘F. `openApplication` is asynchronous, so a keystroke
    /// fired on a timer can land wherever the frontmost app happens to be, and
    /// ⌘F is Find almost everywhere — the failure mode is opening a find bar in
    /// somebody's editor. Addressing the menu item by pid can only ever reach
    /// System Settings, no matter how slow the launch.
    ///
    /// Matched on the key equivalent rather than the word "Search": the title is
    /// localised, the shortcut is not. AXMenuItemCmdModifiers of 0 means ⌘ alone.
    ///
    /// Best effort throughout. No Accessibility, a renamed attribute, a future
    /// System Settings that drops the item — all of them just mean the window
    /// opens the way it always did.
    /// Focusing the search field also drops a suggestions overlay under it. One
    /// Escape closes the overlay and leaves the caret where it is, which is the
    /// state you actually want on arrival: an empty field, nothing covering the
    /// pane behind it, ready to type.
    ///
    /// The delay is for the overlay, not the focus — it appears a beat after the
    /// menu item is pressed, and an Escape that arrives first would have nothing
    /// to close. Landing early is harmless either way: Escape in the search field
    /// with no overlay leaves focus exactly where it was, which is why this is a
    /// fixed short delay rather than a poll for something the overlay does not
    /// expose to Accessibility.
    ///
    /// Guarded on System Settings still being frontmost, because unlike the
    /// menu-item press this *is* a synthetic keystroke and goes wherever the
    /// user is. If they have already switched away, they get no stray Escape.
    private func dismissSettingsSearchSuggestions(in app: NSRunningApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == app.processIdentifier else { return }
            self?.post(CGKeyCode(kVK_Escape), [])
        }
    }

    private func focusSettingsSearch(in app: NSRunningApplication,
                                     deadline: Date = Date().addingTimeInterval(3)) {
        guard AXIsProcessTrusted() else { return }

        func commandF(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 4 { return nil }
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return nil }
            for child in children {
                var charRef: CFTypeRef?, modRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, "AXMenuItemCmdChar" as CFString, &charRef)
                AXUIElementCopyAttributeValue(child, "AXMenuItemCmdModifiers" as CFString, &modRef)
                if (charRef as? String)?.uppercased() == "F", (modRef as? Int) == 0 { return child }
                if let hit = commandF(child, depth: depth + 1) { return hit }
            }
            return nil
        }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var menuBarRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
           let menuBar = menuBarRef, CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
           let item = commandF(menuBar as! AXUIElement, depth: 0) {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            dismissSettingsSearchSuggestions(in: app)
            return
        }
        // A cold launch has no menu bar to walk yet. Poll rather than guess at a
        // single delay, and give up quietly at the deadline — the window is open
        // either way, which is the part that matters.
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.focusSettingsSearch(in: app, deadline: deadline)
        }
    }

    private func armDictation() {
        disarmDictation()
        dictationArmTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.dictationArmTimer = nil
            self?.startDictation()
        }
    }

    private func disarmDictation() {
        dictationArmTimer?.invalidate()
        dictationArmTimer = nil
    }

    private func startDictation() {
        // Distinguish the two failures: without Accessibility we can't read any
        // app's menus at all (a rebuild silently drops that trust), which looks
        // identical to an app that simply has no Dictation item.
        guard AXIsProcessTrusted() else {
            promptForAccessibility()   // macOS offers to open the pane
            hud.showMessage("Needs Accessibility", symbol: "exclamationmark.triangle.fill", tint: .systemRed)
            return
        }
        // Nothing checks whether the focus can take text. macOS makes no such
        // check when you press the dictation key, and this is meant to be that
        // key under a different finger. The probe that used to be here read
        // perfectly good fields as unusable and refused to start in apps where
        // dictation worked fine on its own.
        guard pressDictationMenuItem(starting: true) else {
            hud.showMessage("No Dictation menu here", symbol: "mic.slash.fill", tint: .systemRed)
            return
        }
        dictating = true
        // No pill. macOS puts up its own indicator the moment dictation starts,
        // and a second one saying the same thing is just a second thing on screen.
        // Errors above still speak, because those are the cases macOS says nothing
        // about.
    }

    /// A buffer for fingers moving faster than mouths.
    ///
    /// Two things want it. macOS keeps transcribing for a beat after you stop
    /// speaking, so stopping the instant the key comes up clips the last few
    /// words. And people let go early — a fraction before the sentence is
    /// actually finished — which would end dictation mid-thought.
    ///
    /// If the key goes back down inside the window, dictation carries on as if
    /// it never let up. That is the recovery for having released too soon, not a
    /// feature to reach for: the window is short and gives no sign it is open,
    /// so nobody can aim at it deliberately, and nothing in the UI suggests they
    /// should. It used to announce itself — first with an amber tint, then with
    /// the busy dots — and taught nobody anything either time.
    ///
    /// (Whether the trailing punctuation survives is macOS's business: it varies
    /// by app, and no amount of waiting here changes it.)
    ///
    /// One number, for everybody. This used to watch the field's text over
    /// Accessibility and stop as soon as nothing new had arrived for a moment —
    /// quicker in theory, and wrong in practice: in Notes it read a natural pause
    /// mid-sentence as "finished" and cut dictation off early. Reading the field
    /// to decide is the same fragility that took Auto-Correct down, and it earns
    /// less here, because the thing it was optimising was a second of waiting
    /// with the meter up.
    ///
    /// So: wait, always. One second covers what macOS has been seen to need
    /// while still feeling like a release rather than a hang — two was safe and
    /// read as lag. The words are already typed either way; all this decides is
    /// when the microphone closes and the meter goes.
    private func scheduleDictationStop(after grace: TimeInterval = 1.0) {
        pendingDictationStop?.cancel()
        // The meter stays up, deliberately. The microphone is still open and
        // macOS is still transcribing through this window — dictation has not
        // finished, so showing the busy dots here claimed the system had moved
        // on to processing when it hadn't. The dots mean the app is working on
        // something; this is still the app listening.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDictationStop = nil
            self.stopDictation()
        }
        pendingDictationStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }

    /// Claim the text for a rewrite's round trip. Every path that finishes with
    /// it — including the ones that give up — has to call `endRewriting`, or the
    /// hold key stays dead until `rewriteText`'s own timeout ends the call.
    private func beginRewriting() {
        rewriting = true
    }

    /// Safe to call when no tidy is in flight, so the shared paths can call it
    /// unconditionally rather than each having to know how they were reached.
    private func endRewriting() {
        rewriting = false
    }

    /// Stop, and nothing else.
    ///
    /// This used to finish by selecting the run just dictated and rewriting it
    /// in place — Auto-Correct. It came out because both pieces it stood on were
    /// unreliable: the diff that worked out which characters had been inserted,
    /// and the probe that decided whether a field could be read at all. Between
    /// them they over-selected in some apps and replaced text nobody had asked
    /// them to touch, and a wrong span is worse than no cleanup at all.
    ///
    /// So this is the dictation key now, on a key you can hold, and nothing
    /// more. Cleaning up is a separate and deliberate act: select what you want
    /// and run the Clean Dictation rewrite action, which carries the very same
    /// instructions Auto-Correct used to apply — over a span you chose rather
    /// than one that was guessed at.
    private func stopDictation() {
        dictating = false
        pendingDictationStop?.cancel()
        pendingDictationStop = nil
        // Prefer the app's own Stop item; fall back to Escape, which ends
        // dictation while keeping whatever has already been transcribed.
        if !pressDictationMenuItem(starting: false) { post(CGKeyCode(kVK_Escape), []) }
    }

    /// The focused text element — asking the frontmost app directly when the
    /// system-wide query comes back empty.
    ///
    /// Notes is why. It publishes nothing for kAXFocusedUIElement on the
    /// system-wide element, which is what "Notes exposes no focused element at
    /// all" meant everywhere in this file — but ask its *application* element the
    /// same question and it hands back an AXTextArea complete with its value and
    /// its selection range. Measured, not assumed.
    ///
    /// Without this the dictated run could only be guessed at with a word count,
    /// which over-selected, and a rewrite had to go through the clipboard.
    private func focusedTextElement() -> AXUIElement? {
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                         kAXFocusedUIElementAttribute as CFString,
                                         &focused) == .success,
           let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() {
            return (element as! AXUIElement)
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        var appFocused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                            kAXFocusedUIElementAttribute as CFString,
                                            &appFocused) == .success,
              let element = appFocused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    /// Read the selection straight out of the focused field, no ⌘C involved.
    ///
    /// Worth trying before the clipboard for the same reason as above: a copy is
    /// the frontmost app's write, so it can't be marked transient from here and
    /// turns up in clipboard history. Plenty of apps won't answer — Notes exposes
    /// no focused element at all — hence the fallback rather than a replacement.
    private func selectedTextViaAX() -> String? {
        guard let element = focusedTextElement() else { return nil }
        // Believe the range before the text. Some apps report the whole field as
        // kAXSelectedText when nothing is selected at all — Zed's panels among
        // them — and acting on that appends the rewrite instead of replacing it,
        // because there was never a selection for ⌘V to overwrite. A zero-length
        // range means no selection, whatever the text attribute claims.
        //
        // Only decisive when the app answers: plenty don't publish a range, and
        // those still fall through to the checks below.
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element,
                                         kAXSelectedTextRangeAttribute as CFString,
                                         &rangeRef) == .success,
           let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length == 0 {
                return nil
            }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            &value) == .success,
              let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Show the system color loupe (`NSColorSampler`), copy the picked color's
    /// code (the clipboard is text-only by design — see `copyColorCode`), and
    /// record it to Color History (which any open palette then refreshes). The
    /// sampler reads the screen out of process (no Screen Recording /
    /// Accessibility). A nil color (Esc) leaves everything untouched.
    ///
    /// `reopenHistory` is for picks started from the palette: it closes itself
    /// first (so it never floats while the loupe is up), and this brings it back
    /// once the pick finishes — including a canceled one.
    func sampleColor(reopenHistory: Bool = false) {
        NSColorSampler().show { [weak self] color in
            guard let self else { return }
            defer {
                if reopenHistory {
                    DispatchQueue.main.async { [weak self] in self?.openColorHistory() }
                }
            }
            guard let color else { return }
            let rgb = color.usingColorSpace(.sRGB) ?? color
            self.copyColorCode(rgb)
            ColorHistory.add(rgb)
            self.colorHistoryPanel?.reload()
        }
    }

    /// Copy a color's code (in the chosen format) to the clipboard, plus the raw
    /// `NSColor` for color wells, and flash the confirmation pill. Text + color
    /// only, no swatch image: macOS's clipboard history snapshots any image and
    /// re-offers it as a file URL on recall, so a swatch would make recalling a
    /// color paste a PATH instead of the code. (Color History is how you see past
    /// colors visually instead.)
    func copyColorCode(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let code = UserDefaults.standard.colorFormat.string(for: rgb)
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        let colorType = NSPasteboard.PasteboardType(rawValue: "com.apple.cocoa.pasteboard.color")
        if let colorData = rgb.pasteboardPropertyList(forType: colorType) as? Data {
            item.setData(colorData, forType: colorType)
        }
        pb.writeObjects([item])
        hud.showColor(code: code, color: rgb)
    }

    /// Toggle the floating Color History palette (the shortcut's action).
    func showColorHistory() {
        if let p = colorHistoryPanel, p.isVisible { p.close() } else { openColorHistory() }
    }

    /// Open (never toggle) the palette — used when reopening after a pick.
    func openColorHistory() {
        if colorHistoryPanel == nil { colorHistoryPanel = ColorHistoryPanel(appDelegate: self) }
        colorHistoryPanel?.reload()
        colorHistoryPanel?.center()
        NSApp.activate(ignoringOtherApps: true)
        colorHistoryPanel?.makeKeyAndOrderFront(nil)
    }

    /// Capture Text: the system's own crosshair region selector
    /// (`/usr/sbin/screencapture -i`) writes a PNG, which Vision OCRs; the text
    /// lands on the clipboard with a confirmation pill. screencapture reads the
    /// screen in its own process, so Pullcord needs no Screen Recording grant.
    /// A canceled selection (Esc) writes no file and is a silent no-op.
    func captureText() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pullcord-ocr-\(UUID().uuidString).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", url.path]   // interactive region, silent
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { try? FileManager.default.removeItem(at: url) }
                guard let data = try? Data(contentsOf: url),
                      let image = NSImage(data: data),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return }   // canceled — nothing written
                self.recognizeText(cg)
            }
        }
        do {
            try task.run()
        } catch {
            hud.showMessage("Couldn’t start capture", symbol: "exclamationmark.triangle.fill", tint: .systemRed)
        }
    }

    private func recognizeText(_ cg: CGImage) {
        // Recognition on a dense screenshot can run for seconds, and until now
        // nothing was on screen between letting go of the drag and the result —
        // long enough to look like the shortcut had missed. Sticky, so it holds
        // until the result morphs it into the count.
        hud.showProcessing()
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            // Preserve the OCR line breaks, or flow onto one line — the user's choice.
            let keep = UserDefaults.standard.ocrKeepLineBreaks
            let text = lines.joined(separator: keep ? "\n" : " ")
            DispatchQueue.main.async {
                guard let self else { return }
                guard !text.isEmpty else {
                    self.hud.showMessage("No text found", symbol: "text.viewfinder", tint: .systemRed)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                // Count lines when breaks are kept, words when they're removed.
                let n = keep ? lines.count : text.split { $0.isWhitespace }.count
                let unit = keep ? (n == 1 ? "line" : "lines") : (n == 1 ? "word" : "words")
                self.hud.showMessage("\(n) \(unit) copied", symbol: "text.viewfinder", tint: nil)
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        }
    }

    /// Toggle a power assertion that blocks sleep (what `caffeinate` does). Its
    /// type depends on the "Screen Sleep" option: keep the whole system awake,
    /// or keep it awake but still let the display sleep. Released automatically
    /// if Pullcord quits, so it can never orphan. No permission needed.
    @objc func toggleKeepAwake() {
        if keepAwakeAssertion != 0 {
            IOPMAssertionRelease(keepAwakeAssertion)
            keepAwakeAssertion = 0
        } else {
            createKeepAwakeAssertion()
        }
        let on = keepAwakeAssertion != 0
        updateKeepAwakeIndicator()
        hud.showMessage(on ? "Keep Awake On" : "Keep Awake Off", symbol: "mug.fill",
                        tint: on ? .systemGreen : .secondaryLabelColor)
    }

    /// Re-create the assertion with the current type if sleep is blocked — used
    /// when the "Screen Sleep" option is toggled while it's running.
    func reapplyKeepAwake() {
        guard keepAwakeAssertion != 0 else { return }
        IOPMAssertionRelease(keepAwakeAssertion)
        keepAwakeAssertion = 0
        createKeepAwakeAssertion()
    }

    private func createKeepAwakeAssertion() {
        let type = UserDefaults.standard.keepAwakeAllowDisplaySleep
            ? kIOPMAssertionTypePreventUserIdleSystemSleep    // system awake, display may sleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep   // display stays awake too
        var id: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Pullcord Keep Awake" as CFString, &id) == kIOReturnSuccess {
            keepAwakeAssertion = id
        }
    }

    /// A menu-bar cup that appears only while sleep is blocked (Pullcord is
    /// otherwise menu-bar-less) — a persistent indicator, click it to turn off.
    private func updateKeepAwakeIndicator() {
        if keepAwakeAssertion != 0 {
            guard keepAwakeStatusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let img = NSImage(systemSymbolName: "mug.fill", accessibilityDescription: "Keep Awake")
            img?.isTemplate = true
            item.button?.image = img
            item.button?.toolTip = "Pullcord Keep Awake is on — click to turn off"
            item.button?.target = self
            item.button?.action = #selector(toggleKeepAwake)
            keepAwakeStatusItem = item
        } else if let item = keepAwakeStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            keepAwakeStatusItem = nil
        }
    }

    /// ⌘Space, small gap, ⌘N — waiting first for the user to release the
    /// non-⌘ modifiers of their shortcut (a lingering ⇧ would turn ⌘4 into
    /// the ⌘⇧4 screenshot shortcut; ⌥/⌃ similarly corrupt the sequence, and
    /// fn is held whenever the shortcut used an F-key on a laptop keyboard).
    /// Timing learnings inherited from Key54's clipboard experiment:
    /// Spotlight buffers keys behind its ⌘Space, but a ~30 ms gap is needed
    /// for cold starts (1 ms was observed to miss).
    /// `trigger` is the key of the shortcut that fired, which has to be released
    /// before the sequence runs. Waiting only for the modifiers isn't enough: we
    /// park our own hotkeys while synthesizing, so a trigger key still held is no
    /// longer swallowed by us and its auto-repeat reaches whatever we just opened.
    /// With Clipboard on ⌃⌥⌘Return that meant Return landing in the panel —
    /// activating an entry and leaving it half-open.
    private func synthesizeSpotlight(then key: CGKeyCode, trigger: CGKeyCode? = nil,
                                     attempt: Int = 0) {
        guard hasAccessibility else {
            // Rather than silently doing nothing, ask — macOS shows the dialog
            // that leads straight to the setting.
            if attempt == 0 { promptForAccessibility() }
            return
        }
        var watch = [kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
                     kVK_Control, kVK_RightControl, kVK_Function].map { CGKeyCode($0) }
        if let trigger { watch.append(trigger) }
        let held = watch.contains { CGEventSource.keyState(.hidSystemState, key: $0) }
        if held {
            // Waiting on the user's fingers: people hold a chord for a long
            // beat when they expect something to appear, so give them 2 s
            // (80 × 25 ms) before quietly giving up, not a fraction of one.
            guard attempt < 80 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.synthesizeSpotlight(then: key, trigger: trigger, attempt: attempt + 1)
            }
            return
        }
        // ⌘Space is a toggle and there is no permission-free way to ask
        // whether Spotlight is already open (it never becomes the frontmost
        // app, the window list needs Screen Recording, and macOS 27 exposes
        // no Spotlight UI process). We deliberately do NOT guess: an earlier
        // "assume it's still open for a few seconds" heuristic turned every
        // quick successive press into a silent no-op. Always send the full
        // sequence; the rare cost is that a hotkey pressed while Spotlight
        // is already open closes it and the panel key reaches the previous
        // app. (When Spotlight is open it has focus — just press ⌘1–⌘4.)
        // Park our own hotkeys for the duration of the sequence (see the
        // `synthesizing` note above), then reconcile them back afterward.
        synthesizing = true
        syncHotkeys()
        post(CGKeyCode(kVK_Space), .maskCommand)
        // Undocumented escape hatch: `defaults write com.ethan.pullcord
        // panelDelay 0.08` if a machine needs longer between ⌘Space and ⌘N.
        // Clamped, because a stray value here would park the panel keys.
        let gap = (UserDefaults.standard.object(forKey: "panelDelay")
                   as? Double).map { min(max($0, 0), 1) } ?? 0.03
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            self?.post(key, .maskCommand)
        }
        // Spotlight reopens holding — and selecting — your last query, so a bare
        // Delete lands on that selection and empties the field. Deliberately NOT
        // ⌘A + Delete: if this sequence ever misfires into the frontmost app
        // (Spotlight was already open, so ⌘Space closed it), select-all + delete
        // would wipe that app's document. A stray Delete costs one character.
        DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.12) { [weak self] in
            self?.post(CGKeyCode(kVK_Delete), [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap + 0.3) { [weak self] in
            self?.synthesizing = false
            self?.syncHotkeys()
        }
    }

    /// Press ⌘ as a real key rather than only decorating the keystroke with
    /// `.maskCommand`. Decoration alone is enough for the keystroke itself, but
    /// it leaves the system believing ⌘ is still held afterwards — measured:
    /// after a decorated ⌘Space, `CGEventSource.flagsState` still reported
    /// `cmd`. The Delete this sequence sends 120 ms later therefore arrived
    /// inside a ⌘ that never came up, making it ⌘Delete rather than the bare
    /// Delete the code intends. Pressing and releasing the modifier gives a
    /// complete chord and leaves the modifier state clean for whatever runs
    /// next, synthesized or typed.
    private func post(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let wantsCommand = flags.contains(.maskCommand)
        let cmd = CGKeyCode(kVK_Command)
        func send(_ k: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: k,
                                  keyDown: down) else { return }
            e.flags = f
            e.post(tap: .cghidEventTap)
        }
        if wantsCommand { send(cmd, true, .maskCommand) }
        send(key, true, flags)
        send(key, false, flags)
        if wantsCommand { send(cmd, false, []) }
    }
}

// MARK: - Shortcut controls

/// A panel's single shortcut field: click to record (replacing any existing
/// binding). Bare Esc / Delete cancels; clearing is via the ✕. Only one
/// recorder captures at a time, and window close / focus loss cancels it —
/// otherwise the parked hotkeys stay parked.
final class RecorderButton: NSButton {
    /// nil for a recorder that belongs to an instruction set rather than a
    /// panel — it writes through `onSave` and claims no panel storage.
    let panel: Panel?
    /// Set for a non-panel recorder: called with the new binding, or nil to clear.
    var onSave: ((Shortcut?) -> Void)?
    var restingTitle: String
    private var monitor: Any?
    weak var appDelegate: AppDelegate?
    var onChange: (() -> Void)?
    private var onClear: (() -> Void)?
    private var clearButton: NSButton?
    private var hoverArea: NSTrackingArea?

    /// The one recorder currently capturing, if any.
    private(set) static weak var active: RecorderButton?

    init(panel: Panel?, appDelegate: AppDelegate?, restingTitle: String) {
        self.panel = panel
        self.appDelegate = appDelegate
        self.restingTitle = restingTitle
        super.init(frame: .zero)
        bezelStyle = .rounded
        font = .systemFont(ofSize: 11)
        title = restingTitle
        target = self
        action = #selector(beginRecording)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Add a ✕ at the field's right edge that clears the binding — revealed
    /// only while the pointer is over the field.
    func enableClear(_ handler: @escaping () -> Void) {
        onClear = handler
        let x = NSButton(frame: .zero)
        x.isBordered = false
        x.title = "✕"
        x.font = .systemFont(ofSize: 10, weight: .medium)
        x.contentTintColor = .tertiaryLabelColor
        x.toolTip = "Clear this shortcut."
        x.target = self
        x.action = #selector(clearTapped)
        x.isHidden = true
        addSubview(x)
        clearButton = x
        positionClear()
    }

    private func positionClear() {
        let s: CGFloat = 16
        clearButton?.frame = NSRect(x: bounds.maxX - s - 5, y: (bounds.height - s) / 2, width: s, height: s)
    }

    override func layout() { super.layout(); positionClear() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = hoverArea { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }

    override func mouseEntered(with event: NSEvent) { clearButton?.isHidden = false }
    override func mouseExited(with event: NSEvent) { clearButton?.isHidden = true }

    @objc private func clearTapped() { onClear?() }

    @objc private func beginRecording() {
        RecorderButton.active?.cancelRecording()   // one recorder at a time
        guard monitor == nil else { return }
        RecorderButton.active = self
        appDelegate?.recording = true
        title = "Type keys…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            defer { self.cancelRecording() }   // shared teardown for every branch

            var mods: UInt32 = 0
            let f = event.modifierFlags
            if f.contains(.command) { mods |= UInt32(cmdKey) }
            if f.contains(.shift) { mods |= UInt32(shiftKey) }
            if f.contains(.option) { mods |= UInt32(optionKey) }
            if f.contains(.control) { mods |= UInt32(controlKey) }
            let bare = mods & ~UInt32(shiftKey) == 0
            let code = UInt32(event.keyCode)

            // Bare Esc cancels; bare Delete clears the binding (no ✕ button).
            if bare && Int(event.keyCode) == kVK_Escape { return nil }
            if bare && [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
                if let panel = self.panel { Shortcut.save(nil, panel) } else { self.onSave?(nil) }
                return nil
            }
            // Return and Delete can't be bound at all. Return means "activate"
            // inside every panel these shortcuts open, so a press that outlives
            // the chord lands in the panel and leaves it half-open; Delete is
            // already the gesture for clearing a binding here.
            if [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Delete, kVK_ForwardDelete]
                .contains(Int(event.keyCode)) {
                NSSound.beep()
                return nil
            }
            // Chords need ⌘/⌥/⌃ so a bare letter can't hijack typing
            // system-wide — except F-keys, which exist to be pressed bare.
            guard !bare || fKeyCodes.contains(code) else {
                NSSound.beep()
                return nil
            }

            let sc = Shortcut(keyCode: code, modifiers: mods)
            // One chord belongs to one thing: recording a combo something else
            // already uses clears it there first — panels and instruction sets
            // share one keyboard, so they share one rule.
            for other in panels where other.defaultsKey != self.panel?.defaultsKey {
                if Shortcut.load(other) == sc { Shortcut.save(nil, other) }
            }
            if let panel = self.panel { Shortcut.save(sc, panel) } else { self.onSave?(sc) }
            // Synthesis panels need Accessibility — ask the moment the user
            // records a binding that will require it. An instruction set needs
            // it too: it reads and replaces the selection.
            if self.panel?.defaultsKey != "apps",
               let ad = self.appDelegate, !ad.hasAccessibility {
                ad.promptForAccessibility()
            }
            return nil   // swallow the keystroke
        }
    }

    /// Stop capturing. Safe to call redundantly.
    func cancelRecording() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        if RecorderButton.active === self { RecorderButton.active = nil }
        title = restingTitle
        appDelegate?.recording = false
        onChange?()
    }
}

// MARK: - Settings window

/// A view that reports when the system flips between light and dark. Layer
/// colors (`.cgColor`) are resolved once when they're set, so anything drawn
/// into a layer has to be rebuilt on the flip or it keeps the old theme's
/// colors until the app restarts.
class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Top-down coordinates, so the help overlay's scrolled content starts at the top.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class SettingsWindow: NSWindow, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private var banner: NSTextField?

    // Layout constants — the panels sit side by side, each in its own box.
    private let pad: CGFloat = 20
    // Vertical rhythm mirrored from Key54's settings window: a tall margin
    // under the transparent titlebar, fixed title/switch/description gaps, one
    // consistent section gap before and after the box row, and a Key54-sized
    // button bar.
    private let topMargin: CGFloat = 34
    private let titleTextH: CGFloat = 33
    private let titleSwitchGap: CGFloat = 10
    private let switchRowH: CGFloat = 28
    private let unitGap: CGFloat = 14
    private let descH: CGFloat = 20
    private let sectionGap: CGFloat = 18
    private let btnW: CGFloat = 100, btnH: CGFloat = 32
    private let bottomMargin: CGFloat = 20
    /// Gap between the groups and the button row; the (usually empty)
    /// conflict banner floats inside it rather than reserving its own band.
    private let footerGap: CGFloat = 22
    private var footerH: CGFloat { footerGap + btnH + bottomMargin }
    // Every card — Spotlight panel or System Tool — is the same width.
    private let boxW: CGFloat = 128
    private let boxGap: CGFloat = 12, innerPad: CGFloat = 11
    private let iconSize: CGFloat = 24
    private let headerBlockH: CGFloat = 46   // icon + title (no visible subtitle)
    private let itemH: CGFloat = 24, itemGap: CGFloat = 6
    // Grouping: Spotlight panels in one titled outline box, System Utilities in a
    // second one (same width) stacked below, its cards wrapping into rows.
    private let groupTitleH: CGFloat = 18, groupTitleGap: CGFloat = 6
    private let groupPad: CGFloat = 10
    private func groupWidth(_ w: CGFloat, _ count: Int) -> CGFloat {
        groupPad * 2 + w * CGFloat(count) + boxGap * CGFloat(count - 1)
    }
    private var group1W: CGFloat { groupWidth(boxW, spotlightPanels.count) }
    // The window is as wide as the Spotlight group; the other boxes match.
    private var winW: CGFloat { pad * 2 + group1W }
    private var contentW: CGFloat { winW - pad * 2 }
    private var spotlightPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { !isUtility($0.element) }.map { ($0.offset, $0.element) }
    }
    private var utilityPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { isUtility($0.element) && !isTextTool($0.element) }
            .map { ($0.offset, $0.element) }
    }
    private var textPanels: [(index: Int, panel: Panel)] {
        panels.enumerated().filter { isTextTool($0.element) }.map { ($0.offset, $0.element) }
    }
    /// Permission / Read & Speak state the current content was built for, so
    /// returning from System Settings rebuilds (and re-lights the strip) when any
    /// of them changed.
    /// The appearance the current content was built for, so a theme flip forces
    /// a rebuild (and nothing else does).
    private var builtAppearance: NSAppearance.Name?
    private var builtWithAX = true
    private var builtScreenRec = CGPreflightScreenCaptureAccess()
    private var builtSpoken = SpokenSelection.current
    private var helpButton: NSButton?
    /// The blue update strip only exists while an update is pending, so showing
    /// or hiding it changes the window height — hence a rebuild, not a redraw.
    private static let updateStripH: CGFloat = 28
    private var updateStatus: NSTextField?
    private var updateButton: NSButton?
    private var speakSetupWindow: SpeakSetupWindow?
    private var infoPopover: NSPopover?
    /// The About popover's version line, which doubles as the update check. Weak
    /// and re-set on every open — the popover is rebuilt from scratch each time, so
    /// a check still running when it closes must not write to a dead view.
    private weak var versionLabel: NSButton?
    private var instructionsWindow: InstructionsWindow?

    init(delegate: AppDelegate) {
        appDelegate = delegate
        // Updated width from 460 to 620 to account for the 5th panel
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 320),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = ""
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        self.delegate = self
        rebuild()
        installTitlebarHelpButton()
        center()
    }

    /// The help toggle, in the titlebar proper so it lines up with the window
    /// controls. A button placed in the content view can't: `fullSizeContentView`
    /// puts the content under the titlebar, and the titlebar view sits above it
    /// and takes the clicks. A titlebar accessory is the supported way in.
    private func installTitlebarHelpButton() {
        guard helpButton == nil else { return }
        let titlebarH: CGFloat = 28
        let size: CGFloat = 22
        let btn = NSButton(title: "", target: self, action: #selector(openMoreInfo(_:)))
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.contentTintColor = .secondaryLabelColor
        btn.frame = NSRect(x: 0, y: (titlebarH - size) / 2, width: size, height: size)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: size + 14, height: titlebarH))
        host.addSubview(btn)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        accessory.view = host
        addTitlebarAccessoryViewController(accessory)
        helpButton = btn
        syncHelpButton()
    }

    private func syncHelpButton() {
        helpButton?.image = NSImage(systemSymbolName: "info.circle",
                                    accessibilityDescription: "About Pullcord")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        helpButton?.toolTip = "About Pullcord"
    }

    /// Render the version line, optionally with a trailing status. Same 11 pt
    /// secondary style the plain label used, so the line doesn't shout — the
    /// pointing-hand cursor and the tooltip are what say it's clickable.
    private func setVersionLine(_ status: String?) {
        guard let btn = versionLabel else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let para = NSMutableParagraphStyle(); para.alignment = .center
        btn.attributedTitle = NSAttributedString(
            string: status.map { "Version \(version) · \($0)" } ?? "Version \(version)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: para])
    }

    /// Ask GitHub now, and report the answer on the line itself. When there *is* an
    /// update, the settings window's strip owns the actual Update button — saying
    /// so here rather than offering a second way to trigger it keeps one path.
    @objc private func checkForUpdatesNow(_ sender: NSButton) {
        setVersionLine("Checking…")
        appDelegate?.checkForUpdate { [weak self] reachable in
            guard let self else { return }
            guard reachable else { setVersionLine("Couldn't check"); return }
            switch appDelegate?.updateState ?? .upToDate {
            case .upToDate: setVersionLine("Up to date")
            default:        setVersionLine("Update available")
            }
        }
    }

    @objc private func openMoreInfo(_ sender: NSButton) {
        let content = MoreInfo.makeContent(target: self,
                                           guide:   #selector(openHelpDoc),
                                           website: #selector(openWebsite),
                                           issues:  #selector(openIssues),
                                           coffee:  #selector(openTipJar),
                                           star:    #selector(openRepo),
                                           check:   #selector(checkForUpdatesNow(_:)))
        versionLabel = content.viewWithTag(MoreInfo.versionTag) as? NSButton
        setVersionLine(nil)
        let vc = NSViewController()
        vc.view = content
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = vc.view.frame.size
        pop.behavior = .transient       // clicking anywhere else puts it away
        infoPopover = pop
        // Below the button: it sits at the top-right of the titlebar, so the
        // window is the only direction with room.
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func openLink(_ url: String) {
        guard let u = URL(string: url) else { return }
        infoPopover?.performClose(nil)
        NSWorkspace.shared.open(u)
    }
    @objc private func openHelpDoc() { openLink(MoreInfo.helpURL) }
    @objc private func openWebsite() { openLink(MoreInfo.siteURL) }
    @objc private func openIssues()  { openLink(MoreInfo.issuesURL) }
    @objc private func openRepo()    { openLink(MoreInfo.repoURL) }
    @objc private func openTipJar()  { openLink(MoreInfo.tipURL) }

    /// Recreate the whole content from the current shortcuts, so rows grow and
    /// shrink as bindings are added or removed. Called on init and after any
    /// add/remove.
    func rebuild() {
        // Layer colors (.cgColor) resolve against NSAppearance.current, which
        // outside a draw cycle is the app default — not this window's appearance.
        // Building inside the window's own drawing appearance is what makes the
        // dark/light colors come out right, and what makes a rebuild after a
        // theme change actually change anything.
        effectiveAppearance.performAsCurrentDrawingAppearance { self.rebuildContent() }
    }

    private func rebuildContent() {
        RecorderButton.active?.cancelRecording()

        // ── Measure ────────────────────────────────────────────────────────
        // Spotlight cards are a header over a single shortcut field. The tool
        // cards add a self-labeled option menu below the field. Cards in a group
        // share a height; the two stacked groups size to their own tallest column.
        var columnHeights: [CGFloat] = []
        for panel in panels {
            let items = 1 + optionRows(panel)   // shortcut field (+ option rows)
            columnHeights.append(headerBlockH + CGFloat(items) * itemH + CGFloat(items - 1) * itemGap)
        }
        func maxColumn(_ list: [(index: Int, panel: Panel)]) -> CGFloat {
            list.map { columnHeights[$0.index] }.max() ?? headerBlockH
        }
        let spotCardH = maxColumn(spotlightPanels) + innerPad * 2
        // System and text cards share a height, so the two boxes line up.
        let toolCardH = max(maxColumn(utilityPanels), maxColumn(textPanels)) + innerPad * 2
        let spotGroupBoxH = groupPad * 2 + spotCardH
        let utilGroupBoxH = groupPad * 2 + toolCardH
        let textGroupBoxH = groupPad * 2 + toolCardH
        let spotGroupH = groupTitleH + groupTitleGap + spotGroupBoxH
        let utilGroupH = groupTitleH + groupTitleGap + utilGroupBoxH
        let textGroupH = groupTitleH + groupTitleGap + textGroupBoxH
        let groupsH = spotGroupH + sectionGap + utilGroupH + sectionGap + textGroupH

        // Both permissions just light the bottom strip; neither blocks the
        // controls — macOS prompts for each on demand when a shortcut first
        // needs it (Accessibility for the synthesized panels, Screen Recording
        // the first time Capture Text runs).
        let hasAX = appDelegate?.hasAccessibility ?? AXIsProcessTrusted()
        let hasScreenRec = CGPreflightScreenCaptureAccess()
        builtWithAX = hasAX
        builtScreenRec = hasScreenRec
        builtSpoken = SpokenSelection.current

        let switchBlockH = titleSwitchGap + switchRowH + unitGap + descH
        let hdrH = topMargin + titleTextH + switchBlockH + sectionGap
        // The update strip is a band below the button row, present only when
        // there is something to announce.
        let showUpdate = (appDelegate?.updateState ?? .upToDate) != .upToDate
        let updH = showUpdate ? Self.updateStripH : 0
        let H = hdrH + groupsH + footerH + updH
        // Never taller than the screen can show. Twelve cards in three groups
        // plus the header and the button row want ~700 pt, and the update strip
        // adds to that — fine on this Mac, not fine on a 720 pt display or a
        // heavily scaled laptop, where the bottom of the window (Quit, Done, and
        // the update strip itself) would simply be unreachable. Whatever doesn't
        // fit scrolls; when it all fits the scroll view never appears and
        // nothing looks any different.
        let visibleH = (screen ?? NSScreen.main)?.visibleFrame.height ?? H
        let needsScroll = H > visibleH
        let windowH = min(H, visibleH)
        // A legacy (always-visible) scroller takes real width. Widen the window
        // by exactly that much rather than letting it eat into the content, so
        // the card columns stay where they are and nothing reflows.
        let scrollerW: CGFloat = needsScroll
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let keepTop: CGFloat? = isVisible ? frame.maxY : nil
        setContentSize(NSSize(width: winW + scrollerW, height: windowH))
        if let top = keepTop { setFrameTopLeftPoint(NSPoint(x: frame.minX, y: top)) }

        let v = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: winW, height: H))
        builtAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        v.onAppearanceChange = { [weak self] in
            guard let self,
                  self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != self.builtAppearance
            else { return }
            DispatchQueue.main.async { self.rebuild() }
        }

        let enabled = appDelegate?.appEnabled ?? true
        var yTop = H - topMargin

        yTop -= titleTextH
        let titleLabel = NSTextField(labelWithString: "Pullcord")
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: pad, y: yTop, width: winW - pad * 2, height: titleTextH)
        v.addSubview(titleLabel)

        yTop -= titleSwitchGap + switchRowH
        let sw = NSSwitch()
        sw.state = enabled ? .on : .off
        sw.target = self
        sw.action = #selector(appEnabledChanged(_:))
        sw.frame = NSRect(origin: .zero, size: sw.intrinsicContentSize)
        let swW = ceil(sw.frame.width), swH = ceil(sw.frame.height)
        let capLabel = NSTextField(labelWithString: enabled ? "Enabled" : "Disabled")
        capLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        capLabel.textColor = enabled ? .labelColor : .secondaryLabelColor
        capLabel.sizeToFit()
        let capW = ceil(capLabel.frame.width), capH = ceil(capLabel.frame.height)
        let swGap: CGFloat = 8
        let groupX = (winW - (capW + swGap + swW)) / 2
        let switchTip = enabled
            ? "Shortcuts are live and Pullcord starts at login. Off releases both."
            : "No shortcuts fire and Pullcord won't start at login. On restores both."
        capLabel.toolTip = switchTip
        sw.toolTip = switchTip
        capLabel.frame = NSRect(x: groupX, y: yTop + (switchRowH - capH) / 2, width: capW, height: capH)
        v.addSubview(capLabel)
        sw.frame = NSRect(x: groupX + capW + swGap, y: yTop + (switchRowH - swH) / 2, width: swW, height: swH)
        v.addSubview(sw)

        yTop -= unitGap + descH
        addPermissionPill(hasAX: hasAX, hasScreenRec: hasScreenRec, rowY: yTop, rowH: descH, in: v)

        let onChange: () -> Void = { [weak self] in
            self?.appDelegate?.syncHotkeys()
            self?.rebuild()
        }
        let contentTop = H - hdrH

        // ── Three titled outlines, stacked: Spotlight, System, Text ──
        // Lay out one panel's card at the given left edge / top.
        func layoutCard(_ i: Int, _ panel: Panel, cardX: CGFloat, cardTop: CGFloat, cardH: CGFloat) {
            let bx = cardX
            let cardW = boxW
            let colW = cardW - innerPad * 2

            // The column card — fill only; the group outline carries the border.
            let card = NSView(frame: NSRect(x: bx, y: cardTop - cardH, width: cardW, height: cardH))
            card.wantsLayer = true
            card.layer?.cornerRadius = 8
            // No fill of its own: the group's well is the one surface. Filled
            // cards inside a filled well is a box in a box, twelve times over.
            card.layer?.backgroundColor = NSColor.clear.cgColor
            card.alphaValue = enabled ? 1 : 0.5
            v.addSubview(card)

            let cx = bx + innerPad
            let top = cardTop - innerPad

            // Icon + title only, keeping each box clean. The icon says in one
            // line what the tool is for; the long version is in Help.
            let icon = NSImageView(frame: NSRect(x: cx + (colW - iconSize) / 2, y: top - iconSize, width: iconSize, height: iconSize))
            configureIcon(icon, panel, dimmed: !enabled)
            icon.toolTip = panel.detail

            v.addSubview(icon)

            let name = NSTextField(labelWithString: panel.name)
            // A name too wide for the fixed card ("System Settings") steps down a
            // point or two rather than truncating.
            var titleSize: CGFloat = 13
            while titleSize > 10,
                  (panel.name as NSString).size(withAttributes: [
                      .font: NSFont.systemFont(ofSize: titleSize, weight: .semibold)]).width > colW {
                titleSize -= 0.5
            }
            name.font = .systemFont(ofSize: titleSize, weight: .semibold)
            name.alignment = .center
            name.textColor = enabled ? .labelColor : .tertiaryLabelColor
            name.frame = NSRect(x: cx, y: top - iconSize - 20, width: colW, height: 17)
            v.addSubview(name)

            var lineTop = top - headerBlockH

            /// A shortcut box that isn't yours to edit: the same muted, disabled
            /// bezel as an empty recorder, but with the label drawn on top at full
            /// strength. A disabled NSButton dims its own title too, and that read
            /// as "this tool is switched off" rather than "this is set elsewhere",
            /// which is the opposite of what the box is saying.
            func readOnlyShortcut(_ text: String, opens action: Selector) {
                let box = NSButton(title: "", target: nil, action: nil)
                box.bezelStyle = .rounded
                box.isEnabled = false          // display only — the muted bezel says so
                box.frame = NSRect(x: cx, y: lineTop - itemH, width: colW, height: itemH)
                v.addSubview(box)

                let caption = NSTextField(labelWithString: text)
                caption.font = .systemFont(ofSize: 11)
                caption.alignment = .center
                caption.textColor = enabled ? .labelColor : .tertiaryLabelColor
                caption.sizeToFit()
                let h = ceil(caption.frame.height)
                caption.frame = NSRect(x: cx, y: lineTop - itemH + (itemH - h) / 2,
                                       width: colW, height: h)
                v.addSubview(caption)

                // The box still opens the window that sets it — a disabled button
                // can't take a click, so a transparent one lies over the top and
                // carries the action while the muted bezel keeps saying "not here".
                let hit = NSButton(title: "", target: self, action: action)
                hit.isBordered = false
                hit.isEnabled = enabled
                hit.frame = box.frame
                v.addSubview(hit)
            }

            if usesHoldKey(panel) {
                // Held rather than recorded, so the shortcut column offers the
                // choice outright. This used to be a read-only readout that
                // opened a settings window; once Auto-Correct went, the hold key
                // was the only thing left in there, and a window for one popup is
                // not worth opening.
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: HoldKey.menuOrder.map(\.label))
                popup.selectItem(at: HoldKey.menuOrder.firstIndex(
                    of: UserDefaults.standard.dictationHoldKey) ?? 0)
                popup.isEnabled = enabled
                popup.controlSize = .small
                popup.font = .systemFont(ofSize: 11)
                popup.target = self
                popup.action = #selector(holdKeyChanged(_:))
                popup.toolTip = "Hold it to dictate, let go to stop."
                popup.frame = NSRect(x: cx, y: lineTop - itemH, width: colW, height: itemH)
                v.addSubview(popup)
            } else if mirrorsMacOSHotkey(panel) {
                // Read-only mirror of the macOS "Speak selection" shortcut: unlike
                // the editable recorders it's set in Read & Speak, behind the
                // Configure… button.
                let spoken = SpokenSelection.current
                readOnlyShortcut(spoken.enabled ? (spoken.shortcut ?? "On") : "Not Set Up",
                                 opens: #selector(openSpeakSetup))
            } else if usesTapKey(panel) {
                // Triggered by double-tapping ⌃ rather than a recorded shortcut,
                // so this reads out the tap instead of offering a field. The box
                // opens the rewrite actions, the one thing to configure.
                readOnlyShortcut("Tap ⌃ Twice", opens: #selector(editRewriteActions))
            } else {
                // The single shortcut field, directly under the header. Click to
                // record — replacing any current binding — or press Delete while
                // recording to clear it.
                let sc = Shortcut.load(panel)
                let field = RecorderButton(panel: panel, appDelegate: appDelegate,
                                           restingTitle: sc?.label ?? "Set Shortcut")
                field.alignment = .center
                field.isEnabled = enabled
                field.onChange = onChange
                field.frame = NSRect(x: cx, y: lineTop - itemH, width: colW, height: itemH)
                v.addSubview(field)
                // A hover-revealed ✕ to clear the binding (only when one is set).
                if sc != nil && enabled {
                    field.enableClear { [weak self] in
                        Shortcut.save(nil, panel); self?.appDelegate?.syncHotkeys(); self?.rebuild()
                    }
                }
            }
            lineTop -= (itemH + itemGap)

            // Tool option below the shortcut. Settings and Capture Text use a
            // checkbox; Color Picker uses a select menu (its copy format).
            func centeredCheckbox(_ title: String, on: Bool, action: Selector, tip: String) {
                let check = NSButton(checkboxWithTitle: title, target: self, action: action)
                check.state = on ? .on : .off
                check.isEnabled = enabled
                check.toolTip = tip
                check.font = .systemFont(ofSize: 11)
                check.sizeToFit()
                let w = ceil(check.frame.width)
                check.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                v.addSubview(check)
            }
            if panel.defaultsKey == "settings" {
                centeredCheckbox("Smart Toggle", on: UserDefaults.standard.settingsToggle,
                                 action: #selector(smartToggleChanged(_:)),
                                 tip: "Opens into the search field, ready to type. Press again to go back where you were.")
            }
            if panel.defaultsKey == "textcapture" {
                centeredCheckbox("Remove Breaks", on: !UserDefaults.standard.ocrKeepLineBreaks,
                                 action: #selector(removeBreaksChanged(_:)),
                                 tip: "Flow the captured text onto one line.")
            }
            if panel.defaultsKey == "keepawake" {
                centeredCheckbox("Screen Sleep", on: UserDefaults.standard.keepAwakeAllowDisplaySleep,
                                 action: #selector(screenSleepChanged(_:)),
                                 tip: "Let the display sleep while everything else stays awake.")
            }
            if panel.defaultsKey == "colorhistory" {
                let btn = NSButton(title: "View…", target: self, action: #selector(viewColorHistoryTapped))
                btn.toolTip = "Open the Color History palette."
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = .systemFont(ofSize: 11)
                btn.isEnabled = enabled
                btn.sizeToFit()
                let w = ceil(btn.frame.width)
                btn.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                v.addSubview(btn)
            }
            if panel.defaultsKey == "speakclipboard" {
                // Always "Configure…", never "Change…": the window behind it is the
                // same three steps either way, and a label that changes with
                // state just makes you wonder what you missed.
                let btn = NSButton(title: "Configure…", target: self, action: #selector(openSpeakSetup))
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = .systemFont(ofSize: 11)
                btn.isEnabled = enabled
                btn.toolTip = "Show how to turn on Speak selection."
                btn.sizeToFit()
                let w = ceil(btn.frame.width)
                btn.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                v.addSubview(btn)
            }

            if panel.defaultsKey == "rewrite" {
                let btn = NSButton(title: "Settings", target: self,
                                   action: #selector(editRewriteActions))
                btn.toolTip = "Add and edit rewrite actions."
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = .systemFont(ofSize: 11)
                btn.isEnabled = enabled
                btn.sizeToFit()
                let w = min(ceil(btn.frame.width), colW)
                btn.frame = NSRect(x: cx + (colW - w) / 2, y: lineTop - itemH, width: w, height: itemH)
                v.addSubview(btn)
            }
            if panel.defaultsKey == "colorpicker" {
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: ColorFormat.allCases.map(\.label))
                popup.selectItem(at: UserDefaults.standard.colorFormat.rawValue)
                popup.isEnabled = enabled
                popup.controlSize = .small
                popup.font = .systemFont(ofSize: 11)
                popup.target = self
                popup.action = #selector(colorFormatChanged(_:))
                popup.toolTip = "The format your picks are copied in."
                // Size to its widest label and center it, like the checkboxes.
                popup.sizeToFit()
                let pw = min(ceil(popup.frame.width), colW)
                popup.frame = NSRect(x: cx + (colW - pw) / 2, y: lineTop - itemH, width: pw, height: itemH)
                v.addSubview(popup)
            }
        }

        // Spotlight Panels — full width, on top.
        let g1Box = addGroup("Spotlight Panels", x: pad, width: group1W,
                             top: contentTop, boxH: spotGroupBoxH, dimmed: !enabled, in: v)
        let cardTop1 = g1Box.maxY - groupPad
        for (slot, entry) in spotlightPanels.enumerated() {
            layoutCard(entry.index, entry.panel,
                       cardX: g1Box.minX + groupPad + CGFloat(slot) * (boxW + boxGap),
                       cardTop: cardTop1, cardH: spotCardH)
        }

        // Each group is one centered row of cards, stacked with a gap between.
        func layoutRow(_ entries: [(index: Int, panel: Panel)], in box: NSRect, cardH: CGFloat) {
            let clusterW = CGFloat(entries.count) * boxW + CGFloat(entries.count - 1) * boxGap
            let startX = box.minX + (group1W - clusterW) / 2
            for (i, entry) in entries.enumerated() {
                layoutCard(entry.index, entry.panel,
                           cardX: startX + CGFloat(i) * (boxW + boxGap),
                           cardTop: box.maxY - groupPad, cardH: cardH)
            }
        }

        // System Utilities.
        let g2Top = contentTop - spotGroupH - sectionGap
        let g2Box = addGroup("System Utilities", x: pad, width: group1W,
                             top: g2Top, boxH: utilGroupBoxH, dimmed: !enabled, in: v)
        layoutRow(utilityPanels, in: g2Box, cardH: toolCardH)

        // Text Tools.
        let g3Top = g2Top - utilGroupH - sectionGap
        let g3Box = addGroup("Text Tools", x: pad, width: group1W,
                             top: g3Top, boxH: textGroupBoxH, dimmed: !enabled, in: v)
        layoutRow(textPanels, in: g3Box, cardH: toolCardH)

        // Footer: the conflict banner across the top, Quit (left) + Done (right).
        let bannerField = NSTextField(wrappingLabelWithString: "")
        bannerField.font = .systemFont(ofSize: 11)
        bannerField.textColor = .systemOrange
        bannerField.alignment = .center
        bannerField.frame = NSRect(x: pad, y: updH + bottomMargin + btnH + 8, width: winW - pad * 2, height: 20)
        v.addSubview(bannerField)
        banner = bannerField

        let quit = NSButton(title: "Quit", target: self, action: #selector(forceQuit))
        quit.bezelStyle = .rounded
        quit.contentTintColor = .systemRed
        quit.toolTip = "Stop background agent until restart/login."
        quit.frame = NSRect(x: pad, y: updH + bottomMargin, width: btnW, height: btnH)
        v.addSubview(quit)

        let done = NSButton(title: "Done", target: self, action: #selector(saveAndClose))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.toolTip = "Save settings and close this window."
        done.frame = NSRect(x: winW - pad - btnW, y: updH + bottomMargin, width: btnW, height: btnH)
        v.addSubview(done)

        // The update strip: a blue band across the very bottom, present only
        // while there's an update to announce. The window's rounded bottom
        // corners clip its ends. Blue is the site's accent — loud enough that
        // it can't be missed in a window otherwise made of grays.
        updateStatus = nil
        updateButton = nil
        if showUpdate {
            let accent = NSColor(srgbRed: 59 / 255, green: 130 / 255, blue: 246 / 255, alpha: 1)
            let strip = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: Self.updateStripH))
            strip.wantsLayer = true
            strip.layer?.backgroundColor = accent.cgColor

            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11)
            status.textColor = .white
            strip.addSubview(status)
            updateStatus = status

            // White pill, blue label, drawn with our own layer rather than a
            // native bezel: AppKit washes bezels out whenever the window isn't
            // key, which made the button nearly vanish against the blue.
            let btn = NSButton(title: "Update", target: appDelegate,
                               action: #selector(AppDelegate.performUpdate))
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
            btn.layer?.cornerRadius = 9        // full pill at the 18 pt height
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            btn.attributedTitle = NSAttributedString(string: "Update", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: accent,
                .paragraphStyle: para,
            ])
            btn.toolTip = appDelegate?.isHomebrewManaged == true
                ? "Upgrade through Homebrew and reopen."
                : "Download the new version and open it."
            strip.addSubview(btn)
            updateButton = btn

            v.addSubview(strip)
        }

        if needsScroll {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0,
                                                    width: winW + scrollerW, height: windowH))
            scroll.drawsBackground = false      // the window's own background shows through
            scroll.hasVerticalScroller = true
            // Always visible, never fading: an overlay scroller disappears at
            // rest, which leaves a window silently taller than it looks with no
            // hint that there is anything below the fold.
            scroll.autohidesScrollers = false
            scroll.scrollerStyle = .legacy
            scroll.documentView = v
            contentView = scroll
            // `v` is unflipped, so its origin is the *bottom* — without this the
            // window opens on the button row with the title scrolled off. Drive
            // the clip view rather than `v.scroll(_:)`, which is a no-op this
            // early.
            scroll.contentView.scroll(to: NSPoint(x: 0, y: H - windowH))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            contentView = v
        }
        refreshBanner()
        layoutUpdateStrip()
    }

    /// Fill in the strip's wording for the current state and centre the
    /// [status] (+ [Update]) pair as one group.
    private func layoutUpdateStrip() {
        guard let status = updateStatus, let btn = updateButton else { return }
        let state = appDelegate?.updateState ?? .upToDate
        let latest = appDelegate?.latestVersion
        var showButton = false
        switch state {
        case .upToDate:
            status.stringValue = ""
        case .available:
            status.stringValue = latest.map { "Update available — v\($0)" } ?? "Update available"
            showButton = true
        case .failed:
            // The upgrade didn't take. Say so rather than silently re-offering,
            // so a second press doesn't look like the first one being ignored.
            status.stringValue = latest.map { "Update to v\($0) didn't finish" }
                ?? "Update didn't finish"
            showButton = true
        case .downloading:
            status.stringValue = "Downloading update…"
        case .updating:
            status.stringValue = latest.map { "Updating to v\($0)…" } ?? "Updating…"
        }
        btn.isHidden = !showButton
        status.sizeToFit()

        let gap: CGFloat = 8, btnH: CGFloat = 18
        var bw: CGFloat = 0
        if showButton { btn.sizeToFit(); bw = max(btn.frame.width + 20, 62) }
        let total = status.frame.width + (showButton ? gap + bw : 0)
        var x = ((winW - total) / 2).rounded()
        status.frame.origin = NSPoint(x: x,
                                      y: ((Self.updateStripH - status.frame.height) / 2).rounded())
        x += status.frame.width
        if showButton {
            x += gap
            btn.frame = NSRect(x: x, y: ((Self.updateStripH - btnH) / 2).rounded(),
                               width: bw, height: btnH)
        }
    }

    /// The strip's presence changes the window height, so a state change is a
    /// rebuild rather than a redraw.
    func refreshUpdateFooter() { rebuild() }

    // MARK: Layout helpers

    /// Rebuild for a light/dark flip. Layer colors resolve once when set, so
    /// the whole content has to be rebuilt or it keeps the old theme's colors.
    func appearanceChanged() {
        builtAppearance = nil
        rebuild()
    }

    /// A titled outline group: small secondary label above a rounded border box.
    /// Returns the box's frame so callers can place content inside it.
    private func addGroup(_ title: String, x: CGFloat, width: CGFloat, top: CGFloat,
                          boxH: CGFloat, dimmed: Bool, in v: NSView) -> NSRect {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alphaValue = dimmed ? 0.5 : 1
        label.frame = NSRect(x: x + 6, y: top - groupTitleH, width: width - 12, height: groupTitleH)
        v.addSubview(label)
        // An outline, not a fill. The container has to be here — without it the
        // labels float free of their rows and twelve cards read as one field —
        // but a filled well plus filled cards was a box in a box twelve times
        // over, and a well with unfilled cards was one gray too many. A hairline
        // does the binding without adding another surface.
        let boxFrame = NSRect(x: x, y: top - groupTitleH - groupTitleGap - boxH, width: width, height: boxH)
        let box = NSView(frame: boxFrame)
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        // Plain separatorColor: it's dynamic, so it tracks light/dark. Putting
        // withAlphaComponent on it resolves the color against the default
        // appearance instead — which came out brighter in dark mode, not fainter.
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.alphaValue = dimmed ? 0.5 : 1
        v.addSubview(box)
        return boxFrame
    }

    /// A two-tone pill under the switch, in place of a description: the leading
    /// "System Permissions:" label on one gray, the permission lights on a
    /// second gray. Each light is a green dot when granted, or a red, underlined
    /// link when not — clicking fires the real macOS request (prompting the user
    /// and adding Pullcord to that permission's list). Nothing here blocks the
    /// app. Sits vertically centered in the [rowY, rowY+rowH] slot.
    private func addPermissionPill(hasAX: Bool, hasScreenRec: Bool, rowY: CGFloat, rowH: CGFloat, in v: NSView) {
        let pillH: CGFloat = 22, segPad: CGFloat = 11, itemGap: CGFloat = 16
        func cy(_ h: CGFloat) -> CGFloat { (pillH - h) / 2 }

        // Leading label.
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let heading = NSTextField(labelWithString: "System Permissions:")
        heading.font = labelFont
        heading.textColor = .secondaryLabelColor
        heading.sizeToFit()
        let headW = ceil(heading.frame.width), headH = ceil(heading.frame.height)

        // dot + name; granted is plain status, missing is an underlined link.
        func item(_ name: String, granted: Bool, action: Selector, tip: String) -> NSButton {
            let title = NSMutableAttributedString(
                string: "● ", attributes: [.foregroundColor: granted ? NSColor.systemGreen : NSColor.systemRed,
                                            .font: NSFont.systemFont(ofSize: 9)])
            var nameAttrs: [NSAttributedString.Key: Any] =
                [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                 .foregroundColor: granted ? NSColor.secondaryLabelColor : NSColor.labelColor]
            if !granted { nameAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            title.append(NSAttributedString(string: name, attributes: nameAttrs))
            let btn = NSButton()
            btn.isBordered = false
            btn.attributedTitle = title
            btn.toolTip = tip
            btn.sizeToFit()
            if granted { btn.target = nil; btn.action = nil }
            else { btn.target = self; btn.action = action }
            return btn
        }

        let a = item("Accessibility", granted: hasAX, action: #selector(grantAccessibility),
                     tip: hasAX ? "Accessibility is on. Files, Actions, Clipboard and Settings can run."
                                : "Lets Files, Actions, Clipboard and Settings work. Click to grant.")
        let s = item("Screen Recording", granted: hasScreenRec, action: #selector(grantScreenRecording),
                     tip: hasScreenRec ? "Screen Recording is on. Capture Text can read the screen."
                                       : "Lets Capture Text read the screen. Click to grant.")
        let aw = ceil(a.frame.width), sw2 = ceil(s.frame.width)
        let ah = ceil(a.frame.height), sh = ceil(s.frame.height)

        // Two segments: label chip (darker gray) then the lights chip (lighter).
        let labelSegW = segPad + headW + segPad
        let lightsSegW = segPad + aw + itemGap + sw2 + segPad
        let totalW = labelSegW + lightsSegW
        let pillX = (winW - totalW) / 2
        let pillY = rowY + (rowH - pillH) / 2

        let pill = NSView(frame: NSRect(x: pillX, y: pillY, width: totalW, height: pillH))
        pill.wantsLayer = true
        pill.layer?.cornerRadius = pillH / 2
        pill.layer?.masksToBounds = true
        v.addSubview(pill)

        // Two near-identical grays (about quaternary / quinary label strength —
        // quinary has no NSColor, so approximate), resolved for the current theme.
        let base = (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            ? NSColor.white : NSColor.black
        let leftBG = NSView(frame: NSRect(x: 0, y: 0, width: labelSegW, height: pillH))
        leftBG.wantsLayer = true
        leftBG.layer?.backgroundColor = base.withAlphaComponent(0.10).cgColor
        pill.addSubview(leftBG)
        let rightBG = NSView(frame: NSRect(x: labelSegW, y: 0, width: lightsSegW, height: pillH))
        rightBG.wantsLayer = true
        rightBG.layer?.backgroundColor = base.withAlphaComponent(0.055).cgColor
        pill.addSubview(rightBG)

        heading.frame = NSRect(x: segPad, y: cy(headH), width: headW, height: headH)
        pill.addSubview(heading)
        var x = labelSegW + segPad
        a.frame = NSRect(x: x, y: cy(ah), width: aw, height: ah); pill.addSubview(a); x += aw + itemGap
        s.frame = NSRect(x: x, y: cy(sh), width: sw2, height: sh); pill.addSubview(s)
    }

    /// Fire the real macOS permission requests — each prompts the user and adds
    /// Pullcord to that permission's list in System Settings.
    @objc private func grantAccessibility() { appDelegate?.promptForAccessibility() }
    @objc private func grantScreenRecording() { _ = CGRequestScreenCaptureAccess() }

    @objc private func forceQuit() { NSApp.terminate(nil) }
    @objc private func saveAndClose() { close() }
    @objc private func smartToggleChanged(_ sender: NSButton) {
        UserDefaults.standard.settingsToggle = sender.state == .on
    }

    @objc private func holdKeyChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.dictationHoldKey =
            HoldKey.menuOrder[safe: sender.indexOfSelectedItem] ?? .off
        appDelegate?.syncDictationMonitor()
    }

    @objc private func editRewriteActions() {
        showInstructionsEditor()
    }

    /// The rewrite picker's "New Action…" entry: same editor, new set pre-inserted.
    func addRewriteAction() {
        showInstructionsEditor(addingSet: true)
    }

    private func showInstructionsEditor(addingSet: Bool = false) {
        if instructionsWindow == nil {
            instructionsWindow = InstructionsWindow(appDelegate: appDelegate) { [weak self] in
                self?.appDelegate?.syncHotkeys()      // sets can carry shortcuts now
                self?.refreshBanner()
            }
        }
        if addingSet { instructionsWindow?.addSet() }
        instructionsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        instructionsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSpeakSetup() {
        if speakSetupWindow == nil { speakSetupWindow = SpeakSetupWindow() }
        speakSetupWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        speakSetupWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func colorFormatChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.colorFormat = ColorFormat(rawValue: sender.indexOfSelectedItem) ?? .hex
    }

    /// Open the palette — clearing lives in there, behind actually looking at
    /// what you'd be throwing away.
    @objc private func viewColorHistoryTapped() { appDelegate?.openColorHistory() }

    @objc private func removeBreaksChanged(_ sender: NSButton) {
        UserDefaults.standard.ocrKeepLineBreaks = sender.state != .on   // checked = remove breaks
    }

    @objc private func screenSleepChanged(_ sender: NSButton) {
        UserDefaults.standard.keepAwakeAllowDisplaySleep = sender.state == .on
        appDelegate?.reapplyKeepAwake()   // take effect now if sleep is blocked
    }

    @objc private func appEnabledChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        appDelegate?.setAppEnabled(on)
        rebuild()
    }

    private func configureIcon(_ icon: NSImageView, _ panel: Panel, dimmed: Bool = false) {
        if let gp = panel.glyphPath, let glyph = NSImage(contentsOfFile: gp) {
            glyph.isTemplate = true
            glyph.size = NSSize(width: 19, height: 19)
            icon.image = glyph
        } else {
            icon.image = NSImage(systemSymbolName: panel.symbol, accessibilityDescription: panel.name)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
        }
        icon.contentTintColor = dimmed ? .tertiaryLabelColor : .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
    }

    /// Footer text carries only hotkey conflicts; the Accessibility state lives
    /// in the bottom strip, so a trust flip triggers a rebuild to re-light it.
    func refreshBanner() {
        if (appDelegate?.hasAccessibility ?? false) != builtWithAX { rebuild(); return }
        if let conflicts = appDelegate?.conflicted, !conflicts.isEmpty {
            banner?.stringValue = "In use by another app: " + conflicts.joined(separator: ", ")
        } else {
            banner?.stringValue = ""
        }
    }

    // Recording must never outlive the window's key status: a local NSEvent
    // monitor only sees events while we're the active app, so an orphaned
    // recording would park every hotkey with no way to resume them.
    func windowWillClose(_ notification: Notification) {
        RecorderButton.active?.cancelRecording()
        // Both belong to cards in this window — left open on their own they'd be
        // stray windows from an app with no Dock icon to get back to.
        speakSetupWindow?.close()
        instructionsWindow?.close()
        infoPopover?.performClose(nil)
    }
    func windowDidResignKey(_ notification: Notification) {
        RecorderButton.active?.cancelRecording()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Re-try conflicted registrations (the other app may have released the
        // combo) and reflect any outside changes.
        appDelegate?.syncHotkeys()
        refreshBanner()   // rebuilds if Accessibility flipped (re-lights the strip)
        // Reflect a Screen Recording grant or a "Speak selection" change made in
        // System Settings while we were away.
        if CGPreflightScreenCaptureAccess() != builtScreenRec
            || SpokenSelection.current != builtSpoken { rebuild() }
    }
}

/// What the ⓘ in the titlebar shows: the app, where its source and help live,
/// and a way to say thanks. A popover rather than a window — it is anchored to
/// the control that opened it, dismisses itself the moment you click elsewhere,
/// and never becomes another window to find and close.
///
/// The help document is linked rather than bundled. It is one markdown file in
/// the repo, so linking it means one copy to keep current instead of a second
/// baked into every build — and the app has no business shipping a viewer to
/// read its own manual.
enum MoreInfo {
    /// blob/HEAD rather than blob/main: HEAD resolves to whatever the default
    /// branch is called, so the link survives the repo being made with either.
    static let repoURL   = "https://github.com/grokcodile/pullcord"
    static let helpURL   = "https://github.com/grokcodile/pullcord/blob/HEAD/HELP.md"
    static let issuesURL = "https://github.com/grokcodile/pullcord/issues"
    static let siteURL   = "https://pullcord.app"
    static let tipURL    = "https://ko-fi.com/grokcodile"

    /// The About popover, hung off the titlebar ⓘ: app icon, name, version, the
    /// one setting that lives here, the places to go for help, then the "it's
    /// free…" lead-in and the two ways to support Pullcord. Every row is one
    /// symbol-led button; what it does for you is a tooltip, so the stack stays
    /// a column of actions rather than a wall of copy. (Key54's convention.)
    ///
    /// Built bottom-up, the way AppKit lays out an unflipped view, so the
    /// popover is exactly as tall as its content and a copy change can't clip it.
    /// Tag on the version line, so the caller can find it again to report a
    /// check's progress. The popover is rebuilt on every open, so a stored
    /// reference has to be re-fetched rather than kept.
    static let versionTag = 9101

    static func makeContent(target: AnyObject, guide: Selector,
                            website: Selector, issues: Selector,
                            coffee: Selector, star: Selector,
                            check: Selector) -> NSView {
        // Two gaps and nothing else: rowGap inside a group of buttons,
        // sectionGap between anything and the next thing. Every vertical
        // measurement below is one of those two, so the stack has a rhythm
        // rather than a pile of one-off numbers.
        let w: CGFloat = 300, pad: CGFloat = 16
        let icon: CGFloat = 64, btnH: CGFloat = 30
        let rowGap: CGFloat = 6, sectionGap: CGFloat = 12
        // The lead-in belongs to the two buttons under it — its ellipsis hands
        // straight off into them — so it keeps sectionGap below and takes more
        // above, to part it from the block it is not attached to.
        let leadInGap: CGFloat = 20
        let nameH: CGFloat = 24, versionH: CGFloat = 15
        let innerW = w - pad * 2

        // (title, SF Symbol, tooltip, destination, action). Every list runs
        // bottom-up, the way the view is built. The lead-in sits between help
        // and support so its trailing ellipsis hands off into the support
        // buttons.
        //
        // A row with a destination leaves the app, and says where on a second
        // tooltip line — so a link is never a mystery before you click it. The
        // one row with no destination changes a setting instead, and shows a
        // single line.
        typealias Row = (String, String, String, String?, Selector)
        let support: [Row] = [
            ("Buy me a coffee", "mug",  "Tips keep it going",          tipURL,  coffee),
            ("Star on GitHub",  "star", "A star helps others find it", repoURL, star),
        ]
        let help: [Row] = [
            ("Bug Report", "ladybug", "Submit a support ticket",         issuesURL, issues),
            ("User Guide", "book",    "View help and app documentation", helpURL,   guide),
            // Deliberately doesn't name the address: it's on the line below.
            ("Website",    "globe",   "Learn more about Pullcord",     siteURL,   website),
        ]
        // Sits between the links and the support section: it changes what the
        // app does rather than opening something, so it doesn't belong in the
        // run of destinations above it. The missing ↗ in its tooltip is what
        // marks it out — it needs no heading to say so.
        // The two wrapped blocks are the only content-dependent heights —
        // measure both first and derive every frame (and the popover height)
        // from them, so a copy change can't clip the popover.
        let tagline = NSTextField(wrappingLabelWithString:
            "The most powerful things macOS can do are often the hardest to reach "
            + "— Pullcord puts them at your fingertips.")
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        let taglineH = ceil(tagline.sizeThatFits(
            NSSize(width: innerW, height: .greatestFiniteMagnitude)).height)

        let body = NSTextField(wrappingLabelWithString:
            "Pullcord is 100% free.\nIf it's earned a spot on your Mac…")
        body.font = .systemFont(ofSize: NSFont.systemFontSize - 1)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        let bodyH = ceil(body.sizeThatFits(
            NSSize(width: innerW, height: .greatestFiniteMagnitude)).height)

        /// The address as you'd say it aloud: no scheme, no trailing slash.
        func prettyURL(_ url: String) -> String {
            var out = url
            for scheme in ["https://", "http://"] where out.hasPrefix(scheme) {
                out.removeFirst(scheme.count)
            }
            while out.hasSuffix("/") { out.removeLast() }
            return out
        }

        /// Reserve one button per row, leaving `y` just past the last of them
        /// — no trailing gap, so every gap in the stack is stated explicitly
        /// below rather than half-hidden in here.
        func reserve(_ rows: [Row], from y: inout CGFloat) -> [CGFloat] {
            var ys: [CGFloat] = []
            for i in rows.indices {
                if i > 0 { y += rowGap }
                ys.append(y)
                y += btnH
            }
            return ys
        }

        // The lead-in leans on white space alone to group itself with the two
        // buttons under it. A tinted panel was tried in Key54 and dropped: any
        // fill dark enough to read in dark mode lands as a grey slab in light.
        var y = pad
        let supportY  = reserve(support, from: &y)
        y += sectionGap
        let bodyY     = y;           y += bodyH + leadInGap
        let helpY     = reserve(help, from: &y)
        y += sectionGap
        let taglineY  = y;           y += taglineH + sectionGap
        // The name/version/icon block reads as one unit, so it closes up. The
        // icon needs more than closing up: AppIcon.icns carries 6pt of
        // transparent margin at 64pt (measured), and NSTextField leaves a few
        // more above 20pt caps, so a nominal 8pt gap rendered as nearer 18.
        // Subtracting the bleed puts the frames slightly through each other and
        // the artwork where it should have been all along.
        let iconBleed: CGFloat = 6
        let versionY  = y;           y += versionH + 2
        let nameY     = y;           y += nameH + 4 - iconBleed
        let iconY     = y;           y += icon
        let h = y + pad

        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let iconView = NSImageView(frame: NSRect(x: (w - icon) / 2, y: iconY, width: icon, height: icon))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        v.addSubview(iconView)

        func centered(_ text: String, _ y: CGFloat, _ height: CGFloat,
                      size: CGFloat, weight: NSFont.Weight, color: NSColor) {
            let f = NSTextField(labelWithString: text)
            f.font = .systemFont(ofSize: size, weight: weight)
            f.textColor = color
            f.alignment = .center
            f.frame = NSRect(x: pad, y: y, width: innerW, height: height)
            v.addSubview(f)
        }
        centered("Pullcord", nameY, nameH, size: 20, weight: .bold, color: .labelColor)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        // The version line doubles as the update check — it answers the question
        // the version number raises. An action, not a preference: there's no
        // setting for this and no background polling, so this and opening settings
        // are the only two moments Pullcord asks GitHub anything.
        let versionBtn = LinkButton(title: "", target: target, action: check)
        versionBtn.isBordered = false
        versionBtn.toolTip = "Check for updates"
        versionBtn.tag = versionTag
        versionBtn.frame = NSRect(x: pad, y: versionY, width: innerW, height: versionH)
        let vPara = NSMutableParagraphStyle(); vPara.alignment = .center
        versionBtn.attributedTitle = NSAttributedString(
            string: "Version \(version)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: vPara])
        v.addSubview(versionBtn)

        tagline.frame = NSRect(x: pad, y: taglineY, width: innerW, height: taglineH)
        v.addSubview(tagline)

        body.frame = NSRect(x: pad, y: bodyY, width: innerW, height: bodyH)
        v.addSubview(body)

        func place(_ rows: [Row], _ ys: [CGFloat]) {
            for (i, row) in rows.enumerated() {
                // A missing symbol just leaves a title-only button rather than a
                // blank one, so a rename in some future SF Symbols can't break this.
                let image = NSImage(systemSymbolName: row.1, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
                // NSButton has no image/title spacing knob, so the gap is a
                // leading space on the title.
                let btn = NSButton(title: image == nil ? row.0 : " " + row.0,
                                   target: target, action: row.4)
                btn.bezelStyle = .rounded
                btn.image = image
                btn.imagePosition = image == nil ? .noImage : .imageLeading
                // Without this the symbol pins to the button's leading edge and
                // the title centers on its own, leaving a gap down the column.
                btn.imageHugsTitle = true
                // Second line: where this goes. The scheme is dropped because it
                // is the same on every one of them and only costs width.
                btn.toolTip = row.3.map { row.2 + "\n↗ " + prettyURL($0) } ?? row.2
                btn.frame = NSRect(x: pad, y: ys[i], width: innerW, height: btnH)
                v.addSubview(btn)
            }
        }
        place(support, supportY)
        place(help, helpY)
        return v
    }
}

/// How to switch on macOS's "Speak selection", written out, with the button that
/// gets you to the pane.
///
/// It has to be told rather than linked: the shortcut lives in a sheet behind the
/// ⓘ on that row, and no URL opens it — the deep link reaches the pane and stops.
final class SpeakSetupWindow: NSWindow {
    init() {
        let w: CGFloat = 440, pad: CGFloat = 24
        let badge: CGFloat = 24, textX = pad + badge + 12
        let textW = w - textX - pad

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                   color: NSColor, x: CGFloat, width: CGFloat) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = .systemFont(ofSize: size, weight: weight)
            f.textColor = color
            f.isSelectable = false
            f.preferredMaxLayoutWidth = width
            let h = ceil(f.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
            f.frame = NSRect(x: x, y: 0, width: width, height: h)
            return f
        }

        // One action per line. Anything that needed a sentence under it was
        // really two steps wearing one number.
        let steps = [
            "Open “Read & Speak” using the button below.",
            "Choose a “System voice” of your choice.",
            "Turn on “Speak selection”.",
            "Click ⓘ beside “Speak selection” to set a keyboard shortcut.",
        ]

        // Laid out top-down into a flipped view, so the window is sized to fit
        // its own text rather than to a guess.
        var placed: [(NSView, CGFloat)] = []
        var y = pad

        let intro = label("Advanced text to speech is built into macOS.",
                          size: 13, weight: .regular, color: .labelColor, x: pad, width: w - pad * 2)
        placed.append((intro, y))
        y += intro.frame.height + 20

        for (i, step) in steps.enumerated() {
            let line = label(step, size: 13, weight: .regular, color: .labelColor,
                             x: textX, width: textW)
            let rowH = max(badge, line.frame.height)

            let dot = NSView(frame: NSRect(x: pad, y: 0, width: badge, height: badge))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = badge / 2
            dot.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.15).cgColor
            let n = NSTextField(labelWithString: "\(i + 1)")
            n.font = .systemFont(ofSize: 12, weight: .semibold)
            n.textColor = .labelColor
            n.alignment = .center
            n.frame = NSRect(x: 0, y: (badge - 15) / 2 - 1, width: badge, height: 15)
            dot.addSubview(n)

            // Centre both against the taller of the two, so a wrapped step keeps
            // its number beside the first line rather than floating.
            placed.append((dot, y + (rowH - badge) / 2))
            placed.append((line, y + (rowH - line.frame.height) / 2))
            y += rowH + 12
        }
        y -= 12

        let btnH: CGFloat = 32
        let h = y + 24 + btnH + pad

        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Configure Speak Text"
        isReleasedWhenClosed = false

        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        for (view, top) in placed {
            view.frame.origin.y = top
            v.addSubview(view)
        }

        let open = NSButton(title: "Open System Settings", target: self,
                            action: #selector(openSpokenContent))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        open.sizeToFit()
        let bw = ceil(open.frame.width) + 20
        open.frame = NSRect(x: (w - bw) / 2, y: h - pad - btnH, width: bw, height: btnH)
        v.addSubview(open)

        contentView = v
    }

    /// Opens the pane and gets out of the way — the steps have been read by the
    /// time this is pressed, and leaving the window sitting over System Settings
    /// only means dismissing it there.
    @objc private func openSpokenContent() {
        let urls = ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                    "x-apple.systempreferences:com.apple.Accessibility-Settings.extension"]
        for s in urls where NSWorkspace.shared.open(URL(string: s)!) { break }
        close()
    }
}

/// The editor for Rewrite Text's actions. Two sets, because
/// the tool does two different jobs: rewriting text you selected, and cleaning up
/// what you just dictated.
final class InstructionsWindow: NSWindow, NSTableViewDataSource, NSTableViewDelegate {
    private var sets: [RewriteAction] = []
    private var selected = 0
    /// Selecting a row during init fires the delegate before the editor fields
    /// have been filled — committing those blanks wiped the first set every time
    /// the window opened. Nothing commits until the first load is done.
    private var ready = false
    private weak var appDelegate: AppDelegate?
    private let table = NSTableView()
    private let titleField = NSTextField()
    private let textView = NSTextView()
    private var recorderBox: NSView!
    private let onChange: () -> Void

    private let w: CGFloat = 640, pad: CGFloat = 20
    private let listW: CGFloat = 180

    init(appDelegate: AppDelegate?, onChange: @escaping () -> Void) {
        self.appDelegate = appDelegate
        self.onChange = onChange
        let h: CGFloat = 430
        super.init(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Rewrite Text Settings"
        isReleasedWhenClosed = false
        sets = UserDefaults.standard.rewriteActions

        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let listHead = NSTextField(labelWithString: "Rewrite Actions")
        listHead.font = .systemFont(ofSize: 12, weight: .semibold)
        listHead.frame = NSRect(x: pad, y: h - pad - 18, width: 300, height: 18)
        v.addSubview(listHead)

        let listTop = listHead.frame.minY - 6, listBottom: CGFloat = 84

        // ── the list ───────────────────────────────────────────────────
        let scroll = NSScrollView(frame: NSRect(x: pad, y: listBottom,
                                                width: listW, height: listTop - listBottom))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("t"))
        col.width = listW - 24
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        v.addSubview(scroll)

        let add = NSButton(title: "+", target: self, action: #selector(addSet))
        add.bezelStyle = .rounded
        add.frame = NSRect(x: pad, y: listBottom - 32, width: 32, height: 26)
        v.addSubview(add)
        let remove = NSButton(title: "−", target: self, action: #selector(removeSet))
        remove.bezelStyle = .rounded
        remove.frame = NSRect(x: pad + 36, y: listBottom - 32, width: 32, height: 26)
        v.addSubview(remove)

        // ── the editor ─────────────────────────────────────────────────
        let ex = pad + listW + 20, ew = w - ex - pad
        func label(_ text: String, x: CGFloat, _ y: CGFloat, _ width: CGFloat) {
            let f = NSTextField(labelWithString: text)
            f.font = .systemFont(ofSize: 11, weight: .semibold)
            f.textColor = .secondaryLabelColor
            f.frame = NSRect(x: x, y: y, width: width, height: 15)
            v.addSubview(f)
        }
        label("Title", x: ex, listTop - 15, 120)
        titleField.frame = NSRect(x: ex, y: listTop - 42, width: ew - 150, height: 22)
        titleField.font = .systemFont(ofSize: 12)
        titleField.target = self
        titleField.action = #selector(titleEdited)
        titleField.delegate = self
        v.addSubview(titleField)

        label("Direct Shortcut", x: ex + ew - 140, listTop - 15, 140)
        let box = NSView(frame: NSRect(x: ex + ew - 140, y: listTop - 42, width: 140, height: 22))
        v.addSubview(box)
        recorderBox = box

        label("Instructions", x: ex, listTop - 70, 200)
        // Top stops 78pt below the list's top, clearing the Title row and the
        // Instructions label above it.
        let insScroll = NSScrollView(frame: NSRect(x: ex, y: listBottom, width: ew,
                                                   height: listTop - 78 - listBottom))
        insScroll.hasVerticalScroller = true
        insScroll.borderType = .bezelBorder
        textView.font = .systemFont(ofSize: 12)
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        insScroll.documentView = textView
        v.addSubview(insScroll)

        // ── footer ─────────────────────────────────────────────────────
        let save = NSButton(title: "Save", target: self, action: #selector(saveAll))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: w - pad - 90, y: 22, width: 90, height: 30)
        v.addSubview(save)

        contentView = v
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        loadSelected()
        ready = true
    }

    // MARK: list
    func numberOfRows(in tableView: NSTableView) -> Int { sets.count }

    /// A checkbox and a title per row, so which sets are live is visible without
    /// selecting each one.
    func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let set = sets[safe: row] else { return nil }
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: listW - 24, height: 22))
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
        check.state = set.enabled ? .on : .off
        check.tag = row
        check.frame = NSRect(x: 2, y: 2, width: 18, height: 18)
        cell.addSubview(check)
        let label = NSTextField(labelWithString: set.title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = set.enabled ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 24, y: 2, width: listW - 52, height: 17)
        cell.addSubview(label)
        return cell
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard sets.indices.contains(sender.tag) else { return }
        commitEditor()          // or a title typed but not yet committed is saved over
        sets[sender.tag].enabled = sender.state == .on
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        saveQuietly()
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = max(0, table.selectedRow)
        // The editor belongs to the row it was last loaded for. Committing it
        // into the freshly selected row is how a new set inherited the previous
        // set's instructions, and how deleting a set blanked the one above.
        if row != selected { commitEditor() }
        selected = row
        loadSelected()
    }

    /// Pull the editor's fields into the model. Called before anything that
    /// changes which set is showing, so nothing typed is lost by clicking away.
    fileprivate func commitEditor() {
        guard ready, sets.indices.contains(selected) else { return }
        // A blank title keeps the one it had — inventing "Untitled" for someone
        // who cleared the field to retype it is worse than leaving it alone.
        let t = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { sets[selected].title = t }
        sets[selected].instructions = textView.string
    }

    private func loadSelected() {
        guard let set = sets[safe: selected] else { return }
        titleField.stringValue = set.title
        textView.string = set.instructions
        recorderBox.subviews.forEach { $0.removeFromSuperview() }
        let rec = RecorderButton(panel: nil, appDelegate: appDelegate,
                                 restingTitle: set.shortcut?.label ?? "Set Shortcut")
        rec.alignment = .center
        rec.frame = recorderBox.bounds
        let index = selected
        rec.onSave = { [weak self] sc in
            guard let self, self.sets.indices.contains(index) else { return }
            self.sets[index].shortcut = sc
        }
        rec.onChange = { [weak self] in self?.loadSelected(); self?.saveQuietly() }
        recorderBox.addSubview(rec)
        if set.shortcut != nil {
            rec.enableClear { [weak self] in
                guard let self, self.sets.indices.contains(index) else { return }
                self.sets[index].shortcut = nil
                self.loadSelected()
                self.saveQuietly()
            }
        }
    }

    @objc private func titleEdited() { commitEditor(); refreshRow() }

    /// Redraw just the edited row, so the list tracks the title as it's typed
    /// without a full reload taking focus out of the field.
    fileprivate func refreshRow() {
        guard sets.indices.contains(selected) else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: selected),
                         columnIndexes: IndexSet(integer: 0))
    }

    /// Internal: SettingsWindow's "New Action…" path calls it from outside the
    /// table's own plus button.
    @objc func addSet() {
        commitEditor()
        sets.append(RewriteAction(title: "Untitled Action", instructions: "", shortcut: nil, enabled: true))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: sets.count - 1), byExtendingSelection: false)
        // Straight into the title field with everything selected: typing a name
        // replaces "Untitled Action" instead of being inserted before it.
        makeFirstResponder(titleField)
        titleField.selectText(nil)
        // Nothing to persist yet: the set becomes real once its title is typed
        // or its instructions change, and both of those save on their own.
    }

    /// The first set is the built-in Clean Up and stays: it is what runs when
    /// nothing is enabled, so removing it would leave the shortcut with nothing
    /// to fall back on.
    @objc private func removeSet() {
        guard selected > 0, sets.indices.contains(selected) else { NSSound.beep(); return }
        commitEditor()          // nothing typed is lost before the row goes
        sets.remove(at: selected)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: min(selected, sets.count - 1)),
                               byExtendingSelection: false)
        // The selection change reloads the editor for the row that slid into
        // the deleted one's place; its commit is skipped, the row being gone.
    }

    fileprivate func saveQuietly() {
        UserDefaults.standard.rewriteActions = sets
        onChange()
    }

    @objc private func saveAll() {
        commitEditor()
        saveQuietly()
        close()
    }
}

/// Live commits. Waiting for Return or for Save is how an edit gets lost by
/// clicking somewhere else first — which is exactly what happened when the
/// something else was a checkbox that saved on the spot.
extension InstructionsWindow: NSTextViewDelegate, NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        commitEditor()
        refreshRow()
    }
    func controlTextDidEndEditing(_ notification: Notification) { commitEditor(); saveQuietly() }
    func textDidChange(_ notification: Notification) { commitEditor() }
    func textDidEndEditing(_ notification: Notification) { commitEditor(); saveQuietly() }
}

// MARK: - Working indicator

/// The app's single "working" indicator: a row of dots with a bright crest
/// travelling along them.
///
/// There used to be three. The bar meter did double duty — a wave while
/// listening, a pulse while waiting — and a separate shimmer of text lines ran
/// for the model and for OCR. None of the busy ones said anything a user could
/// decode from the shape, and one actively lied: bars claim sound is arriving,
/// which is wrong for a grace period that is only waiting. The tint already says
/// which tool is working, so the shape only has to say "not finished yet".
///
/// It is the last one standing. The bar meter went with the dictation pill, once
/// macOS's own indicator turned out to say the same thing in the same moment.
final class ProcessingDotsView: NSView {
    private var dots: [CALayer] = []
    private let dotD: CGFloat = 6, dotGap: CGFloat = 5
    private var t: Double = 0
    private var timer: Timer?

    var tint: NSColor = .systemPurple { didSet { applyTint() } }

    init(count: Int = 5) {
        let w = CGFloat(count) * dotD + CGFloat(count - 1) * dotGap
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: dotD))
        wantsLayer = true
        for i in 0..<count {
            let dot = CALayer()
            dot.frame = NSRect(x: CGFloat(i) * (dotD + dotGap), y: 0,
                               width: dotD, height: dotD)
            dot.cornerRadius = dotD / 2
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        applyTint()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyTint() {
        dots.forEach { $0.backgroundColor = tint.withAlphaComponent(0.28).cgColor }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Luminance, not size: the dots hold their shape and the crest passes
    /// through them. Brightness is distance from the crest rather than an on/off
    /// step, so it reads as one light moving rather than five lights blinking.
    private func step() {
        t += 1.0 / 30
        let n = Double(dots.count)
        // The +1.4 is a beat of dark before it comes round again, so the loop
        // reads as a repeating pass rather than a continuous spin.
        let pos = (t * 3.0).truncatingRemainder(dividingBy: n + 1.4) - 0.7
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, dot) in dots.enumerated() {
            let d = Double(i) - pos
            let crest = exp(-d * d / 0.5)
            dot.backgroundColor = tint.withAlphaComponent(0.28 + 0.72 * crest).cgColor
        }
        CATransaction.commit()
    }

    deinit { timer?.invalidate() }
}

// MARK: - HUD

/// A brief, non-interactive pill that flashes at the top-center of the active
/// screen — a color swatch + code after a pick, or an SF Symbol + message after
/// a text capture. It never takes focus, floats above other windows (including
/// full-screen apps), and fades itself out. One reused panel, so a rapid second
/// action just replaces the first.
final class HUD {
    private var panel: NSPanel?
    private var hideTimer: Timer?
    private var stickyWatchdog: Timer?
    private weak var working: ProcessingDotsView?
    private var chrome: NSVisualEffectView?
    private let panelH: CGFloat = 42, padH: CGFloat = 18, gap: CGFloat = 10
    /// Bumped by every present, hide and dismiss. The morph runs as three
    /// chained animations across about 0.4s, which is long enough for the next
    /// pill to arrive mid-flight — `stopDictation` does exactly that, showing
    /// the working dots and then a result one runloop turn later. Each stage
    /// checks it is still the current generation and gives up if it is not.
    /// Without this, two chains both add their content to the shell and both
    /// animate the panel frame, so the pill ends up showing two states at once,
    /// clipped to the wrong width — and, because only the last stage schedules
    /// the auto-hide, a superseded chain can leave the pill up with no timer
    /// at all until the app restarts.
    private var generation = 0

    /// Swatch dot in the sampled color + the copied code (Color Picker).
    func showColor(code: String, color: NSColor) {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let textSize = (code as NSString).size(withAttributes: [.font: font])
        let textW = ceil(textSize.width), textH = ceil(textSize.height)
        let dotD: CGFloat = 20
        let width = padH + dotD + gap + textW + padH
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: panelH))

        let swatch = NSView(frame: NSRect(x: padH, y: (panelH - dotD) / 2, width: dotD, height: dotD))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        swatch.layer?.cornerRadius = dotD / 2
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = ink.withAlphaComponent(0.4).cgColor
        content.addSubview(swatch)

        let label = NSTextField(labelWithString: code)
        label.font = font
        label.textColor = ink
        label.frame = NSRect(x: padH + dotD + gap, y: (panelH - textH) / 2, width: textW, height: textH)
        content.addSubview(label)
        working?.stop()
        present(content, width: width)
    }

    /// A pill that's just the dots — shown whenever something is working: the
    /// model rewriting text, Vision reading it off the screen, or dictation
    /// waiting out its grace period.
    func showProcessing(tint: NSColor? = nil) {
        let tint = tint ?? ink
        let dots = ProcessingDotsView()
        dots.tint = tint
        let width = padH + dots.frame.width + padH
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: panelH))
        dots.frame.origin = NSPoint(x: padH, y: (panelH - dots.frame.height) / 2)
        content.addSubview(dots)
        working?.stop()
        working = dots
        present(content, width: width, sticky: true)
        dots.start()
    }

    /// Take down a sticky pill.
    func hide() {
        working?.stop()
        hideTimer?.invalidate()
        dismiss()
    }

    /// SF Symbol + message (Capture Text confirmations), styled like the color pill.
    /// `sticky` leaves the pill up until `hide()` — for states that last as long
    /// as you hold a key, rather than momentary confirmations.
    func showMessage(_ message: String, symbol: String, tint: NSColor? = nil,
                     sticky: Bool = false) {
        let tint = tint ?? ink
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let measured = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let textW = measured, textH = ceil(font.ascender - font.descender)
        let iconD: CGFloat = 18
        let width = padH + iconD + gap + textW + padH
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: panelH))

        let icon = NSImageView(frame: NSRect(x: padH, y: (panelH - iconD) / 2, width: iconD, height: iconD))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyDown
        content.addSubview(icon)

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = ink
        label.frame = NSRect(x: padH + iconD + gap, y: (panelH - textH) / 2, width: textW, height: textH)
        content.addSubview(label)
        present(content, width: width, sticky: sticky)
    }

    /// Shared chrome: frost the pill, center it at the top, fade in, auto-hide.
    /// Where a pill of this width sits: centred at the top of the active screen.
    private func pillFrame(width: CGFloat) -> NSRect {
        guard let vf = NSScreen.main?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: width, height: panelH)
        }
        return NSRect(x: (vf.midX - width / 2).rounded(), y: vf.maxY - panelH - 16,
                      width: width, height: panelH)
    }

    private func present(_ content: NSView, width: CGFloat, sticky: Bool = false) {
        hideTimer?.invalidate()
        generation &+= 1
        let gen = generation
        let p = panel ?? makePanel()
        // A pill already on screen reports its new state in place rather than
        // being replaced. Rewriting shows a narrow dot row and finishes with a
        // wider confirmation; fading one out and another in reads as two HUDs
        // for one action, when it is one thing changing what it says.
        let morphing = panel != nil && p.isVisible && p.alphaValue > 0.01
        panel = p

        // The pill's chrome outlives its contents, so the material and the
        // rounded mask are never rebuilt mid-flight — only what's inside moves.
        let shell: NSVisualEffectView
        if let existing = chrome {
            shell = existing
        } else {
            shell = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: panelH))
            shell.material = .hudWindow
            shell.blendingMode = .behindWindow
            shell.state = .active
            shell.wantsLayer = true
            shell.layer?.cornerRadius = panelH / 2
            shell.layer?.masksToBounds = true      // what clips the push
            shell.autoresizingMask = [.width, .height]
            chrome = shell
        }
        p.contentView = shell

        let target = pillFrame(width: width)
        if morphing {
            // Sequenced, not simultaneous: the old line fades, THEN the pill
            // resizes, THEN the new line fades in. Overlapping them meant the
            // incoming content — built at the final width — arriving while the
            // pill was still narrow, so it read as text extruded from an edge.
            // Three short stages cost about a tenth of a second over one long
            // one and never land clipped.
            let outgoing = shell.subviews
            content.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.10
                outgoing.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                guard let self, gen == self.generation else { return }
                // Every subview, not just the set captured when this chain
                // started: a chain we superseded may have added content after
                // that snapshot was taken, and leaving it here is what put two
                // pills' worth of state on screen at once.
                shell.subviews.forEach { $0.removeFromSuperview() }
                shell.addSubview(content)
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    p.animator().setFrame(target, display: true)
                }, completionHandler: { [weak self] in
                    guard let self, gen == self.generation else { return }
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.14
                        content.animator().alphaValue = 1
                    }, completionHandler: { [weak self] in
                        guard let self, gen == self.generation else { return }
                        // Only now start the dwell, so a confirmation gets its
                        // full read time rather than spending a third of it
                        // arriving.
                        self.scheduleHide(sticky: sticky)
                    })
                })
            })
            return
        } else {
            shell.subviews.forEach { $0.removeFromSuperview() }
            shell.frame = NSRect(x: 0, y: 0, width: width, height: panelH)
            shell.addSubview(content)
            p.setFrame(target, display: false)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                p.animator().alphaValue = 1
            }
        }
        scheduleHide(sticky: sticky)
    }

    /// A sticky pill has no dwell: it waits to be replaced or hidden by whatever
    /// started it. That is right — dictation and the model both run for an
    /// unknown length of time — but it means a stop path that never runs leaves
    /// the pill on screen with nothing scheduled to take it down, and the only
    /// cure is relaunching the app.
    ///
    /// So sticky gets a watchdog instead of a dwell. Two minutes is deliberately
    /// far past any real case: dictation is hold-to-talk, and rewriting or OCR
    /// is seconds. If it ever fires, something upstream failed to clean up, and
    /// losing the indicator is the better failure — the work itself carries on,
    /// and the text still lands.
    private static let stickyMaxLifetime: TimeInterval = 120

    private func scheduleHide(sticky: Bool) {
        hideTimer?.invalidate()
        stickyWatchdog?.invalidate()
        guard !sticky else {
            stickyWatchdog = Timer.scheduledTimer(
                withTimeInterval: Self.stickyMaxLifetime, repeats: false) { [weak self] _ in
                self?.dismiss()
            }
            return
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismiss() {
        // Both meters, always: a timer left running on a dismissed pill is a
        // retained view redrawing 30 times a second forever.
        working?.stop()
        stickyWatchdog?.invalidate()
        stickyWatchdog = nil
        // Retire any morph still in flight, so a stage landing during the
        // fade-out cannot set the frame or fade content back in behind it.
        generation &+= 1
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            p.animator().alphaValue = 0
        }, completionHandler: { [weak p] in p?.orderOut(nil) })
    }

    /// `labelColor`, resolved against the pill's own appearance and handed back
    /// as a concrete colour.
    ///
    /// The indicators are layer-backed, and a dynamic colour turned into a
    /// `cgColor` resolves against whatever appearance is current at that
    /// moment — outside a draw cycle that is the app default, not this panel's.
    /// So a dot row built in dark mode kept its dark-mode ink after a theme
    /// flip. Resolving here, once, keeps every part of the pill honest.
    private var ink: NSColor {
        let appearance = panel?.effectiveAppearance ?? NSApp.effectiveAppearance
        var c = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            c = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return c
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 42),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }
}

// MARK: - Color history palette

/// A floating palette of recently-picked colors. A grid of swatches, each a color
/// square over an editable label box (the hex by default; click to rename).
/// Click a square to copy its code, drag it out to get the swatch as a PNG, or
/// use its hover pin to keep it. The header has an
/// eyedropper Pick, a format selector, and Clear. Recent picks roll off after 20;
/// pinned keepers persist at the top. It's an ordinary window — it stays open
/// while you work elsewhere until you close it — except that Pick closes it for
/// the duration of the sample, then reopens it.
final class ColorHistoryPanel: NSPanel, NSTextFieldDelegate {
    private weak var appDelegate: AppDelegate?
    private let cols = 5
    private let sq: CGFloat = 90                 // color square
    private let labelH: CGFloat = 20, labelGap: CGFloat = 4
    private let gap: CGFloat = 10, pad: CGFloat = 16, headerH: CGFloat = 42
    private var cellH: CGFloat { sq + labelGap + labelH }
    private var reloading = false   // guards against any re-entrant rebuild loop
    private var builtAppearance: NSAppearance.Name?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Color History"
        // A normal window, not a floating overlay: it stays put while you work in
        // other apps and closes only via its close button, so it can sit open
        // alongside a design tool.
        isFloatingPanel = false
        level = .normal
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Panels close on Esc by default; this one is an ordinary window that should
    /// only close via its close button (Esc still just ends a rename edit).
    override func cancelOperation(_ sender: Any?) {}

    /// Pullcord is a menu-bar-less agent, so there's no File menu to supply
    /// ⌘W — wire it up here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Redraw for a light/dark flip — swatch borders and the pin badge are layer
    /// colors, which keep whichever theme they were created under.
    func appearanceChanged() {
        builtAppearance = nil
        reload()
    }

    /// Rebuild the content from the current store — called on open and after any
    /// pick / pin / clear / format change.
    func reload() {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.reloadContent() }
    }

    private func reloadContent() {
        guard !reloading else { return }
        reloading = true
        defer { reloading = false }
        let entries = ColorHistory.load()
        let fmt = UserDefaults.standard.colorFormat
        let rows = max(1, Int(ceil(Double(entries.count) / Double(cols))))
        let contentW = pad * 2 + CGFloat(cols) * sq + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * cellH + CGFloat(rows - 1) * gap
        let H = headerH + gridH + pad
        setContentSize(NSSize(width: contentW, height: H))

        let v = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: contentW, height: H))
        // Swatch borders and the pin badge are layer colors too, so a theme flip
        // has to redraw this the same way it redraws the settings window.
        builtAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        v.onAppearanceChange = { [weak self] in
            guard let self,
                  self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != self.builtAppearance
            else { return }
            DispatchQueue.main.async { self.reload() }
        }
        let headerY = H - headerH

        // Eyedropper "Pick" (left) — closes the window FIRST, then samples, then
        // reopens (a loupe launched from under this window could end up orphaned
        // and holding the mouse system-wide).
        let pick = NSButton(title: "Pick", target: self, action: #selector(pickTapped))
        pick.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)
        pick.imagePosition = .imageLeading
        pick.bezelStyle = .rounded
        pick.toolTip = "Close the palette and sample a new color."
        pick.sizeToFit()
        let ph = ceil(pick.frame.height)
        pick.frame = NSRect(x: pad, y: headerY + (headerH - ph) / 2, width: ceil(pick.frame.width) + 14, height: ph)
        v.addSubview(pick)

        // Format selector (center) — drives the copy format and the labels below.
        let fmtPopup = NSPopUpButton()
        fmtPopup.addItems(withTitles: ColorFormat.allCases.map(\.label))
        fmtPopup.selectItem(at: fmt.rawValue)
        fmtPopup.target = self; fmtPopup.action = #selector(formatChanged(_:))
        fmtPopup.toolTip = "Format used when copying a code, and shown under each swatch."
        fmtPopup.sizeToFit()
        let fw = ceil(fmtPopup.frame.width), fhh = ceil(fmtPopup.frame.height)
        fmtPopup.frame = NSRect(x: (contentW - fw) / 2, y: headerY + (headerH - fhh) / 2, width: fw, height: fhh)
        v.addSubview(fmtPopup)

        // Clear (right, only if there are recents).
        if entries.contains(where: { !$0.pinned }) {
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearTapped))
            clear.bezelStyle = .rounded
            clear.toolTip = "Clear the recent colors (pinned colors are kept)."
            clear.sizeToFit()
            let cw = ceil(clear.frame.width) + 12, ch = ceil(clear.frame.height)
            clear.frame = NSRect(x: contentW - pad - cw, y: headerY + (headerH - ch) / 2, width: cw, height: ch)
            v.addSubview(clear)
        }

        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No colors yet — pick one to start.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: pad, y: (H - headerH) / 2 - 10, width: contentW - pad * 2, height: 20)
            v.addSubview(empty)
        } else {
            let top = H - headerH
            for (i, entry) in entries.enumerated() {
                let r = i / cols, c = i % cols
                let x = pad + CGFloat(c) * (sq + gap)
                let squareY = top - CGFloat(r) * (cellH + gap) - sq
                let square = ColorSquare(
                    entry: entry, size: sq, code: fmt.string(for: entry.color),
                    onCopyCode: { [weak self] in self?.appDelegate?.copyColorCode(entry.color) },
                    onTogglePin: { [weak self] in ColorHistory.togglePin(entry.hex); self?.reload() })
                square.frame = NSRect(x: x, y: squareY, width: sq, height: sq)
                v.addSubview(square)

                // Editable label in a visible box (so it's clearly renamable):
                // the hex by default; clearing it (or retyping the hex) reverts.
                // The code in the chosen format is the square's tooltip.
                let name = NSTextField()
                name.stringValue = ColorNames.display(entry.hex)
                name.isEditable = true
                name.isBezeled = true
                name.bezelStyle = .roundedBezel
                name.controlSize = .small
                name.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                name.alignment = .center
                name.lineBreakMode = .byTruncatingTail
                name.delegate = self
                name.identifier = NSUserInterfaceItemIdentifier(entry.hex)
                name.toolTip = "Rename this color"
                name.frame = NSRect(x: x, y: squareY - labelGap - labelH, width: sq, height: labelH)
                v.addSubview(name)
            }
        }
        contentView = v
        // Don't let AppKit hand first-responder to the first name field — the
        // window would open with a swatch's label focused and selected blue.
        initialFirstResponder = v
        makeFirstResponder(nil)
    }

    /// Close the palette, sample on the next runloop pass (the loupe must not be
    /// launched while this floating panel is up), then reopen once the pick ends.
    @objc private func pickTapped() {
        close()
        DispatchQueue.main.async { [weak self] in
            self?.appDelegate?.sampleColor(reopenHistory: true)
        }
    }

    @objc private func clearTapped() { ColorHistory.clearRecents(); reload() }
    @objc private func formatChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.colorFormat = ColorFormat(rawValue: sender.indexOfSelectedItem) ?? .hex
        reload()
    }

    /// Save a typed name as a custom name for that color; empty or the auto-name
    /// reverts to the auto-generated one.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let hex = field.identifier?.rawValue else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        ColorNames.setCustom(hex, (typed.isEmpty || typed == hex) ? nil : typed)
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }
}

/// A borderless icon button that reports its own hover, so the pin can swap
/// between "pin.fill" and "pin.slash.fill" while the pointer is over it.
final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// One color square in the palette. Click it to copy its code; DRAG it out to get
/// the swatch as a PNG (into a folder, a doc, anywhere that takes an image); and
/// use the pin at its top-right to keep it: the pin appears hollow on hover, turns
/// solid and stays visible once pinned, and shows a slash on hover when pinned to
/// signal that clicking removes it. The full code is the square's tooltip.
final class ColorSquare: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private let entry: ColorEntry
    private let onCopyCode: () -> Void
    private let onTogglePin: () -> Void
    private let pin = HoverButton()
    private var tracking: NSTrackingArea?
    private var hovered = false, pinHovered = false
    private var mouseDownAt: NSPoint?
    private var dragged = false
    private let promiseQueue = OperationQueue()

    init(entry: ColorEntry, size: CGFloat, code: String,
         onCopyCode: @escaping () -> Void, onTogglePin: @escaping () -> Void) {
        self.entry = entry
        self.onCopyCode = onCopyCode; self.onTogglePin = onTogglePin
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = (entry.color.usingColorSpace(.sRGB) ?? entry.color).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        toolTip = code

        pin.isBordered = true
        pin.bezelStyle = .circular
        pin.contentTintColor = ColorSquare.contrastInk(entry.color)
        pin.target = self
        pin.action = #selector(togglePin)
        pin.frame = NSRect(x: size - 26, y: size - 26, width: 20, height: 20)
        pin.onHover = { [weak self] inside in
            self?.pinHovered = inside
            self?.updatePin()
        }
        addSubview(pin)
        updatePin()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Unpinned: hollow pin, shown only while the square is hovered. Pinned: solid
    /// pin, always shown — and a slashed pin while the pointer is on it, so it's
    /// clear a click will unpin.
    private func updatePin() {
        let pinned = entry.pinned
        pin.isHidden = !pinned && !hovered
        let sym = pinned ? (pinHovered ? "pin.slash.fill" : "pin.fill") : "pin"
        pin.image = NSImage(systemSymbolName: sym, accessibilityDescription: pinned ? "Unpin" : "Pin")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        pin.toolTip = pinned ? "Unpin this color" : "Pin this color to keep it"
    }

    @objc private func togglePin() { onTogglePin() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updatePin() }
    override func mouseExited(with event: NSEvent) { hovered = false; updatePin() }

    // Click = copy the code; drag = pull the swatch out as a PNG. The copy fires
    // on mouse-up only if no drag started, so dragging never also copies.
    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let start = mouseDownAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }   // real drag, not a jittery click
        dragged = true

        // A file promise, so it can be dropped into Finder as <hex>.png as well as
        // into apps that take image data.
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let preview = NSImage(size: bounds.size)
        preview.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: bounds.size), xRadius: 12, yRadius: 12)
        (entry.color.usingColorSpace(.sRGB) ?? entry.color).setFill()
        path.fill()
        preview.unlockFocus()
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onCopyCode() }
        mouseDownAt = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    // MARK: File promise (the dragged-out PNG)

    /// Name the dragged-out file after the swatch's label — its custom name if it
    /// has one, otherwise the hex (with the "#" kept). Only characters a filename
    /// can't hold are swapped out.
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType t: String) -> String {
        let label = ColorNames.display(entry.hex)
        let safe = label.replacingOccurrences(of: "/", with: "-")
                        .replacingOccurrences(of: ":", with: "-")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? entry.hex : safe) + ".png"
    }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let png = ColorSwatch.png(entry.color) else { completionHandler(nil); return }
            try png.write(to: url)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    /// Black on light colors, white on dark — for the pin badge.
    static func contrastInk(_ color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.6 ? .black : .white
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
