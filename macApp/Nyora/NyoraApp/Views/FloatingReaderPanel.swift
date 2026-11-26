import SwiftUI
import AppKit

/// Non-activating floating panel: it can sit above other apps without making Nyora
/// the active app, so typing keeps going to whatever the user is working in.
/// `canBecomeKey` / `canBecomeMain` are `false` on purpose (see the focus check in
/// the plan); flip `canBecomeKey` only if controls stop responding.
final class FloatingReaderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the single floating-reader panel. All close paths (native red button,
/// in-panel Close, Return to main) end in `windowWillClose`.
@MainActor
final class FloatingReaderController: NSObject, NSWindowDelegate {
    private weak var appState: AppState?
    private var panel: FloatingReaderPanel?

    private static let autosaveName = "NyoraFloatingReader"

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Creates the panel on first use and brings it to the front without activating Nyora.
    func show() {
        guard let appState else { return }
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let panel = FloatingReaderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 240, height: 360)
        panel.delegate = self

        let host = NSHostingView(
            rootView: FloatingReaderView(onClose: { [weak self] in self?.close() })
                .environmentObject(appState)
        )
        panel.contentView = host

        // Restore the last size/position; if that frame is off every connected
        // screen (monitor unplugged), fall back to the centre of the main screen.
        panel.center()
        panel.setFrameAutosaveName(Self.autosaveName)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !onScreen { panel.center() }

        self.panel = panel
        panel.orderFrontRegardless()
    }

    /// Closes the panel; the delegate callback below performs the cleanup.
    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        appState?.autoScrollOn = false
        appState?.readerRestoreChapterId = appState?.activeChapter?.id
        appState?.readerRestorePage = appState?.readerPageIndex ?? 0
        appState?.isReaderFloating = false
        panel?.delegate = nil
        panel = nil
    }
}

/// Reader content for the floating panel: the webtoon reader (never taking keyboard
/// focus) with a slim control strip. Pause stays visible while auto-scroll runs; the
/// rest of the strip fades after 2.5 s without interaction.
struct FloatingReaderView: View {
    @EnvironmentObject var appState: AppState
    let onClose: () -> Void

    @State private var stripVisible = true
    /// Last interaction time, kept outside SwiftUI state so mouse-moves never re-render.
    @State private var idle = IdleClock()
    private let hideAfter: TimeInterval = 2.5

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let chapter = appState.activeChapter, !chapter.pages.isEmpty {
                WebtoonReaderV2(
                    chapter: chapter,
                    controlsVisible: false,
                    onToggleChrome: wakeStrip,   // a tap on the page wakes the strip
                    takesKeyboardFocus: false
                )
            }
            controlStrip
                .padding(.bottom, 10)
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { wakeStrip() }
        }
        .task { await runIdleTimer() }
    }

    private var controlStrip: some View {
        HStack(spacing: 2) {
            if stripVisible {
                stripButton("minus") { appState.bumpAutoScrollSpeed(-1) }
                    .help("Slower")
                Text("\(appState.readerPrefs.autoScrollLevel)/10")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28)
                stripButton("plus") { appState.bumpAutoScrollSpeed(+1) }
                    .help("Faster")
            }
            // Pause is the one control that must never disappear while scrolling.
            if stripVisible || appState.autoScrollOn {
                stripButton(appState.autoScrollOn ? "pause.fill" : "play.fill",
                            tint: appState.autoScrollOn ? .appAccent : .primary) {
                    appState.toggleAutoScroll()
                    wakeStrip()
                }
                .help(appState.autoScrollOn ? "Pause auto-scroll" : "Start auto-scroll")
            }
            if stripVisible {
                stripButton("rectangle.portrait.on.rectangle.portrait") { appState.returnReaderToMain() }
                    .help("Return to main window")
                stripButton("xmark") { onClose() }
                    .help("Close")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.easeInOut(duration: 0.2), value: stripVisible)
    }

    private func stripButton(_ system: String, tint: Color = .primary,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .frame(width: 28, height: 28)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func wakeStrip() {
        idle.last = .now
        if !stripVisible { stripVisible = true }
    }

    private func runIdleTimer() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if stripVisible, Date().timeIntervalSince(idle.last) > hideAfter {
                stripVisible = false
            }
        }
    }
}

/// Shown in the main window's reader pane while the chapter is in the floating panel,
/// so only one reader exists at a time.
struct ReaderFloatingPlaceholder: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pip")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Reading in floating window")
                .font(.headline)
            if let title = appState.activeChapter?.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("Return to main window") { appState.returnReaderToMain() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}
