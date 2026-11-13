# SidePanel

A hidden, floating macOS panel with its own **web browser** and its own **terminal**.
Press a shortcut (default **⌥Space**) or push the pointer against the screen edge,
and the panel slides in. Press **Esc** and it's gone.

- **Browser:** an original interface over the system WebKit engine. It has tabs, a combined address and search bar with suggestions, back/forward/reload, bookmarks, history, downloads, page zoom, a start page and error pages. It never opens Safari or Chrome.
- **Terminal:** SidePanel's own xterm-compatible emulator, connected to a real PTY (`forkpty`) running your login shell. It supports multiple sessions, scrollback, 256-colour and true-colour, the alternate screen (vim, htop, less), mouse reporting, bracketed paste, IME input, selection and copy/paste, and drag-and-drop of files. It never opens Terminal.app or any other terminal.
- **Panel:** a background accessory app (no Dock icon). It has a customizable global hotkey and optional screen-edge reveal. You can dock it left, right or top-centre, or leave it wherever you drag it. It can be resized and pinned on top, it animates in and out, and it remembers the last section you used.

## Screenshots

These were captured automatically by CI from the real app running on a macOS runner.

| Browser | Terminal | Settings |
|---|---|---|
| ![Browser](docs/screenshots/browser.jpg) | ![Terminal](docs/screenshots/terminal.jpg) | ![Settings](docs/screenshots/settings.jpg) |

## Project layout

```
Package.swift                 Swift Package (Swift 5.9+, macOS 13+)
Sources/CPTY/                 C shim: forkpty / TIOCSWINSZ / process info (async-signal-safe)
Sources/SidePanelCore/        Platform-independent engine (Foundation only)
  Terminal/                   TerminalEmulator (VT/xterm parser + screen), KeyEncoder, PTYProcess
  Browser/                    AddressResolver, search engines, bookmarks, history, suggestions
  Support/                    JSON persistence
Sources/SidePanel/            The macOS app
  App/                        entry point, AppDelegate, floating panel, hotkey, edge activation, menus
  Browser/                    WKWebView tabs, address field, start page, library, downloads
  Terminal/                   TerminalView (CoreText renderer + input), sessions, palette
  Settings/                   in-panel settings, shortcut recorder
  UI/                         theme, custom glyph set, tab strip, window chrome
Tests/SidePanelCoreTests/     Unit tests: emulator, key encoding, PTY, address bar, library
Packaging/                    Info.plist, entitlements, AppIcon.icns
scripts/                      build_app.sh, make_dmg.sh, generate_icon.py
.github/workflows/build.yml   Cloud build: tests on Linux + macOS, builds the .app and .dmg
```

The core is separate from the app so each feature can be developed and tested on its own. The terminal engine, PTY layer and browser logic have no AppKit dependency, and CI runs their tests on Linux as well as macOS.

There are no third-party dependencies. The app uses only Apple system frameworks: AppKit, SwiftUI, WebKit, Carbon (for the hotkey) and ServiceManagement (for launch at login).

## Getting the app without a Mac toolchain (cloud build)

Every push runs **GitHub Actions** (`.github/workflows/build.yml`) on an Apple Silicon macOS runner. The workflow:

1. runs the unit tests (on Linux and macOS),
2. builds a universal (arm64 + x86_64) `SidePanel.app`,
3. launches it as a smoke test,
4. packages `SidePanel-<version>.dmg`.

To download the result, open the repository's **Actions** tab, choose the latest **Build** run and download the `SidePanel-dmg` artifact (or `SidePanel-app`). Open the DMG and drag SidePanel to Applications.

CI builds are **ad-hoc signed**. The first time you open one, macOS Gatekeeper will block it. You can get past this in either of two ways:
- right-click SidePanel.app, choose **Open**, then **Open** again, or
- run `xattr -dr com.apple.quarantine /Applications/SidePanel.app`.

If you want the cloud builds to be signed and notarized, see the "Signing and notarization in CI" section below.

## Building locally

You don't need Xcode. Apple's free Command Line Tools are enough:

```sh
xcode-select --install          # once; installs swift, codesign, hdiutil

swift test                      # run the unit tests
scripts/build_app.sh            # → dist/SidePanel.app (arm64, ad-hoc signed)
scripts/make_dmg.sh             # → dist/SidePanel-1.0.0.dmg
open dist/SidePanel.app
```

To build a universal binary, run `ARCHS="arm64 x86_64" scripts/build_app.sh`.

If you prefer to work in Xcode, it can open `Package.swift` directly.

To change the icon, edit and run `python3 scripts/generate_icon.py`, which needs Pillow. It regenerates `Packaging/AppIcon.icns`.

## Signing, notarizing and packaging for distribution

An ad-hoc signature is fine for your own Macs. To give the app to other people without Gatekeeper warnings, you need an Apple Developer account ($99/year).

1. **Create a Developer ID certificate.** At developer.apple.com, go to Certificates and create a *Developer ID Application* certificate. Install it in your login keychain. To find its exact name, run `security find-identity -v -p codesigning`.
2. **Sign with the Hardened Runtime.** `build_app.sh` adds `--options runtime --timestamp` automatically when an identity is given:
   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   BUNDLE_ID="com.yourname.SidePanel" \
   ARCHS="arm64 x86_64" scripts/build_app.sh
   ```
3. **Store notarization credentials once.** Use an app-specific password from appleid.apple.com:
   ```sh
   xcrun notarytool store-credentials sidepanel-notary \
       --apple-id you@example.com --team-id TEAMID --password abcd-efgh-ijkl-mnop
   ```
4. **Build, sign, notarize and staple the DMG:**
   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE=sidepanel-notary scripts/make_dmg.sh
   ```
   This creates the DMG (with an Applications shortcut), signs it, submits it to Apple, waits for approval, and staples the ticket. The resulting `dist/SidePanel-<version>.dmg` opens cleanly on any Mac running macOS 13 or later.

The app is **not sandboxed**, and this is deliberate. A terminal has to run arbitrary programs, which App Sandbox forbids. That is why the app is distributed through Developer ID and a DMG, not the Mac App Store. The entitlements in `Packaging/SidePanel.entitlements` only grant camera, microphone and location, so that websites can ask for them through WebKit's normal prompts, plus Apple Events for terminal commands such as `osascript`.

### Signing and notarization in CI (optional)

You can add repository secrets and import the certificate into a temporary keychain before the build step. You would need:
- the certificate as a base64 `.p12` plus its password,
- your Apple ID, team ID and an app-specific password.

Then run the same two scripts with `SIGN_IDENTITY` and `NOTARY_PROFILE` set. The workflow currently skips this, so it works without any secrets.

## Using SidePanel

| Action | Shortcut |
|---|---|
| Show / hide panel | ⌥Space (change it in Settings) |
| Hide | Esc, or ⇧Esc (always works, even inside vim) |
| Browser / Terminal | ⌘1 / ⌘2 |
| New tab or session / close | ⌘T / ⌘W |
| Next / previous tab | ⌃Tab / ⌃⇧Tab (also ⌘⇧] / ⌘⇧[) |
| Go to tab 1–9 | ⌥⌘1 … ⌥⌘9 |
| Address bar | ⌘L (↑/↓ choose a suggestion, ⌘Return opens in a new tab) |
| Back / forward / reload | ⌘[ / ⌘] / ⌘R |
| Bookmark page / Library / Downloads | ⌘D / ⌘Y / ⌥⌘L |
| Zoom page or terminal font | ⌘+ / ⌘− / ⌘0 |
| Clear terminal | ⌘K |
| Scroll terminal history | trackpad, ⇧PageUp/PageDown, ⌘↑ / ⌘↓ |
| Line start / end / delete line (terminal) | ⌘← / ⌘→ / ⌘⌫ |
| Word left / right (terminal) | ⌥← / ⌥→ |
| Pin on top | ⇧⌘P |
| Settings | ⌘, |

More behaviour:
- **Moving and resizing.** Drag the header to move the panel; this switches it to "Where I leave it". Double-click the header to dock it again. Drag the panel's inner edges to resize it.
- **Menu bar icon.** Click it to toggle the panel. Right-click it for Settings and Quit.
- **Terminal tricks.** Drop files onto the terminal to paste their shell-quoted paths. A new session opens in the current session's working directory.

## How the pieces work

- **PTY.**
  - `sp_pty_spawn` calls `forkpty`. In the child it resets every signal disposition (GUI apps ignore SIGPIPE), closes inherited descriptors and `execve`s your login shell as `-zsh`.
  - The parent reads the master side with a `DispatchSource` and writes on a serial queue, so large pastes never block the UI.
  - Window resizes go through `TIOCSWINSZ`, so programs receive `SIGWINCH`.
- **Emulator.**
  - The parser is a byte-level VT500-style state machine with streaming UTF-8 decoding.
  - It handles CSI, ESC, OSC (window title, working directory), DCS pass-through and DEC line-drawing.
  - It supports scroll regions, origin and insert modes, wide and combining characters, alternate screen 47/1047/1049, cursor styles, and device status and attribute replies.
  - Scrollback is bounded, and lines move in and out of scrollback when the terminal is resized.
- **Renderer.**
  - Each frame draws background runs, the selection, text runs in the monospaced system font, then the cursor.
  - Non-ASCII glyphs are drawn cell by cell, so font fallback can't push the rest of a line off the grid.
- **Browser.** Each tab owns a `WKWebView`, and SwiftUI hosts the existing view without recreating it. Downloads go through `WKDownload` into `~/Downloads`. Bookmarks and history are stored as JSON in `~/Library/Application Support/SidePanel/`.
- **Hotkey.** Registered with Carbon `RegisterEventHotKey`, so it needs no Accessibility permission. Edge activation polls the pointer position, so it needs no permissions either.
