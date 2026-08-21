import Foundation
import SwiftUI
import SwiftTerm
import TalariaTheme

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A uniquely identified chunk of bytes received from a gateway PTY.
///
/// Identity is intentionally separate from the payload: SwiftUI may call an
/// update repeatedly, and terminal bytes must be fed exactly once.
public struct GatewayTerminalChunk: Equatable, Sendable {
    public let id: UUID
    public let bytes: Data

    public init(id: UUID = UUID(), bytes: Data) {
        self.id = id
        self.bytes = bytes
    }
}

/// Colors used by the terminal emulator. Transport and process concerns do not
/// belong here; this is solely renderer configuration.
public struct GatewayTerminalTheme: Equatable, Sendable {
    public let foreground: SwiftUI.Color
    public let background: SwiftUI.Color
    public let cursor: SwiftUI.Color
    public let selection: SwiftUI.Color

    public init(
        foreground: SwiftUI.Color,
        background: SwiftUI.Color,
        cursor: SwiftUI.Color,
        selection: SwiftUI.Color
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
    }

    public init(theme: ThemePack) {
        self.init(
            foreground: theme.ink,
            background: theme.inset,
            cursor: theme.accent,
            selection: theme.accentFaint
        )
    }
}

enum GatewayTerminalSoftKey: CaseIterable, Equatable {
    case escape
    case control
    case tab
    case arrowLeft
    case arrowDown
    case arrowUp
    case arrowRight

    var label: String {
        switch self {
        case .escape: "Esc"
        case .control: "Ctrl"
        case .tab: "Tab"
        case .arrowLeft: "←"
        case .arrowDown: "↓"
        case .arrowUp: "↑"
        case .arrowRight: "→"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .control: "Control modifier"
        case .tab: "Tab"
        case .arrowLeft: "Left arrow"
        case .arrowDown: "Down arrow"
        case .arrowUp: "Up arrow"
        case .arrowRight: "Right arrow"
        }
    }
}

struct GatewayTerminalInputPolicy {
    static func softKeyBytes(_ key: GatewayTerminalSoftKey, controlArmed: Bool,
                             applicationCursor: Bool = false) -> [UInt8]? {
        switch key {
        case .control:
            return nil
        case .escape:
            return [0x1b]
        case .tab:
            return [0x09]
        case .arrowLeft:
            return controlArmed ? [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44]
                : (applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
        case .arrowDown:
            return controlArmed ? [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x42]
                : (applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
        case .arrowUp:
            return controlArmed ? [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x41]
                : (applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
        case .arrowRight:
            return controlArmed ? [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x43]
                : (applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
        }
    }

    /// Applies the phone Ctrl latch to the next native keyboard byte. SwiftTerm
    /// already handles hardware modifier events; this only handles the soft key.
    static func applyingControl(to bytes: ArraySlice<UInt8>, armed: Bool) -> [UInt8] {
        guard armed, let first = bytes.first else { return Array(bytes) }
        var result = Array(bytes.dropFirst())
        let transformed: UInt8? = switch first {
        case 0x40...0x5f: first & 0x1f
        case 0x61...0x7a: first & 0x1f
        case 0x20: 0
        case 0x3f: 0x7f
        default: nil
        }
        guard let transformed else { return Array(bytes) }
        result.insert(transformed, at: 0)
        return result
    }
}

struct GatewayTerminalRendererState {
    private(set) var consumedChunkIDs: Set<UUID> = []
    private(set) var lastSize: (columns: Int, rows: Int)?
    private(set) var appliedTheme: GatewayTerminalTheme?
    private(set) var applicationCursor = false
    private var modeTail: [UInt8] = []

    mutating func chunksToFeed(from chunks: [GatewayTerminalChunk]) -> [GatewayTerminalChunk] {
        consumedChunkIDs.formIntersection(Set(chunks.map(\.id)))
        if chunks.isEmpty {
            consumedChunkIDs.removeAll(keepingCapacity: true)
            return []
        }
        return chunks.compactMap { chunk -> GatewayTerminalChunk? in
            guard consumedChunkIDs.insert(chunk.id).inserted else { return nil }
            observeModes(in: chunk.bytes)
            return chunk
        }
    }

    mutating func resizeToEmit(columns: Int, rows: Int) -> (Int, Int)? {
        guard columns > 0, rows > 0 else { return nil }
        let next = (columns, rows)
        guard lastSize?.columns != next.0 || lastSize?.rows != next.1 else { return nil }
        lastSize = next
        return next
    }

    mutating func shouldApply(_ theme: GatewayTerminalTheme) -> Bool {
        guard appliedTheme != theme else { return false }
        appliedTheme = theme
        return true
    }

    private mutating func observeModes(in data: Data) {
        let bytes = modeTail + [UInt8](data)
        let enabled: [UInt8] = [0x1b, 0x5b, 0x3f, 0x31, 0x68]
        let disabled: [UInt8] = [0x1b, 0x5b, 0x3f, 0x31, 0x6c]
        if bytes.count >= enabled.count {
            for start in 0...(bytes.count - enabled.count) {
                let candidate = Array(bytes[start..<(start + enabled.count)])
                if candidate == enabled { applicationCursor = true }
                if candidate == disabled { applicationCursor = false }
            }
        }
        modeTail = Array(bytes.suffix(enabled.count - 1))
    }
}

@MainActor
private final class GatewayTerminalInputController {
    weak var terminal: SwiftTerm.TerminalView?
    func send(_ bytes: [UInt8]) { terminal?.send(bytes) }
}

struct GatewayTerminalLinkPolicy {
    private static let allowedSchemes = Set(["http", "https", "mailto"])

    static func url(for rawValue: String) -> URL? {
        guard let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        return url
    }
}

/// A SwiftTerm-backed terminal renderer for an already-established PTY stream.
/// It never creates a process, socket, or SSH session.
public struct GatewayTerminalView: View {
    private let receivedChunks: [GatewayTerminalChunk]
    private let terminalTheme: GatewayTerminalTheme
    private let allowsRemoteClipboardWrite: Bool
    private let onInput: (Data) -> Void
    private let onResize: (_ columns: Int, _ rows: Int) -> Void
    private let onOpenLink: (URL) -> Void
    private let onConsume: ([UUID]) -> Void

    @State private var controlArmed = false
    @State private var applicationCursor = false
    @State private var inputController = GatewayTerminalInputController()

    public init(
        receivedChunks: [GatewayTerminalChunk],
        theme: GatewayTerminalTheme,
        allowsRemoteClipboardWrite: Bool = false,
        onInput: @escaping (Data) -> Void,
        onResize: @escaping (_ columns: Int, _ rows: Int) -> Void,
        onOpenLink: @escaping (URL) -> Void,
        onConsume: @escaping ([UUID]) -> Void = { _ in }
    ) {
        self.receivedChunks = receivedChunks
        self.terminalTheme = theme
        self.allowsRemoteClipboardWrite = allowsRemoteClipboardWrite
        self.onInput = onInput
        self.onResize = onResize
        self.onOpenLink = onOpenLink
        self.onConsume = onConsume
    }

    public var body: some View {
        VStack(spacing: 0) {
            GatewayTerminalRepresentable(
                receivedChunks: receivedChunks,
                theme: terminalTheme,
                allowsRemoteClipboardWrite: allowsRemoteClipboardWrite,
                controlArmed: $controlArmed,
                applicationCursor: $applicationCursor,
                inputController: inputController,
                onInput: onInput,
                onResize: onResize,
                onOpenLink: onOpenLink,
                onConsume: onConsume
            )
            .accessibilityLabel("Gateway terminal")
            .accessibilityHint("Interactive remote terminal")

            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                softKeyRow
            }
            #endif
        }
        .background(terminalTheme.background)
    }

    #if os(iOS)
    private var softKeyRow: some View {
        HStack(spacing: 4) {
            ForEach(GatewayTerminalSoftKey.allCases, id: \.self) { key in
                Button {
                    send(key)
                } label: {
                    Text(key.label)
                        .font(.system(size: 13, weight: key == .control && controlArmed ? .bold : .medium, design: .monospaced))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(key == .control && controlArmed ? terminalTheme.selection : SwiftUI.Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.accessibilityLabel)
                .accessibilityValue(key == .control && controlArmed ? "On" : "")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .foregroundStyle(terminalTheme.foreground)
        .background(terminalTheme.background)
        .overlay(alignment: .top) { Divider().opacity(0.45) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal keys")
    }

    private func send(_ key: GatewayTerminalSoftKey) {
        if key == .control {
            controlArmed.toggle()
            return
        }
        guard let bytes = GatewayTerminalInputPolicy.softKeyBytes(
            key, controlArmed: controlArmed, applicationCursor: applicationCursor) else { return }
        controlArmed = false
        inputController.send(bytes)
    }
    #endif
}

#if os(iOS)
private typealias NativeTerminalColor = UIColor
private typealias NativeTerminalFont = UIFont
#elseif os(macOS)
private typealias NativeTerminalColor = NSColor
private typealias NativeTerminalFont = NSFont
#endif

private struct GatewayTerminalRepresentable {
    let receivedChunks: [GatewayTerminalChunk]
    let theme: GatewayTerminalTheme
    let allowsRemoteClipboardWrite: Bool
    @Binding var controlArmed: Bool
    @Binding var applicationCursor: Bool
    let inputController: GatewayTerminalInputController
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void
    let onOpenLink: (URL) -> Void
    let onConsume: ([UUID]) -> Void

    @MainActor
    func makeTerminal(context: Coordinator) -> SwiftTerm.TerminalView {
        let terminal = SwiftTerm.TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        terminal.terminalDelegate = context
        inputController.terminal = terminal
        terminal.linkReporting = .implicit
        terminal.allowMouseReporting = false
        terminal.optionAsMetaKey = true
        #if os(iOS)
        // SwiftTerm ships its own keyboard accessory. Talaria supplies the
        // phone policy below, so avoid presenting two rows of terminal keys.
        if UIDevice.current.userInterfaceIdiom == .phone {
            terminal.inputAccessoryView = nil
        }
        #endif
        if context.state.shouldApply(theme) { configure(terminal) }
        return terminal
    }

    @MainActor
    func update(_ terminal: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.parent = self
        inputController.terminal = terminal
        if coordinator.state.shouldApply(theme) { configure(terminal) }
        let pending = coordinator.state.chunksToFeed(from: receivedChunks)
        for chunk in pending {
            let bytes = [UInt8](chunk.bytes)
            terminal.feed(byteArray: bytes[...])
        }
        if !pending.isEmpty {
            let consumed = pending.map(\.id)
            let handler = coordinator.parent.onConsume
            DispatchQueue.main.async { handler(consumed) }
        }
        let cursorMode = coordinator.state.applicationCursor
        if applicationCursor != cursorMode {
            DispatchQueue.main.async { applicationCursor = cursorMode }
        }
    }

    private func configure(_ terminal: SwiftTerm.TerminalView) {
        terminal.nativeForegroundColor = NativeTerminalColor(theme.foreground)
        terminal.nativeBackgroundColor = NativeTerminalColor(theme.background)
        terminal.caretColor = NativeTerminalColor(theme.cursor)
        terminal.selectedTextBackgroundColor = NativeTerminalColor(theme.selection)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: GatewayTerminalRepresentable
        var state = GatewayTerminalRendererState()

        init(parent: GatewayTerminalRepresentable) {
            self.parent = parent
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard let size = state.resizeToEmit(columns: newCols, rows: newRows) else { return }
            parent.onResize(size.0, size.1)
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            let bytes = GatewayTerminalInputPolicy.applyingControl(to: data, armed: parent.controlArmed)
            if parent.controlArmed { parent.controlArmed = false }
            guard !bytes.isEmpty else { return }
            parent.onInput(Data(bytes))
        }

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let url = GatewayTerminalLinkPolicy.url(for: link) else { return }
            parent.onOpenLink(url)
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            guard parent.allowsRemoteClipboardWrite,
                  let value = String(data: content, encoding: .utf8) else { return }
            #if os(iOS)
            UIPasteboard.general.string = value
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            #endif
        }

        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func bell(source: SwiftTerm.TerminalView) {}
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

#if os(iOS)
extension GatewayTerminalRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let terminal = makeTerminal(context: context.coordinator)
        DispatchQueue.main.async { _ = terminal.becomeFirstResponder() }
        return terminal
    }

    func updateUIView(_ terminal: SwiftTerm.TerminalView, context: Context) {
        update(terminal, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
}
#elseif os(macOS)
extension GatewayTerminalRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        makeTerminal(context: context.coordinator)
    }

    func updateNSView(_ terminal: SwiftTerm.TerminalView, context: Context) {
        update(terminal, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
}
#endif
