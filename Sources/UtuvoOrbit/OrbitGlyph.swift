import AppKit
import OrbitCore

enum OrbitGlyph {
    /// Shared vector renderer for the real menu bar icon and the detail
    /// view. `.combined` (default, v0.2-identical when `ringCenter ==
    /// .network`) is one 27pt ring+center glyph. `.classic` renders three
    /// separate fixed-width symbols instead — see `classicImage`.
    @MainActor static func image(_ s: StatusSnapshot, desktop: DesktopRing, size: CGFloat = 28,
                                foreground: NSColor = .labelColor, color: Bool = true,
                                ringCenter: RingCenter = .network, glyphStyle: GlyphStyle = .combined) -> NSImage {
        if glyphStyle == .classic {
            return classicImage(s, desktop: desktop, size: size, foreground: foreground, color: color)
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
        context.scaleBy(x: size / 32, y: size / 32)
        context.translateBy(x: 0, y: 32)
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        func stroke(_ points: [CGPoint], _ ink: NSColor, width: CGFloat) {
            guard let first = points.first else { return }
            context.beginPath(); context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            context.setStrokeColor(ink.cgColor); context.setLineWidth(width); context.strokePath()
        }
        func arc(_ start: Double, _ end: Double, radius: CGFloat, center: CGPoint, ink: NSColor, width: CGFloat) {
            guard end > start else { return }
            let steps = max(2, Int(end - start))
            let points = (0...steps).map { i -> CGPoint in
                let angle = (start + (end - start) * Double(i) / Double(steps)) * .pi / 180
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
            stroke(points, ink, width: width)
        }
        let center = CGPoint(x: 16, y: 15.5)
        let track = foreground.withAlphaComponent(0.22)
        let hidesRing = s.machine == .desktop && desktop == .hidden
        var accent = foreground
        if color {
            if s.machine == .desktop && desktop == .cpu { accent = NSColor.systemTeal }
            if s.machine == .laptop, let battery = s.battery {
                if battery.charging { accent = .systemGreen }
                else if let fraction = battery.fraction, fraction <= 0.2 { accent = .systemRed }
            }
        }
        if !hidesRing {
            arc(140, 250, radius: 13, center: center, ink: track, width: 2.5)
            arc(290, 400, radius: 13, center: center, ink: track, width: 2.5)
            if let value = s.ringFraction(desktop: desktop), value.isFinite {
                let amount = min(1, max(0, value)) * 220
                arc(140, 140 + min(110, amount), radius: 13, center: center, ink: accent, width: 2.5)
                if amount > 110 { arc(290, 290 + amount - 110, radius: 13, center: center, ink: accent, width: 2.5) }
            }
        }
        let centerContent = CenterContent.resolve(snapshot: s, desktopRing: desktop, ringCenter: ringCenter)
        // Top slot: normally explains the ring (charging bolt / CPU chip /
        // power plug / laptop dot). When the CENTER is showing a percent
        // numeral instead of the network mark, that network information
        // would otherwise vanish entirely — so a miniature version of it
        // takes over the top slot instead of the CPU-chip/dot mark (the
        // charging bolt case can never coincide with percent: charging
        // always makes `CenterContent.resolve` fall back to `.network`).
        if case .percent = centerContent {
            drawNetworkMark(s.connection, wifiStrength: s.wifiStrength, in: context, center: CGPoint(x: 16, y: 4.5), scale: 0.34,
                            foreground: foreground, track: track, stroke: stroke, arc: arc)
        } else if s.machine == .laptop && s.battery?.charging == true {
            context.beginPath(); context.move(to: CGPoint(x: 17, y: 0.5))
            for point in [CGPoint(x: 13.5, y: 5), CGPoint(x: 16, y: 5), CGPoint(x: 15, y: 8),
                          CGPoint(x: 19, y: 3.5), CGPoint(x: 16.5, y: 3.5)] { context.addLine(to: point) }
            context.closePath(); context.setFillColor(accent.cgColor); context.fillPath()
        } else if s.machine == .desktop && desktop == .cpu {
            context.setFillColor(accent.cgColor)
            context.fill(CGRect(x: 14, y: 2.5, width: 4, height: 4))
            for x in [14.8, 17.2] {
                stroke([CGPoint(x: x, y: 1), CGPoint(x: x, y: 8)], accent, width: 0.9)
            }
        } else if s.machine == .desktop && desktop == .power {
            stroke([CGPoint(x: 14, y: 1.5), CGPoint(x: 14, y: 5)], foreground, width: 1.2)
            stroke([CGPoint(x: 18, y: 1.5), CGPoint(x: 18, y: 5)], foreground, width: 1.2)
            stroke([CGPoint(x: 13.5, y: 4), CGPoint(x: 13.5, y: 5.5), CGPoint(x: 16, y: 7),
                    CGPoint(x: 18.5, y: 5.5), CGPoint(x: 18.5, y: 4)], foreground, width: 1.2)
        } else if s.machine == .laptop {
            context.setFillColor(foreground.withAlphaComponent(0.5).cgColor)
            context.fillEllipse(in: CGRect(x: 15, y: 3.5, width: 2, height: 2))
        }

        switch centerContent {
        case .percent(let value, _):
            // Centered on the RING's own center (15.5), not the old y21
            // network-icon position — the numeral previously sat visibly
            // low relative to the ring it's supposed to be the center of.
            drawCenterPercent(value, in: context, center: CGPoint(x: 16, y: 15.5), ink: foreground)
        case .network:
            drawNetworkMark(s.connection, wifiStrength: s.wifiStrength, in: context, center: CGPoint(x: 16, y: 21),
                            foreground: foreground, track: track, stroke: stroke, arc: arc)
        }
        drawVolume(hasAudioOutput: s.hasAudioOutput, muted: s.muted, volume: s.volume, in: context,
                  dots: (0..<4).map { CGRect(x: 8.2 + Double($0) * 4.5, y: $0 == 0 || $0 == 3 ? 25 : 26.3, width: 2.6, height: 2.6) },
                  foreground: foreground, track: track, stroke: stroke)
        // Local, non-color shape cue for degraded states (also visible with
        // `color == false` / colorful off) — a small triangle, never the
        // only signal (full detail is in the panel/AX), never widening the
        // glyph regardless of how many reasons are active at once.
        if AttentionAnalysis.isDegraded(snapshot: s) {
            let warnInk = color ? NSColor.systemRed : foreground
            context.beginPath()
            context.move(to: CGPoint(x: 26, y: 1.5))
            context.addLine(to: CGPoint(x: 29.5, y: 7.5))
            context.addLine(to: CGPoint(x: 22.5, y: 7.5))
            context.closePath()
            context.setFillColor(warnInk.cgColor); context.fillPath()
        }
        image.unlockFocus()
        image.isTemplate = !color
        return image
    }

    /// SF monospaced digits so 0/8/99/100 keep consistent width at a real
    /// 27pt render. No "%" glyph drawn — the unit is implicit (explained in
    /// the panel/tooltip/AX label instead), which keeps 3-digit "100"
    /// legible in the same space as "8".
    @MainActor private static func drawCenterPercent(_ value: Double, in context: CGContext, center: CGPoint, ink: NSColor) {
        let percent = Int((min(1, max(0, value)) * 100).rounded())
        let text = "\(percent)"
        let fontSize: CGFloat = percent >= 100 ? 8.5 : 10.5
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink]))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        // The outer context is already flipped (y increases downward) to
        // match the rest of this renderer's hand-computed points; CoreText
        // draws in its own y-up space, so flip back locally around the
        // glyph's own bounds instead of drawing upside down.
        context.translateBy(x: center.x - bounds.width / 2 - bounds.origin.x,
                            y: center.y + bounds.height / 2 + bounds.origin.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Every case is expressed as an offset from `center` (scaled by
    /// `scale`) — previously Ethernet/offline/checking used hardcoded
    /// ABSOLUTE coordinates tuned only for the one call site at
    /// `center: (16, 21)`, silently ignoring whatever `center` the caller
    /// actually passed. That broke classic mode's network cell (centered at
    /// `(16, 16)`, not `(16, 21)`) for exactly those three connection types,
    /// and made a miniature/repositioned version impossible. At
    /// `center: (16, 21), scale: 1` this renders pixel-identical to the
    /// original hand-tuned geometry.
    @MainActor private static func drawNetworkMark(_ connection: Connection, wifiStrength: Int?, in context: CGContext, center: CGPoint,
                                                    scale: CGFloat = 1,
                                                    foreground: NSColor, track: NSColor,
                                                    stroke: ([CGPoint], NSColor, CGFloat) -> Void,
                                                    arc: (Double, Double, CGFloat, CGPoint, NSColor, CGFloat) -> Void) {
        func pt(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: center.x + dx * scale, y: center.y + dy * scale) }
        switch connection {
        case .wifi:
            if let level = wifiStrength {
                for i in 1...3 { arc(225, 315, CGFloat(i) * 3.2 * scale, center, i <= level ? foreground : track, max(0.7, 1.9 * scale)) }
                context.setFillColor(foreground.cgColor)
                context.fillEllipse(in: CGRect(x: center.x - 1.2 * scale, y: center.y - 1.2 * scale, width: 2.4 * scale, height: 2.4 * scale))
            } else {
                // Unknown signal strength must not silently read as "0
                // bars" (a confirmed terrible signal) — all arcs dim AND a
                // hollow (not filled) center dot, a distinct combination
                // from both a real 0-bar reading and any real 1-3 bar one.
                for i in 1...3 { arc(225, 315, CGFloat(i) * 3.2 * scale, center, track, max(0.7, 1.9 * scale)) }
                context.setStrokeColor(track.cgColor); context.setLineWidth(max(0.6, 0.9 * scale))
                context.strokeEllipse(in: CGRect(x: center.x - 1.2 * scale, y: center.y - 1.2 * scale, width: 2.4 * scale, height: 2.4 * scale))
            }
        case .ethernet:
            stroke([pt(-6, -1.5), pt(-6, -9.5), pt(6, -9.5), pt(6, -1.5), pt(2.5, -1.5), pt(2.5, 1),
                    pt(-2.5, 1), pt(-2.5, -1.5), pt(-6, -1.5)], foreground, max(0.7, 1.5 * scale))
            for dx: CGFloat in [-3, 0, 3] { stroke([pt(dx, -8.5), pt(dx, -6)], foreground, max(0.5, 1 * scale)) }
        case .other:
            arc(0, 360, 6 * scale, center, foreground, max(0.7, 1.5 * scale))
            stroke([pt(-6, 0), pt(6, 0)], foreground, max(0.5, 1 * scale))
            stroke([pt(0, -6), pt(0, 6)], foreground, max(0.5, 1 * scale))
        case .offline:
            arc(225, 315, 8 * scale, center, track, max(0.7, 1.8 * scale))
            stroke([pt(-5, -5), pt(5, 6)], foreground, max(0.7, 1.8 * scale))
        case .checking:
            for dx: CGFloat in [-4, 0, 4] {
                context.setFillColor(track.cgColor)
                context.fillEllipse(in: CGRect(x: center.x + dx * scale - 1 * scale, y: center.y - 5 * scale, width: 2 * scale, height: 2 * scale))
            }
        }
    }

    /// Availability is checked FIRST (via `VolumeDisplay.resolve`) — a
    /// stale `volume`/`muted` reading can never leak through once
    /// `hasAudioOutput == false`. Three genuinely distinct visuals: filled
    /// dots for a real level (muted additionally gets the diagonal slash,
    /// same as before), all-hollow dots for "unknown" (unreadable/still
    /// loading), all-hollow dots WITH the slash for "confirmed unavailable"
    /// — never just a bare 4-dot row that could be mistaken for a real
    /// (possibly stale) reading.
    @MainActor private static func drawVolume(hasAudioOutput: Bool?, muted: Bool, volume: Double?, in context: CGContext,
                                              dots: [CGRect], foreground: NSColor, track: NSColor,
                                              stroke: ([CGPoint], NSColor, CGFloat) -> Void) {
        let state = VolumeDisplay.resolve(hasAudioOutput: hasAudioOutput, muted: muted, volume: volume)
        switch state {
        case .level(let count, let isMuted):
            for (i, rect) in dots.enumerated() {
                context.setFillColor((i < count ? foreground : track).cgColor)
                context.fillEllipse(in: rect)
            }
            if isMuted, let first = dots.first, let last = dots.last {
                stroke([CGPoint(x: first.minX - 0.2, y: last.maxY + 0.5), CGPoint(x: last.maxX + 0.2, y: first.minY - 0.5)], foreground, 1)
            }
        case .unknown:
            for rect in dots {
                context.setStrokeColor(track.cgColor); context.setLineWidth(0.8); context.strokeEllipse(in: rect)
            }
        case .unavailable:
            for rect in dots {
                context.setStrokeColor(track.cgColor); context.setLineWidth(0.8); context.strokeEllipse(in: rect)
            }
            if let first = dots.first, let last = dots.last {
                stroke([CGPoint(x: first.minX - 0.2, y: last.maxY + 0.5), CGPoint(x: last.maxX + 0.2, y: first.minY - 0.5)], foreground, 1)
            }
        }
    }

    /// Classic mode's OWN volume symbol — a recognizable speaker silhouette
    /// with expanding "sound wave" arcs — NOT the combined glyph's 4-dot
    /// row (`drawVolume` above stays exactly as-is; only classic's
    /// presentation changes here, per repair1's proven "four anonymous
    /// dots" defect). Same availability-first precedence as `drawVolume`,
    /// expressed as 4 genuinely distinct SHAPE combinations so a
    /// mono/template render keeps the same distinctions color alone would
    /// lose:
    /// - a real level: FILLED body + 0...3 filled wave arcs, no slash.
    /// - muted: FILLED body (a real, present device) + all-dim wave arcs +
    ///   a diagonal slash — never "zero waves" alone, which would look
    ///   identical to unknown.
    /// - confirmed unavailable: HOLLOW (outline-only) body + slash.
    /// - unknown/unreadable: HOLLOW body, no waves, no slash — the only
    ///   fully "empty" combination, so it can never be confused with muted
    ///   or unavailable.
    @MainActor private static func drawClassicSpeaker(hasAudioOutput: Bool?, muted: Bool, volume: Double?,
                                                       in ctx: CGContext, foreground: NSColor, track: NSColor,
                                                       stroke: ([CGPoint], NSColor, CGFloat) -> Void,
                                                       arc: (Double, Double, CGFloat, CGPoint, NSColor, CGFloat) -> Void) {
        let bodyPoints = [CGPoint(x: 6, y: 13), CGPoint(x: 10, y: 13), CGPoint(x: 16, y: 7),
                          CGPoint(x: 16, y: 25), CGPoint(x: 10, y: 19), CGPoint(x: 6, y: 19)]
        func drawBody(filled: Bool, ink: NSColor) {
            ctx.beginPath(); ctx.move(to: bodyPoints[0])
            for point in bodyPoints.dropFirst() { ctx.addLine(to: point) }
            ctx.closePath()
            if filled { ctx.setFillColor(ink.cgColor); ctx.fillPath() }
            else { ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1.3); ctx.strokePath() }
        }
        let hornTip = CGPoint(x: 16, y: 16)
        let slash: [CGPoint] = [CGPoint(x: 5, y: 24), CGPoint(x: 25, y: 6)]
        switch VolumeDisplay.resolve(hasAudioOutput: hasAudioOutput, muted: muted, volume: volume) {
        case .level(let count, let isMuted):
            drawBody(filled: true, ink: foreground)
            let waveLevel = isMuted ? 0 : min(3, count)
            for tier in 1...3 {
                arc(315, 405, CGFloat(tier) * 3 + 3, hornTip, tier <= waveLevel ? foreground : track, 1.2)
            }
            if isMuted { stroke(slash, foreground, 1.2) }
        case .unknown:
            drawBody(filled: false, ink: track)
        case .unavailable:
            drawBody(filled: false, ink: track)
            stroke(slash, foreground, 1.2)
        }
    }

    /// `drawNetworkMark`'s `center` is each connection type's own
    /// hand-tuned ANCHOR point, not its visual bounding-box center — proven
    /// by root: Wi-Fi/Ethernet's ink sits almost entirely ABOVE `center`
    /// (their anchor is effectively a lower/base point), the globe already
    /// IS centered on its anchor, and offline/checking fall somewhere in
    /// between. Repair1's relative-coordinate fix aligned every connection
    /// type to the SAME anchor, but never corrected each type's own
    /// centroid against the classic cell's true vertical center — so the
    /// classic network cell looked visibly high next to battery/speaker
    /// (both of which sit visually centered on y=16). Values below are each
    /// connection's measured (dyMin+dyMax)/2 from `drawNetworkMark`'s own
    /// geometry. Combined mode's call sites are untouched — they still pass
    /// their own hand-tuned `center` directly, unaffected by this.
    private static func classicNetworkCenter(for connection: Connection, cellCenter: CGPoint) -> CGPoint {
        let centroidOffset: CGFloat
        switch connection {
        case .wifi: centroidOffset = -4.2
        case .ethernet: centroidOffset = -4.25
        case .other: centroidOffset = 0 // globe already centered on its own anchor
        case .offline: centroidOffset = -1
        case .checking: centroidOffset = -4
        }
        return CGPoint(x: cellCenter.x, y: cellCenter.y - centroidOffset)
    }

    // MARK: - Classic (three fixed-width symbols)

    /// Always `27pt` tall × up to `81pt` wide (three 27pt cells), regardless
    /// of health/degraded state — the layout never reflows. Each cell is a
    /// separate, independently-readable native/vector symbol: primary
    /// (battery/CPU/power), network, and volume. Desktop `.hidden` leaves
    /// cell 1 as an explicit empty reserved slot — it never fabricates a
    /// battery or CPU reading to fill the space.
    @MainActor private static func classicImage(_ s: StatusSnapshot, desktop: DesktopRing, size: CGFloat,
                                                 foreground: NSColor, color: Bool) -> NSImage {
        let cell: CGFloat = size
        let image = NSImage(size: NSSize(width: cell * 3, height: cell))
        image.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
        let track = foreground.withAlphaComponent(0.22)
        var accent = foreground
        if color {
            if s.machine == .desktop && desktop == .cpu { accent = .systemTeal }
            if s.machine == .laptop, let battery = s.battery {
                if battery.charging { accent = .systemGreen }
                else if let fraction = battery.fraction, fraction <= 0.2 { accent = .systemRed }
            }
        }

        func withCell(_ index: Int, _ body: (CGContext) -> Void) {
            context.saveGState()
            context.scaleBy(x: cell / 32, y: cell / 32)
            context.translateBy(x: CGFloat(index) * 32, y: 32)
            context.scaleBy(x: 1, y: -1)
            context.setLineCap(.round)
            body(context)
            context.restoreGState()
        }
        func stroke(_ ctx: CGContext, _ points: [CGPoint], _ ink: NSColor, width: CGFloat) {
            guard let first = points.first else { return }
            ctx.beginPath(); ctx.move(to: first)
            for point in points.dropFirst() { ctx.addLine(to: point) }
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(width); ctx.strokePath()
        }
        func arc(_ ctx: CGContext, _ start: Double, _ end: Double, radius: CGFloat, center: CGPoint, ink: NSColor, width: CGFloat) {
            guard end > start else { return }
            let steps = max(2, Int(end - start))
            let points = (0...steps).map { i -> CGPoint in
                let angle = (start + (end - start) * Double(i) / Double(steps)) * .pi / 180
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
            stroke(ctx, points, ink, width: width)
        }

        // Cell 0: primary — battery (laptop) / CPU or power (desktop) / a
        // blank reserved slot (hidden) / a dashed placeholder (unknown
        // machine). A valid 0% battery draws a genuinely EMPTY body (no
        // fabricated minimum-width fill); an unreadable/invalid fraction
        // draws the outline only with a small "?" dash, visibly different
        // from "confirmed empty".
        withCell(0) { ctx in
            switch s.machine {
            case .laptop:
                let bodyRect = CGRect(x: 8, y: 10, width: 14, height: 12)
                ctx.setStrokeColor(track.cgColor); ctx.setLineWidth(1.5)
                ctx.stroke(bodyRect)
                ctx.fill(CGRect(x: 22, y: 14, width: 2, height: 4))
                if let fraction = s.battery?.fraction, fraction.isFinite, fraction >= 0, fraction <= 1 {
                    let width = (bodyRect.width - 2) * CGFloat(fraction) // 0 draws nothing — never a fake minimum
                    if width > 0 {
                        ctx.setFillColor(accent.cgColor)
                        ctx.fill(CGRect(x: bodyRect.minX + 1, y: bodyRect.minY + 1, width: width, height: bodyRect.height - 2))
                    }
                } else {
                    stroke(ctx, [CGPoint(x: bodyRect.midX - 1.5, y: bodyRect.midY), CGPoint(x: bodyRect.midX + 1.5, y: bodyRect.midY)], track, width: 1.2)
                }
                if s.battery?.charging == true {
                    // LABEL-FINISH: a plain `foreground` stroke (repair2's
                    // fix for the color-mode green-fill case) is STILL
                    // invisible in MONOCHROME — `accent` never diverges
                    // from `foreground` there, so at a full/near-full
                    // battery the fill IS `foreground` too, and the bolt
                    // vanishes into it exactly like before, just for a
                    // different reason ("foreground always contrasts" was
                    // false). A transparent halo cut through whatever is
                    // underneath (`.clear` blend mode) guarantees real
                    // contrast regardless of fill color OR later template
                    // re-tinting, since erased (alpha 0) pixels stay
                    // transparent either way — then the crisp bolt line
                    // draws into that transparent gap.
                    let bolt = [CGPoint(x: 16, y: 9), CGPoint(x: 13.5, y: 15), CGPoint(x: 16, y: 15), CGPoint(x: 14.5, y: 23)]
                    ctx.saveGState()
                    ctx.setBlendMode(.clear)
                    stroke(ctx, bolt, foreground, width: 2.6)
                    ctx.restoreGState()
                    stroke(ctx, bolt, foreground, width: 1.2)
                }
            case .desktop where desktop == .cpu:
                let chipRect = CGRect(x: 11, y: 11, width: 10, height: 10)
                if let cpu = s.cpu, cpu.isFinite, cpu >= 0, cpu <= 1 {
                    // Outline + proportional fill (like the battery bar
                    // above), not an unconditional solid chip — repair2:
                    // "known CPU still draws the same full chip for every
                    // usage." A genuine 0% draws NO fill (no fake minimum),
                    // and the crisp accent-colored outline itself already
                    // differs from the unknown branch's dim `track` outline
                    // below, so 0% is never visually identical to unknown.
                    ctx.setStrokeColor(accent.cgColor); ctx.setLineWidth(1.2)
                    ctx.stroke(chipRect)
                    let innerHeight = chipRect.height - 2
                    let fillHeight = innerHeight * CGFloat(cpu)
                    if fillHeight > 0 {
                        ctx.setFillColor(accent.cgColor)
                        ctx.fill(CGRect(x: chipRect.minX + 1, y: chipRect.maxY - 1 - fillHeight, width: chipRect.width - 2, height: fillHeight))
                    }
                    for x: CGFloat in [12.5, 16, 19.5] { stroke(ctx, [CGPoint(x: x, y: 7), CGPoint(x: x, y: 11)], accent, width: 1) }
                    for x: CGFloat in [12.5, 16, 19.5] { stroke(ctx, [CGPoint(x: x, y: 21), CGPoint(x: x, y: 25)], accent, width: 1) }
                } else {
                    // Unknown usage: outline only, no fabricated fill. Dim
                    // `track` outline (vs. the known branch's crisp accent
                    // outline above) is itself the known-0-vs-unknown cue,
                    // independent of the fill (which is absent in both).
                    ctx.setStrokeColor(track.cgColor); ctx.setLineWidth(1.2)
                    ctx.stroke(chipRect)
                    for x: CGFloat in [12.5, 16, 19.5] { stroke(ctx, [CGPoint(x: x, y: 7), CGPoint(x: x, y: 11)], track, width: 1) }
                    for x: CGFloat in [12.5, 16, 19.5] { stroke(ctx, [CGPoint(x: x, y: 21), CGPoint(x: x, y: 25)], track, width: 1) }
                }
            case .desktop where desktop == .power:
                stroke(ctx, [CGPoint(x: 13, y: 8), CGPoint(x: 13, y: 13)], foreground, width: 1.3)
                stroke(ctx, [CGPoint(x: 19, y: 8), CGPoint(x: 19, y: 13)], foreground, width: 1.3)
                stroke(ctx, [CGPoint(x: 12, y: 13), CGPoint(x: 12, y: 15), CGPoint(x: 16, y: 18),
                            CGPoint(x: 20, y: 15), CGPoint(x: 20, y: 13)], foreground, width: 1.3)
            case .desktop: // .hidden — explicit empty reserved slot, keeps the 3-cell width.
                break
            case .unknown:
                for i in 0..<3 {
                    ctx.setFillColor(track.cgColor)
                    ctx.fillEllipse(in: CGRect(x: 11 + Double(i) * 5, y: 15, width: 2.2, height: 2.2))
                }
            }
        }
        // Cell 1: network — genuinely centered on this cell's own (16, 16)
        // both horizontally (repair1's relative-coordinate fix) AND
        // vertically (repair2's `classicNetworkCenter` correction — the
        // shared anchor and each connection type's own visual centroid are
        // NOT the same point; repair1 only fixed the former).
        withCell(1) { ctx in
            let networkCenter = Self.classicNetworkCenter(for: s.connection, cellCenter: CGPoint(x: 16, y: 16))
            drawNetworkMark(s.connection, wifiStrength: s.wifiStrength, in: ctx, center: networkCenter,
                            foreground: foreground, track: track,
                            stroke: { stroke(ctx, $0, $1, width: $2) },
                            arc: { arc(ctx, $0, $1, radius: $2, center: $3, ink: $4, width: $5) })
        }
        // Cell 2: volume — classic's OWN speaker+waves presentation
        // (`drawClassicSpeaker`), not the combined glyph's 4-dot row.
        withCell(2) { ctx in
            drawClassicSpeaker(hasAudioOutput: s.hasAudioOutput, muted: s.muted, volume: s.volume, in: ctx,
                              foreground: foreground, track: track,
                              stroke: { stroke(ctx, $0, $1, width: $2) },
                              arc: { arc(ctx, $0, $1, radius: $2, center: $3, ink: $4, width: $5) })
        }
        if AttentionAnalysis.isDegraded(snapshot: s) {
            // `context` here is the OUTER classic context, which — unlike
            // every `withCell` closure above — never had
            // `translateBy(0,32); scaleBy(1,-1)` applied to it, so it is
            // still in AppKit's normal Y-UP space (origin bottom-left).
            // The combined glyph's identical-looking triangle at y:1.5/7.5
            // sits near the TOP there because that context IS flipped —
            // copying those same y-values here without accounting for the
            // different coordinate space put the badge near the BOTTOM
            // instead (root: "badge currently sits bottom-right in
            // classic"). `cell - y` mirrors it back to the top edge.
            let warnInk = color ? NSColor.systemRed : foreground
            context.beginPath()
            context.move(to: CGPoint(x: cell * 3 - 6, y: cell - 1.5))
            context.addLine(to: CGPoint(x: cell * 3 - 2.5, y: cell - 7.5))
            context.addLine(to: CGPoint(x: cell * 3 - 9.5, y: cell - 7.5))
            context.closePath()
            context.setFillColor(warnInk.cgColor); context.fillPath()
        }
        image.unlockFocus()
        image.isTemplate = !color
        return image
    }
}
