// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

/// Layer 2 of the agent operating mask: recolors the page's own elements —
/// headings, links, buttons, selection — from the Space theme, so an operated
/// page reads as the agent's rather than merely being filmed over. The design
/// specifies separate light and dark palettes, so the sheet is generated for
/// the window's current appearance and re-issued when that flips.
///
/// Layer 1 (`EdgeFogOverlayView`) is a native AppKit wash and cannot reach the
/// DOM, so this half is injected as a stylesheet over CDP through the app-owned
/// `AppDevToolsPageSession` — the same transport in-app autofill uses. Nothing
/// goes through the agent: the browser styles its own pages.
///
/// Scope is the agent window, not a single tab. Every page target in the
/// window belongs to the agent while it holds control, and window membership is
/// something CDP can answer (`Browser.getWindowForTarget`) whereas a Phi tab id
/// is not addressable over CDP at all.
///
/// A session per styled target is held open for the duration: scripts added
/// with `Page.addScriptToEvaluateOnNewDocument` are session state, and Chromium
/// drops them when the session detaches, taking re-application on navigation
/// with it.
@MainActor
final class AgentPageTheme {
    static let shared = AgentPageTheme()

    private init() {}

    /// Marks the injected element so re-application replaces rather than stacks,
    /// and so removal needs no bookkeeping in the page.
    private static let styleElementId = "phi-agent-page-theme"

    private struct StyledTarget {
        let session: AppDevToolsPageSession
        /// `Page.addScriptToEvaluateOnNewDocument` handle, for clean removal.
        let scriptIdentifier: String?
        /// The sheet this target currently carries. The palette differs
        /// between light and dark appearance, so an already-styled target is
        /// only up to date while its sheet matches the one being applied.
        let css: String
    }

    /// Live sessions keyed by window, then by CDP target id.
    private var styled: [Int: [String: StyledTarget]] = [:]

    /// Guards against a re-entrant apply while the previous one is still
    /// dialing — the mask can flip faster than CDP round-trips complete.
    private var inFlightWindows = Set<Int>()

    // MARK: - Lifecycle

    /// Styles every page in `windowId`. Safe to call repeatedly; targets
    /// already carrying the requested sheet are skipped, so tab switches and
    /// new tabs converge without tearing down what is already applied — while
    /// a palette change (theme color, or the light/dark appearance the design
    /// styles differently) restyles live targets in place.
    func apply(windowId: Int, themeColor: NSColor, appearance: Appearance) {
        guard windowId != 0, !inFlightWindows.contains(windowId) else { return }
        let css = Self.styleSheet(
            for: Palette(themeColor: themeColor, appearance: appearance))
        inFlightWindows.insert(windowId)
        Task { @MainActor in
            defer { inFlightWindows.remove(windowId) }
            await applyToTargets(windowId: windowId, css: css)
        }
    }

    /// Removes the stylesheet from every page styled in `windowId` and drops the
    /// sessions. Also used on task completion, so a Space handed back or closed
    /// never leaves a recolored page behind.
    func clear(windowId: Int) {
        guard let targets = styled.removeValue(forKey: windowId) else { return }
        let removal = "document.getElementById('\(Self.styleElementId)')?.remove()"
        Task { @MainActor in
            for (_, target) in targets {
                if let identifier = target.scriptIdentifier {
                    _ = try? await target.session.command(
                        "Page.removeScriptToEvaluateOnNewDocument",
                        params: ["identifier": identifier])
                }
                _ = try? await target.session.command(
                    "Runtime.evaluate",
                    params: ["expression": removal, "returnByValue": true])
                target.session.close()
            }
        }
    }

    private func applyToTargets(windowId: Int, css: String) async {
        let started = Date()
        let browser: AppDevToolsPageSession
        do {
            browser = try await AppDevToolsPageSession.openBrowser()
        } catch {
            // Loud on purpose: every failure below is a silent no-op that looks
            // exactly like "the design didn't land", so it must be greppable.
            AppLogError("[AgentPageTheme] browser session failed: \(error)")
            return
        }
        defer { browser.close() }

        let infos: [[String: Any]]
        do {
            let result = try await browser.command("Target.getTargets")
            infos = result["targetInfos"] as? [[String: Any]] ?? []
        } catch {
            AppLogError("[AgentPageTheme] Target.getTargets failed: \(error)")
            return
        }

        let injection = Self.injectionScript(css: css)
        var matched = 0
        for info in infos {
            guard info["type"] as? String == "page",
                  let targetId = info["targetId"] as? String,
                  styled[windowId]?[targetId]?.css != css else { continue }

            // A target styled with an outdated sheet (appearance flip, theme
            // change) restyles through its held session — its window
            // membership was proven when it was first styled, and the
            // injection replaces the style element's content in place.
            if let target = styled[windowId]?[targetId] {
                matched += 1
                if let identifier = target.scriptIdentifier {
                    _ = try? await target.session.command(
                        "Page.removeScriptToEvaluateOnNewDocument",
                        params: ["identifier": identifier])
                }
                let added = try? await target.session.command(
                    "Page.addScriptToEvaluateOnNewDocument",
                    params: ["source": injection])
                do {
                    _ = try await target.session.command(
                        "Runtime.evaluate",
                        params: ["expression": injection, "returnByValue": true])
                } catch {
                    AppLogError("[AgentPageTheme] restyle failed for \(targetId): \(error)")
                }
                styled[windowId, default: [:]][targetId] = StyledTarget(
                    session: target.session,
                    scriptIdentifier: added?["identifier"] as? String,
                    css: css)
                continue
            }

            // Window membership is the ownership test; the same id space the
            // skill matches `AgentTask.windowId` against.
            guard let owner = try? await browser.command(
                    "Browser.getWindowForTarget", params: ["targetId": targetId]),
                  owner["windowId"] as? Int == windowId else { continue }
            matched += 1
            guard let session = try? await AppDevToolsPageSession.open(targetId: targetId)
            else {
                AppLogError("[AgentPageTheme] attach failed for target \(targetId)")
                continue
            }

            _ = try? await session.command("Page.enable")
            // Persist across the agent's navigations…
            let added = try? await session.command(
                "Page.addScriptToEvaluateOnNewDocument", params: ["source": injection])
            // …and cover the document already loaded.
            do {
                _ = try await session.command(
                    "Runtime.evaluate",
                    params: ["expression": injection, "returnByValue": true])
            } catch {
                AppLogError("[AgentPageTheme] inject failed for \(targetId): \(error)")
            }

            styled[windowId, default: [:]][targetId] = StyledTarget(
                session: session,
                scriptIdentifier: added?["identifier"] as? String,
                css: css)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        AppLogInfo("[AgentPageTheme] windowId=\(windowId) pages=\(infos.count) " +
                   "styled=\(matched) in \(ms)ms")
    }

    // MARK: - Injection

    /// Runs both as a new-document script (before any DOM exists) and against an
    /// already-parsed document, so it installs on whichever it finds.
    private static func injectionScript(css: String) -> String {
        """
        (() => {
          const id = '\(styleElementId)';
          const css = \(jsStringLiteral(css));
          const apply = () => {
            const root = document.documentElement;
            if (!root) return;
            let el = document.getElementById(id);
            if (!el) {
              el = document.createElement('style');
              el.id = id;
              root.appendChild(el);
            }
            if (el.textContent !== css) el.textContent = css;
          };
          apply();
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', apply, { once: true });
          }
        })();
        """
    }

    /// JSON is a subset of JS literal syntax, so encoding the sheet as a JSON
    /// string is enough to survive quotes, newlines and backslashes in the CSS.
    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: [value], options: []),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Palette

    /// The design's derivation: one theme color fans out into the shades the
    /// stylesheet needs. Authored in HSL (not AppKit's HSB) to stay faithful to
    /// the source, whose lightness clamps have no HSB equivalent.
    ///
    /// The design's dark variant keeps the chosen color as the theme source
    /// but rebuilds every ink for low-luminance surfaces: text roles are
    /// `color-mix` lifts toward white, and the soft fills become translucent
    /// primary washes instead of near-white solids. Those per-appearance rule
    /// values live here so the stylesheet template stays single.
    private struct Palette {
        let primary: String
        let deep: String
        let secondary: String
        let accent: String
        let soft: String
        let onPrimary: String

        // Appearance-resolved rule values. Light references the palette
        // variables directly; dark carries the design's dark-block
        // expressions.
        let heading1: String
        let heading2: String
        let subheading: String
        let link: String
        let accentLine: String
        let tableHeadText: String
        let scrollbar: String
        let buttonShadow: String

        init(themeColor: NSColor, appearance: Appearance) {
            let color = themeColor.usingColorSpace(.sRGB) ?? themeColor
            let r = Int((color.redComponent * 255).rounded())
            let g = Int((color.greenComponent * 255).rounded())
            let b = Int((color.blueComponent * 255).rounded())
            primary = String(format: "#%02X%02X%02X", r, g, b)

            let hsl = Palette.rgbToHSL(r: r, g: g, b: b)
            let saturation = max(42, min(78, hsl.s))
            deep = Palette.hslToHex(h: hsl.h, s: saturation,
                                    l: max(20, min(35, hsl.l * 0.62)))
            secondary = Palette.hslToHex(h: (hsl.h + 28).truncatingRemainder(dividingBy: 360),
                                         s: max(36, saturation - 10), l: 48)
            accent = Palette.hslToHex(h: (hsl.h + 330).truncatingRemainder(dividingBy: 360),
                                      s: min(86, saturation + 10), l: 61)
            onPrimary = hsl.l > 66 ? "#17151A" : "#FFFFFF"

            switch appearance {
            case .light:
                soft = Palette.hslToHex(h: hsl.h, s: max(24, saturation * 0.45), l: 94)
                heading1 = "var(--chroma-deep)"
                heading2 = "var(--chroma-primary)"
                subheading = "var(--chroma-secondary)"
                link = "var(--chroma-primary)"
                accentLine = "var(--chroma-accent)"
                tableHeadText = "var(--chroma-deep)"
                scrollbar = "var(--chroma-primary) var(--chroma-soft)"
                buttonShadow = "0 7px 20px rgba(\(r), \(g), \(b), .18)"
            case .dark:
                // The design's dark block, generalized: heading and link inks
                // are lifted toward white (48/46% for the two display
                // headings, 70% for secondary text and links, 64% for the
                // active-surface ink), soft fills become a 14% primary wash,
                // the scrollbar thumb a 45% one, and the button glow runs
                // slightly larger and hotter.
                soft = "rgba(\(r), \(g), \(b), .14)"
                heading1 = "color-mix(in srgb, var(--chroma-primary) 48%, white)"
                heading2 = "color-mix(in srgb, var(--chroma-primary) 46%, white)"
                subheading = "color-mix(in srgb, var(--chroma-secondary) 70%, white)"
                link = "color-mix(in srgb, var(--chroma-primary) 70%, white)"
                accentLine = "color-mix(in srgb, var(--chroma-accent) 70%, white)"
                tableHeadText = "color-mix(in srgb, var(--chroma-primary) 64%, white)"
                scrollbar = "rgba(\(r), \(g), \(b), .45) transparent"
                buttonShadow = "0 8px 24px rgba(\(r), \(g), \(b), .24)"
            }
        }

        private static func rgbToHSL(r: Int, g: Int, b: Int)
            -> (h: CGFloat, s: CGFloat, l: CGFloat) {
            let red = CGFloat(r) / 255, green = CGFloat(g) / 255, blue = CGFloat(b) / 255
            let maxV = max(red, green, blue), minV = min(red, green, blue)
            let delta = maxV - minV
            let l = (maxV + minV) / 2
            var h: CGFloat = 0
            if delta != 0 {
                if maxV == red {
                    h = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
                } else if maxV == green {
                    h = 60 * ((blue - red) / delta + 2)
                } else {
                    h = 60 * ((red - green) / delta + 4)
                }
            }
            let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
            return ((h + 360).truncatingRemainder(dividingBy: 360), s * 100, l * 100)
        }

        private static func hslToHex(h: CGFloat, s: CGFloat, l: CGFloat) -> String {
            let sat = s / 100, light = l / 100
            let c = (1 - abs(2 * light - 1)) * sat
            let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
            let m = light - c / 2
            var rgb: (CGFloat, CGFloat, CGFloat)
            switch h {
            case ..<60:   rgb = (c, x, 0)
            case ..<120:  rgb = (x, c, 0)
            case ..<180:  rgb = (0, c, x)
            case ..<240:  rgb = (0, x, c)
            case ..<300:  rgb = (x, 0, c)
            default:      rgb = (c, 0, x)
            }
            return String(format: "#%02X%02X%02X",
                          Int(((rgb.0 + m) * 255).rounded()),
                          Int(((rgb.1 + m) * 255).rounded()),
                          Int(((rgb.2 + m) * 255).rounded()))
        }
    }

    /// The design's selector set. `:where()` keeps specificity at zero so a page
    /// author's own rules still win on structure; only the colors are forced.
    /// The design's own 20% overlay rule is deliberately absent — that is
    /// layer 1, already drawn natively over the whole tab. Rule values whose
    /// expression differs between the design's light and dark blocks come in
    /// pre-resolved on the palette; the selector set itself never varies.
    private static func styleSheet(for p: Palette) -> String {
        """
        :root{--chroma-primary:\(p.primary);--chroma-deep:\(p.deep);\
        --chroma-secondary:\(p.secondary);--chroma-accent:\(p.accent);\
        --chroma-soft:\(p.soft);--chroma-on:\(p.onPrimary);\
        accent-color:var(--chroma-primary)!important}
        html{scrollbar-color:\(p.scrollbar)}
        :where(h1){color:\(p.heading1)!important;\
        text-decoration-color:\(p.accentLine)!important}
        :where(h2){color:\(p.heading2)!important;\
        text-decoration-color:\(p.subheading)!important}
        :where(h3,h4,h5,h6){color:\(p.subheading)!important}
        :where(a:not([class*="button"]):not([class*="btn"])){\
        color:\(p.link)!important;\
        text-decoration-color:\(p.accentLine)!important;\
        text-decoration-thickness:.09em}
        :where(button,[role="button"],input[type="button"],input[type="submit"],\
        a[class*="button"],a[class*="btn"]){\
        background-color:var(--chroma-primary)!important;\
        border-color:var(--chroma-deep)!important;color:var(--chroma-on)!important;\
        box-shadow:\(p.buttonShadow)}
        :where(blockquote){border-color:var(--chroma-primary)!important;\
        background:var(--chroma-soft)!important}
        :where(mark){background:var(--chroma-accent)!important;color:#17151a!important}
        :where(hr){border-color:var(--chroma-secondary)!important;opacity:.35}
        :where(input,textarea,select):focus{\
        outline-color:var(--chroma-primary)!important;\
        border-color:var(--chroma-primary)!important}
        :where(th){background-color:var(--chroma-soft)!important;\
        color:\(p.tableHeadText)!important}
        ::selection{background:var(--chroma-primary);color:var(--chroma-on)}
        """
    }
}
