# Floating Reader (picture-in-picture style) — Design

Status: approved 2026-11-26 (with the three review points below folded in). Size: small change.

## Intent and why
Read a manhwa in a small, always-on-top, phone-shaped window while working in
other apps. It scrolls automatically (hands-free) or by hand. Think YouTube
picture-in-picture, but for the reader.

## Goals
- A "Pop out" action in the reader moves the current chapter into a small
  floating window.
- The window stays above other apps (including full-screen apps) and follows
  you across desktops/Spaces.
- Clicking or scrolling it does NOT pull focus away from the app you are working in.
- Phone-shaped by default (about 360x640), resizable, remembers size and position.
- Auto-scroll (play/pause, speed) and manual scroll both work.
- Auto-scroll rolls into the next chapter by itself (existing behaviour).
- Reading position keeps saving to history/progress as it does today.

## Non-goals
- Reading two different chapters at once (main window and panel are one reader).
- Paged / double-page modes in the panel. Manhwa is long-strip, so the panel is
  always webtoon-style scrolling.
- Translation overlay, colour correction, trackers UI inside the panel.
- System PiP (AVPictureInPictureController): it only accepts video.

## Anti-goals (a failure even if it technically works)
- The panel steals keyboard focus from the user's work app.
- Two readers fighting over the same shared reader state.
- Auto-scroll that keeps running with no visible way to stop it.

## Constraints
- Reader state lives in AppState (activeChapter, readerChapters,
  readerChapterIndex, readerPageIndex, autoScrollOn, autoScrollLevel).
  WebtoonReaderV2 reads from it. No parallel state.
- macOS 26+, Swift 6 strict concurrency (Package.swift). New code is @MainActor.
- No new dependencies. No schema, auth or helper/engine (nyora-shared) changes.
- Precedent for a floating NSWindow: Bridge/MacCloudflareSolver.swift.

## Approaches considered
1. Second SwiftUI `Window` scene + floating tweaks. Least code, but the window
   activates Nyora on click and steals focus. Rejected: defeats the use case.
2. **AppKit `NSPanel` hosting the existing reader view (chosen).** Non-activating,
   floating, all-Spaces, full-screen-auxiliary. Slightly more AppKit, true PiP feel.
3. System picture-in-picture. Video only. Rejected.

## Design (approach 2) — calls marked "my call" are proposals, not agreed
- **FloatingReaderController** (new, `Views/FloatingReaderPanel.swift`),
  `@MainActor`, owned by AppState (or a small singleton). Creates one `NSPanel`
  with styleMask `[.nonactivatingPanel, .titled, .closable, .resizable,
  .fullSizeContentView]`, `level = .floating`, `collectionBehavior =
  [.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false`,
  `becomesKeyOnlyIfNeeded = true`. Hosts `NSHostingView(FloatingReaderView)`
  with `.environmentObject(appState)`. Frame autosave name set so size/position persist.
- **FloatingReaderView** (new): `WebtoonReaderV2` for `appState.activeChapter`
  plus a slim overlay control strip: play/pause, speed - / +, "return to main
  window", close. The rest of the strip auto-hides when idle and shows on hover
  (my call); **Pause stays visible while auto-scroll is running** (review point 3).
- **Pop out / return:** a button in the reader chrome opens the panel and sets
  the main window's reader pane to a placeholder ("Reading in floating window",
  with a Return button) so only one WebtoonReaderV2 exists at a time.
  Return/close tears the panel down and restores the main reader at the same
  page (state is shared, so position is already correct).
- **Auto-scroll** reuses `appState.autoScrollOn` / `autoScrollLevel`; no new
  scroll engine. Manual scroll cancelling auto-scroll stays as is.
- **Lifecycle:** closing the panel stops auto-scroll (my call, so it never
  scrolls unseen). Both the in-panel Close button and the native window close
  button go through the same cleanup path (NSWindowDelegate `windowWillClose`
  does the work; the Close button just calls `close()`). Quitting the app closes the panel.
- **Resizing:** free resize, no aspect lock; minimum about 240x360 (my call).
  Page images are width-locked, so panel width controls page size.
- **Opacity:** optional, not in v1 (my call).

## Files touched (expected)
- new: `macApp/Nyora/NyoraApp/Views/FloatingReaderPanel.swift`
- edit: `Views/PlaceholderViews.swift` (reader host: pop-out button + placeholder
  while popped out), `ViewModels/AppState.swift` (isReaderFloating flag + open/close).
- no changes to `Reader.swift` expected unless the reader needs a compact
  layout (see open items).

## Verification
Order matters; do the focus check FIRST, before building the rest (review point 1):
- Focus/full-screen spike: with a text editor in front, click Play/Pause, change
  speed, scroll and resize the panel, then type; text must still go to the editor.
  Also try `.canJoinAllApplications` so it shows over other apps' full-screen Spaces.
  If focus is stolen, fix the panel config before any other work.
- Position handoff (review point 2): pop out and return from HALFWAY down a tall
  webtoon image. The page index identifies the page but the recreated view may
  need a scroll anchor (offset within page) to restore the same spot. Also verify
  next-chapter rollover immediately before returning.
- `swift build` in `macApp/` must succeed (Swift 6 mode).
- Manual run via `macApp/scripts/dev-launch.sh`: pop out, check it floats over
  another app and a full-screen app, does not steal focus, scrolls manually and
  automatically, rolls into next chapter, returns to main at the same page.
- No UI test target is known; if none exists, manual checks are reported as manual.

## Left to the builder / open items
- Whether WebtoonReaderV2's existing chrome (page counter, scrub bar, tap zones)
  is acceptable at 360 px wide or needs a compact flag. Decide when seeing it.
- Exact default size, minimum size and strip styling.
- Whether an in-page scroll anchor must be added to AppState to restore the exact
  spot after return (see Verification).
- Whether the panel needs `NSApp.setActivationPolicy` care (non-activating
  panels on an app that has a Dock icon should be fine; verify).
