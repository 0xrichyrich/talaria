import SwiftUI
import TalariaKit

// The Bot Mode avatar language: geometric shape × hue with blinking eyes;
// eyes scan side-to-side while the bot works. Clip-path polygons ported from
// the prototype's SHAPE_CSS.

public struct AvatarSilhouette: Shape, Sendable {
    public var kind: AvatarShape

    public init(_ kind: AvatarShape) { self.kind = kind }

    public func path(in rect: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x / 100, y: rect.minY + rect.height * y / 100)
        }
        switch kind {
        case .circle:
            return Circle().path(in: rect)
        case .squircle:
            return RoundedRectangle(cornerRadius: rect.width * 0.38, style: .continuous).path(in: rect)
        case .hexagon:
            return polygon([pt(25, 4), pt(75, 4), pt(98, 50), pt(75, 96), pt(25, 96), pt(2, 50)])
        case .triangle:
            return polygon([pt(50, 6), pt(97, 94), pt(3, 94)])
        case .diamond:
            return polygon([pt(50, 2), pt(98, 50), pt(50, 98), pt(2, 50)])
        case .pentagon:
            return polygon([pt(50, 2), pt(98, 38), pt(79, 97), pt(21, 97), pt(2, 38)])
        }
    }

    private func polygon(_ points: [CGPoint]) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for point in points.dropFirst() { p.addLine(to: point) }
        p.closeSubpath()
        return p
    }
}

/// Vertical eye centering differs per silhouette (triangle rides lower);
/// ported from EYE_TOP, expressed as an offset from center in avatar-heights.
private func eyeOffsetFraction(for shape: AvatarShape) -> CGFloat {
    switch shape {
    case .triangle: 0.14
    case .pentagon: 0.04
    default: 0
    }
}

public struct AvatarView: View {
    public var shape: AvatarShape
    public var hue: AvatarHue
    public var size: CGFloat
    public var isWorking: Bool
    public var theme: ThemePack

    @State private var blinkPhase = false
    @State private var scanPhase = false

    public init(shape: AvatarShape, hue: AvatarHue, size: CGFloat,
                isWorking: Bool = false, theme: ThemePack) {
        self.shape = shape; self.hue = hue; self.size = size
        self.isWorking = isWorking; self.theme = theme
    }

    public init(bot: Bot, size: CGFloat, theme: ThemePack) {
        self.init(shape: bot.shape, hue: bot.hue, size: size,
                  isWorking: bot.status == .working, theme: theme)
    }

    private var fill: Color { theme.color(for: hue) }
    private var eyeWidth: CGFloat { size * 0.115 }
    private var eyeHeight: CGFloat { size * 0.21 }

    public var body: some View {
        ZStack {
            AvatarSilhouette(shape)
                .fill(fill)
                .shadow(color: theme.avatarGlowRadius > 0 ? fill.opacity(0.5) : .clear,
                        radius: theme.avatarGlowRadius * size / 44)
            eyes
                .offset(y: size * eyeOffsetFraction(for: shape))
        }
        .frame(width: size, height: size)
        .onAppear { startAnimations() }
    }

    private var eyes: some View {
        HStack(spacing: size * 0.115) {
            eye
            eye
        }
        .offset(x: isWorking ? (scanPhase ? size * 0.09 : -size * 0.09) : 0)
        .animation(isWorking ? .easeInOut(duration: 2.1).repeatForever(autoreverses: true) : .default,
                   value: scanPhase)
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: min(theme.eyeCornerRadius, eyeWidth / 2))
            .fill(theme.eyeColor)
            .frame(width: eyeWidth, height: eyeHeight)
            .scaleEffect(y: blinkPhase ? 0.08 : 1, anchor: .center)
    }

    private func startAnimations() {
        if isWorking { scanPhase = true }
        // Periodic blink: quick close/open every ~4.5s.
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3.6...5.2)))
                withAnimation(.easeIn(duration: 0.09)) { blinkPhase = true }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeOut(duration: 0.12)) { blinkPhase = false }
            }
        }
    }
}

/// Pulsing ring shown around a working bot's avatar.
public struct WorkingPulse: View {
    public var color: Color
    public var lineWidth: CGFloat
    @State private var animate = false

    public init(color: Color, lineWidth: CGFloat = 2) {
        self.color = color; self.lineWidth = lineWidth
    }

    public var body: some View {
        Circle()
            .stroke(color, lineWidth: lineWidth)
            .scaleEffect(animate ? 1.5 : 0.9)
            .opacity(animate ? 0 : 0.5)
            .animation(.easeOut(duration: 1.9).repeatForever(autoreverses: false), value: animate)
            .onAppear { animate = true }
    }
}
