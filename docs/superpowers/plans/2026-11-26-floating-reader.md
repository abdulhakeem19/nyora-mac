# Floating Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pop the current manhwa chapter out of the main window into a small, always-on-top, phone-shaped panel that scrolls automatically or by hand without stealing focus from the app they are working in.

**Architecture:** A new `@MainActor` `FloatingReaderController` owns one non-activating `NSPanel` that hosts the existing `WebtoonReaderV2` plus a slim control strip, sharing the existing `AppState` (no parallel reader state). While the panel is open the main window's reader pane shows a "Reading in floating window" placeholder, so only one reader exists at a time. All close paths run through `NSWindowDelegate.windowWillClose`.

**Tech Stack:** Swift 6 language mode, SwiftUI + AppKit (`NSPanel`, `NSHostingView`), macOS 26 target. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-26-floating-reader-design.md` (approved 2026-11-26, includes the three review points).

## Global Constraints

- Swift 6 strict concurrency (`.swiftLanguageMode(.v6)`); all new UI/controller code is `@MainActor`.
- No new dependencies; no schema, auth, helper/engine (`nyora-shared`, `shared/`) changes.
- Reader state stays in `AppState`; no parallel state. Panel reuses `appState.autoScrollOn` and `appState.readerPrefs.autoScrollLevel`.
- Panel: `level = .floating`, collection behaviour includes `.canJoinAllSpaces` and `.fullScreenAuxiliary`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`; default content size 360x640; free resize (no aspect lock); minimum about 240x360; frame persisted with autosave name `NyoraFloatingReader`.
- Panel is long-strip (webtoon) only; no translation overlay, colour correction or tracker UI in it; no opacity control in v1.
- Pause stays visible while auto-scroll runs; the rest of the strip auto-hides when idle. Native close button and in-panel Close share one cleanup path; closing stops auto-scroll.
- **No automated test target exists** (`macApp/Package.swift` has only `NyoraApp` and `ConcurrencyShim`). Adding one is out of scope (smallest safe change). Every "test" below is `swift build --product Nyora` plus a manual check with a stated expected result, and must be reported as manual.
- Work on a branch (`feature/floating-reader`), never on `main`. Commits are local only; do not push. Commit steps need the user's go-ahead at execution time.
- Build command (from `macApp/`): `swift build --product Nyora 2>&1 | tail -20` — pass means it ends with `Build complete!`. Run the app with `./macApp/scripts/dev-launch.sh` from the repo root (needs JDK 17 and `shared/build/libs/nyora-helper.jar` for sources to load).

## Review Focus

Failure modes the spec implies that a user is most likely to hit, most likely first. Each has its check in the task named.

1. Clicking, scrolling or resizing the panel then typing in the editor behind it: text must still go to the editor (Task 1).
2. Closing with the native red button leaves auto-scroll running or the main window stuck on the placeholder (Task 2).
3. Returning to the main window from halfway down a tall page lands on a different spot, or a chapter rollover just before return shows the wrong chapter (Task 3).
4. Opening another chapter from the library while the panel is open: panel must show the new chapter, main window must not show two readers (Task 3).
5. Saved panel frame is off-screen after a monitor is unplugged: panel must reappear on a visible screen (Task 1).

---

## File Structure

- Create `macApp/Nyora/NyoraApp/Views/FloatingReaderPanel.swift` — panel subclass, `FloatingReaderController`, `FloatingReaderView` (reader + control strip), `ReaderFloatingPlaceholder`. One responsibility: the floating reader surface.
- Modify `macApp/Nyora/NyoraApp/Views/Reader.swift` — `WebtoonReaderV2` gains `takesKeyboardFocus`, and scroll-progress capture/restore.
- Modify `macApp/Nyora/NyoraApp/Views/PlaceholderViews.swift` — `ReaderView`: pop-out button in `floatingTopBar`, placeholder branch while floating.
- Modify `macApp/Nyora/NyoraApp/ViewModels/AppState.swift` — `isReaderFloating`, `popOutReader()`, `returnReaderToMain()`, `readerScrollProgress`.

---

### Task 1: Panel shell that floats and does not steal focus (do this first)

**Files:**
- Create: `macApp/Nyora/NyoraApp/Views/FloatingReaderPanel.swift`
- Modify: `macApp/Nyora/NyoraApp/Views/Reader.swift` (`WebtoonReaderV2`, around lines 444-460 and the `.focusable()` / `.onAppear` block near line 570)
- Modify: `macApp/Nyora/NyoraApp/ViewModels/AppState.swift` (near `autoScrollOn`, line ~810)
- Modify: `macApp/Nyora/NyoraApp/Views/PlaceholderViews.swift` (`floatingTopBar`, next to the auto-scroll `Menu`, line ~980)

**Interfaces:**
- Consumes: `AppState.activeChapter: ChapterSummary?`, `WebtoonReaderV2(chapter:controlsVisible:onToggleChrome:)`.
- Produces:
  - `WebtoonReaderV2.takesKeyboardFocus: Bool` (default `true`; `false` in the panel).
  - `AppState.isReaderFloating: Bool` (`@Published`), `AppState.popOutReader()`, `AppState.returnReaderToMain()`.
  - `final class FloatingReaderController: NSObject, NSWindowDelegate` with `init(appState: AppState)`, `func show()`, `func close()`, `func windowWillClose(_ notification: Notification)`.
  - `struct FloatingReaderView: View` (`init(onClose: @escaping () -> Void)`, reads `@EnvironmentObject appState`).

- [ ] **Step 1: Branch and baseline.** `git checkout -b feature/floating-reader` from the repo root, then build `macApp/` with the build command. Expected: `Build complete!`. If it fails before any change, stop and report the failure output; do not start editing.

- [ ] **Step 2: Add `takesKeyboardFocus` to `WebtoonReaderV2`** in `Reader.swift`. New stored property `var takesKeyboardFocus: Bool = true` (after `onToggleChrome`). Replace `.focusable()` with `.focusable(takesKeyboardFocus)` and `focused = true` in `.onAppear` with `focused = takesKeyboardFocus`. Behaviour with `true` must be identical to today.

- [ ] **Step 3: Add state and entry points to `AppState`.** `@Published var isReaderFloating = false`; `lazy var floatingReader = FloatingReaderController(appState: self)`; `func popOutReader()` guards `activeChapter?.pages.isEmpty == false`, sets `isReaderFloating = true`, calls `floatingReader.show()`; `func returnReaderToMain()` calls `floatingReader.close()`. The controller must hold `appState` weakly to avoid a retain cycle.

- [ ] **Step 4: Create `FloatingReaderPanel.swift`.**
  - `final class FloatingReaderPanel: NSPanel` overriding `canBecomeKey` and `canBecomeMain` to `false` (first attempt; Step 7 decides whether `canBecomeKey` must change).
  - `FloatingReaderController.show()` creates the panel once and fronts it with `orderFrontRegardless()` (never `NSApp.activate`). Config: styleMask `[.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView]`, `isFloatingPanel = true`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `isMovableByWindowBackground = true`, `isReleasedWhenClosed = false`, `minSize = NSSize(width: 240, height: 360)`, content rect 360x640, `delegate = self`, `setFrameAutosaveName("NyoraFloatingReader")`. After restoring the frame, if the frame intersects no `NSScreen.screens` visibleFrame, call `center()` (Review Focus 5).
  - Content: `NSHostingView(rootView: FloatingReaderView(onClose: { [weak self] in self?.close() }).environmentObject(appState))`.
  - `FloatingReaderView` for this task: `WebtoonReaderV2(chapter: chapter, controlsVisible: false, onToggleChrome: {}, takesKeyboardFocus: false)` over a black background, for `appState.activeChapter`; empty `Color.black` if nil.
  - `windowWillClose`: set `appState.isReaderFloating = false` and `appState.autoScrollOn = false`, then drop the panel reference.

- [ ] **Step 5: Add a pop-out button** in `ReaderView.floatingTopBar` right after the auto-scroll `Menu`: `barIcon("pip.enter") { appState.popOutReader() }.help("Pop out to floating window")`, following the existing `barIcon` call style.

- [ ] **Step 6: Build.** Run the build command. Expected: `Build complete!` with no Swift 6 concurrency errors. Fix any isolation errors by keeping everything `@MainActor`, not by loosening language mode.

- [ ] **Step 7: Focus and Spaces check (manual, gate for the rest of the plan).** Launch with `dev-launch.sh`, open a chapter, click the pop-out button. Then, with a text editor (TextEdit) frontmost:
  1. Click the panel, scroll it, drag-resize it, then type in TextEdit. Expected: characters appear in TextEdit; Nyora's menu bar does not take over.
  2. Put the editor in full-screen. Expected: the panel is visible over it. If not, add `.canJoinAllApplications` to `collectionBehavior` and re-test.
  3. Switch Spaces. Expected: panel follows.
  4. If clicking the panel steals focus, change `canBecomeKey` (keeping `.nonactivatingPanel`) and re-test before moving on. Record the final working combination in a code comment.
  Report each result as manual.

- [ ] **Step 8: Commit** (needs user go-ahead): `git add macApp/Nyora/NyoraApp && git commit -m "feat: floating reader panel shell (non-activating, always on top)"`.

---

### Task 2: Control strip and single close path

**Files:**
- Modify: `macApp/Nyora/NyoraApp/Views/FloatingReaderPanel.swift`

**Interfaces:**
- Consumes: Task 1's `FloatingReaderView(onClose:)`, `FloatingReaderController.close()`; `AppState.autoScrollOn`, `toggleAutoScroll()`, `bumpAutoScrollSpeed(_ delta: Int)`, `readerPrefs.autoScrollLevel` (1...10), `returnReaderToMain()`.
- Produces: a control strip inside `FloatingReaderView`; no new public API.

- [ ] **Step 1: Add the strip** as an overlay at the bottom of `FloatingReaderView`: play/pause (`play.fill` / `pause.fill`, calls `appState.toggleAutoScroll()`), speed minus and plus (`bumpAutoScrollSpeed(-1)` / `(+1)`, with the level shown as `"\(level)/10"`), "return to main window" (`appState.returnReaderToMain()`), and close (`onClose`). Compact sizing so all fit at the 240 pt minimum width.

- [ ] **Step 2: Visibility rule.** Pause is always visible while `appState.autoScrollOn` is true. The other controls show on hover and fade after 2.5 s idle, mirroring `ReaderView`'s `wakeControls` / `IdleClock` / `runIdleTimer` pattern in `PlaceholderViews.swift`. When auto-scroll is off the whole strip follows the same hover rule.

- [ ] **Step 3: Single cleanup path.** Both Close and Return call `controller.close()` → `panel.close()` → `windowWillClose` (Task 1). Add no second teardown anywhere. Confirm `windowWillClose` is also what the native red button triggers (it does via the delegate).

- [ ] **Step 4: Build.** Run the build command. Expected: `Build complete!`.

- [ ] **Step 5: Manual check.** Start auto-scroll from the strip; Expected: scrolls, Pause remains visible after the rest fades. Close with the in-panel Close, then repeat with the native red button. Expected both times: auto-scroll is off (open the main reader: it is not moving) and `isReaderFloating` is false. Change speed with minus/plus. Expected: the level label changes and scroll speed visibly changes.

- [ ] **Step 6: Commit** (needs user go-ahead): `git commit -am "feat: floating reader control strip and unified close"`.

---

### Task 3: Main-window placeholder and position handoff

**Files:**
- Modify: `macApp/Nyora/NyoraApp/Views/PlaceholderViews.swift` (`ReaderView.body`, the `Group` starting at line ~837)
- Modify: `macApp/Nyora/NyoraApp/Views/FloatingReaderPanel.swift` (add `ReaderFloatingPlaceholder`)
- Modify: `macApp/Nyora/NyoraApp/Views/Reader.swift` (`WebtoonReaderV2`: capture and restore)
- Modify: `macApp/Nyora/NyoraApp/ViewModels/AppState.swift`

**Interfaces:**
- Consumes: Tasks 1-2 (`isReaderFloating`, `returnReaderToMain()`).
- Produces:
  - `struct ReaderFloatingPlaceholder: View` (reads `@EnvironmentObject appState`; text "Reading in floating window"; a Return button calling `appState.returnReaderToMain()`).
  - `AppState.readerScrollProgress: Double` — plain stored property, **not** `@Published` (it is written every scroll frame; publishing would re-render the app).
  - `AppState.restoreScrollOnAppear: Bool` — plain stored property.

- [ ] **Step 1: Placeholder branch.** In `ReaderView.body`, make the first branch `if appState.isReaderFloating { ReaderFloatingPlaceholder() } else if let chapter = ...` so exactly one `WebtoonReaderV2` exists. Verify the existing `else { ReaderEmptyLanding() }` is still reachable.

- [ ] **Step 2: Capture progress.** In `WebtoonReaderV2`'s existing `onScrollGeometryChange` action, also write `appState.readerScrollProgress = contentHeight > 0 ? y / contentHeight : 0` (extend `AutoGeo` with the content height rather than adding a second observer).

- [ ] **Step 3: Restore.** In `popOutReader()` and in the panel-close path, set `appState.restoreScrollOnAppear = true` (the close path is `windowWillClose`, Task 1). In `WebtoonReaderV2.onAppear`, after the existing jump to `readerPageIndex`, if `restoreScrollOnAppear` is true, wait about 0.4 s for layout, call `scrollPosition.scrollTo(y: appState.readerScrollProgress * <current content height>)`, then clear the flag. Reader widths differ (about 360 vs window width) and page heights scale with width, so a proportion is used instead of raw pixels.

- [ ] **Step 4: Build.** Run the build command. Expected: `Build complete!`.

- [ ] **Step 5: Handoff check (manual).** Open a chapter with tall images, scroll to roughly halfway down one image, pop out; Expected: panel opens near the same spot. Scroll further, return; Expected: main reader resumes within about one screen of where the panel was. If it lands more than a screen off, fall back to the page top (remove the fraction restore), keep the page-level jump, and report the limitation instead of tuning indefinitely.

- [ ] **Step 6: Rollover and library checks (manual).** (a) Let auto-scroll run to a chapter end in the panel so the next chapter loads, and return immediately. Expected: main shows the new chapter, page 1 area, no crash. (b) While popped out, open a different chapter from the library in the main window. Expected: the panel switches to it and the main window shows the placeholder or the library, never a second reader.

- [ ] **Step 7: Commit** (needs user go-ahead): `git commit -am "feat: floating reader placeholder and position handoff"`.

---

### Task 4: Quit, edge cases and final verification

**Files:**
- Modify: `macApp/Nyora/NyoraApp/Views/FloatingReaderPanel.swift` only if a check below fails.

**Interfaces:**
- Consumes: everything above. Produces: nothing new.

- [ ] **Step 1: Quit behaviour (manual).** With the panel open, quit Nyora (Cmd-Q). Expected: panel closes, no lingering window. Repeat with `nyora.app.exitConfirm` on (Settings) and choose Cancel. Expected: panel stays open and still works. Fix only if either fails.

- [ ] **Step 2: Frame persistence (manual).** Resize and move the panel, close it, pop out again. Expected: same size and position. Then, if a second display is available, drag the panel onto it, disconnect that display, and re-open the panel. Expected: panel appears on a visible screen. If no second display is available, mark this check as not run.

- [ ] **Step 3: Regression pass (manual).** With the panel closed, use the normal reader: arrow keys, `A` auto-scroll, `N`/`P` chapter keys, scrub bar. Expected: unchanged (the `takesKeyboardFocus` default is `true`).

- [ ] **Step 4: Final build.** Run the build command once more. Expected: `Build complete!`.

- [ ] **Step 5: Report.** List files changed, which checks ran and which were manual or not run, and the final panel configuration chosen in Task 1 Step 7. Do not push; ask before opening a PR.

---

## Self-Review

- **Spec coverage:** pop-out (T1), floating/all-Spaces/no focus theft (T1), phone size/resizable/remembered (T1), auto + manual scroll and rollover (reuse; T2/T3 checks), control strip with Pause-visible rule (T2), single close path (T1+T2), placeholder and one reader (T3), position handoff with fallback (T3), quit and frame edge cases (T4), review points 1-3 (T1 Step 7, T3 Step 5-6, T2).
- **Types:** `takesKeyboardFocus`, `isReaderFloating`, `popOutReader()`, `returnReaderToMain()`, `readerScrollProgress`, `restoreScrollOnAppear`, `FloatingReaderController`, `FloatingReaderView(onClose:)`, `ReaderFloatingPlaceholder` are used with the same names in every task.
- **Known limits, stated up front:** no automated tests; progress restore is best-effort with a defined fallback; running the app needs the helper jar and JDK 17.
