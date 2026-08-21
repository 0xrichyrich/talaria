import SwiftUI
import TalariaKit
import TalariaTheme
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Roster row for a stable room identity. The name may change; navigation and
/// SwiftUI identity stay on RoomID so a rename never loses the open transcript.
public struct RoomRow: View {
    public let room: RoomRecord
    public let theme: ThemePack
    public let avatarData: Data?
    public let action: () -> Void

    public init(room: RoomRecord, theme: ThemePack, avatarData: Data? = nil,
                action: @escaping () -> Void) {
        self.room = room; self.theme = theme; self.avatarData = avatarData; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                RoomAvatarView(room: room, theme: theme, data: avatarData, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(room.name).font(theme.body(15, weight: .semibold))
                            .foregroundStyle(theme.ink).lineLimit(1)
                        if room.needsUser {
                            Circle().fill(theme.danger).frame(width: 7, height: 7)
                                .accessibilityLabel("A member mentioned you")
                        }
                        if RoomDeliveryPolicy.hasUnresolvedDelivery(room) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.warn)
                                .accessibilityLabel("Delivery needs confirmation")
                        }
                    }
                    Text(preview).font(theme.body(11)).foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if !room.drives.isEmpty {
                    ProgressView().controlSize(.small).tint(theme.accent)
                        .accessibilityLabel("Room is working")
                } else {
                    Text(verbatim: "›").font(theme.body(20, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("room-row-\(room.id.description)")
    }

    private var preview: String {
        guard let last = room.entries.last else {
            return room.members.map { "@\($0.handle)" }.joined(separator: ", ")
        }
        let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity: String
        if let route = last.memberRoute {
            identity = "@\(room.members.first(where: { $0.route == route })?.handle ?? route.profile)"
                + (last.sourceLabel.map { " · \($0)" } ?? "")
        } else { identity = "You" }
        return "\(identity): \(text.isEmpty ? "Attachment" : text)"
    }
}

public struct RoomAvatarView: View {
    public let room: RoomRecord
    public let theme: ThemePack
    public let data: Data?
    public let size: CGFloat

    public init(room: RoomRecord, theme: ThemePack, data: Data? = nil, size: CGFloat = 42) {
        self.room = room; self.theme = theme; self.data = data; self.size = size
    }

    public var body: some View {
        if let data, let image = platformImage(data) {
            image.resizable().scaledToFill().frame(width: size, height: size)
                .clipShape(Circle()).overlay(Circle().stroke(theme.line, lineWidth: 1))
        } else {
            HStack(spacing: -size * 0.34) {
                ForEach(Array(room.members.prefix(3))) { member in
                    AvatarView(bot: bot(member), size: size * 0.68, theme: theme)
                        .overlay(Circle().stroke(theme.bg, lineWidth: 2))
                }
            }.frame(width: size, height: size)
        }
    }

    private func bot(_ member: RoomMember) -> Bot {
        Bot(id: member.route.qualifiedID, job: "Room member",
            shape: BotCosmetics.derivedShape(forName: member.route.qualifiedID),
            hue: BotCosmetics.derivedHue(forName: member.route.qualifiedID),
            title: member.title, handleOverride: member.handle,
            rawDisplayName: member.rawDisplayName)
    }

    private func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        guard let value = UIImage(data: data) else { return nil }
        return Image(uiImage: value)
        #elseif canImport(AppKit)
        guard let value = NSImage(data: data) else { return nil }
        return Image(nsImage: value)
        #else
        return nil
        #endif
    }
}
