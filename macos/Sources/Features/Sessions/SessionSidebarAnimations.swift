import SwiftUI

/// The "thinking" spinner from Cursor's CLI: a two-cell braille animation.
/// Frames are derived from wall-clock time so every spinner in every window
/// animates in lockstep.
struct CursorSpinner: View {
    static let frames = ["⠀⠞", "⠠⠜", "⠰⠰", "⠘⠤", "⠘⠆", "⠘⠣", "⠰⠳", "⠠⠛"]
    static let interval: TimeInterval = 0.25

    var color: Color = SessionPalette.working
    var size: CGFloat = 11

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.interval)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / Self.interval)
            Text(Self.frames[tick % Self.frames.count])
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .fixedSize()
        }
    }
}

/// Text with a highlight sweeping across it, like Cursor's "Generating…" label.
struct ShimmerText: View {
    let text: String
    var base: Color = .secondary
    var highlight: Color = .primary
    var font: Font = .system(size: 11)

    /// Seconds for one sweep across the text, including a short rest.
    private let period: TimeInterval = 1.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            // Sweep from just left of the text to just past the right edge.
            let center = -0.3 + t * 1.6
            Text(text)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: base, location: 0),
                            .init(color: highlight, location: 0.5),
                            .init(color: base, location: 1),
                        ],
                        startPoint: UnitPoint(x: center - 0.25, y: 0.5),
                        endPoint: UnitPoint(x: center + 0.25, y: 0.5)))
        }
    }
}

/// An hourglass that drains, then flips. Used while an agent waits on its
/// own background work. Wall-clock driven, like `CursorSpinner`.
struct HourglassSpinner: View {
    static let frames = ["hourglass.tophalf.filled", "hourglass", "hourglass.bottomhalf.filled"]
    static let interval: TimeInterval = 0.6

    var color: Color = SessionPalette.waiting
    var size: CGFloat = 9

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.interval)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / Self.interval)
            let frame = tick % (Self.frames.count + 1)
            // The extra frame is the flip: the full bottom bulb turned upside down.
            Image(systemName: Self.frames[min(frame, Self.frames.count - 1)])
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
                .rotationEffect(.degrees(frame == Self.frames.count ? 180 : 0))
                .animation(.easeInOut(duration: 0.3), value: frame == Self.frames.count)
                .frame(width: 11, height: 11)
        }
    }
}

/// A softly pulsing dot used for "needs input".
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.4
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(phase)))
                .shadow(color: color.opacity(0.6), radius: 3)
        }
    }
}

enum SessionPalette {
    static let working = Color(red: 0.36, green: 0.84, blue: 0.47)
    static let attention = Color(red: 1.0, green: 0.65, blue: 0.2)
    static let done = Color(red: 0.38, green: 0.62, blue: 1.0)
    static let waiting = Color(red: 0.75, green: 0.6, blue: 0.95)
}

/// The status glyph shown at the leading edge of a session row (and in the rail).
struct SessionIndicator: View {
    let activity: SessionActivity

    var body: some View {
        switch activity {
        case .agentWorking:
            CursorSpinner()
        case .agentNeedsInput:
            PulsingDot(color: SessionPalette.attention)
        case .agentWaitingOnBackground:
            HourglassSpinner()
        case .agentDone:
            Circle().fill(SessionPalette.done).frame(width: 7, height: 7)
        case .agentIdle:
            Circle().strokeBorder(Color.secondary.opacity(0.8), lineWidth: 1.2).frame(width: 7, height: 7)
        case .command:
            Image(systemName: "play.fill")
                .font(.system(size: 7))
                .foregroundColor(.secondary)
        case .shell:
            Text("›")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
        }
    }
}
