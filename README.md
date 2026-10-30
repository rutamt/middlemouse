# FreeWheel

A lightweight macOS menu bar app that adds middle click to any Mac, plus Windows-style auto-scroll. It has no Dock icon, no main window and no external dependencies.

## Features

- **Key + click:** hold a key of your choice (fn, Control, Option, Command or Shift) and left click to middle click. Dragging works too, and keeps going if you let go of the key before the button, which suits CAD panning.
- **Three-finger click and tap:** middle click from the trackpad.
- **Auto-scroll:** hold the mouse wheel briefly, then move the cursor to scroll, while a quick wheel click stays a normal middle click. The further the cursor is from the marker, the faster the page scrolls. Choose which gestures start it, and set the hold time, direction and sensitivity.
- **Per-app controls:** turn FreeWheel off entirely in an app, or turn off only auto-scroll.
- **Hideable menu bar icon:** open the app again to bring the icon back.
- **Start at login**

## Requirements

- macOS 13 or later
- Accessibility permission, which FreeWheel needs to read and change mouse events
- Xcode Command Line Tools, to build it (`xcode-select --install`); Xcode itself isn't needed

## Install

Build the disk image:

```bash
./make_dmg.sh
```

Open `FreeWheel.dmg` and drag FreeWheel to Applications. Launch it from there, then:

1. Click the FreeWheel icon in the menu bar.
2. Click **Accessibility Permission: Needs Access**.
3. Turn FreeWheel on in System Settings > Privacy & Security > Accessibility.

The menu row changes to **Granted** within a couple of seconds, with no restart.

The app is ad-hoc signed, not notarized. On a Mac other than the one that built it, approve the first launch under System Settings > Privacy & Security > Open Anyway.

## Usage

| Menu item | What it does |
| --- | --- |
| Middle Click Shortcut | Picks the key for key + click, or turns it off |
| Three-Finger Click / Three-Finger Tap | Middle click from the trackpad |
| Auto-Scroll | Sets what starts auto-scroll (Mouse Wheel Click, Three-Finger Click, Three-Finger Tap), Hold Time, Reverse Direction and Sensitivity |
| Ignore [App] | Turns off all of FreeWheel in the frontmost app |
| No Auto-Scroll in [App] | Turns off only auto-scroll in the frontmost app, for example a CAD app that needs the wheel button |
| Start at Login | Launches FreeWheel when you log in |
| Hide Menu Bar Icon | Hides the icon until you open FreeWheel again or press fn + Control + Option + M |

### Auto-scroll

- **Quick wheel click:** a normal middle click, so links open in new tabs as usual.
- **Hold past Hold Time (0.15 s by default), or press and drag, then release:** scrolling runs until the next click or key press.
- **Keep the wheel down and scroll for over a second:** scrolling stops when you release.

What's under the start point keeps scrolling wherever you move the mouse, even over other windows or the menu bar. The real pointer stays frozen during auto-scroll while a stand-in arrow follows your hand, and the pointer lands where the arrow ended up when you stop.

On a trackpad, a gesture set to start auto-scroll no longer middle clicks, but you can have a three-finger click start auto-scroll and keep a three-finger tap as a middle click. Key + click is always a real middle click.

## Build from source

```bash
./build.sh
open FreeWheel.app
```

This creates `FreeWheel.app` in the project folder. Each rebuild changes the ad-hoc signature, so macOS stops honoring the earlier Accessibility grant even though System Settings still shows it on. After rebuilding, reset it and grant it again:

```bash
tccutil reset Accessibility com.freewheel.FreeWheel
```

To skip this, create a self-signed code signing certificate in Keychain Access and build with `SIGN_IDENTITY="Your Certificate Name" ./build.sh`.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Menu says **Needs Access** but System Settings shows FreeWheel on | Run the `tccutil` command above, then grant access again |
| Three-finger gestures misbehave | Check for conflicts with "Tap with Three Fingers" under Trackpad > Point & Click, and "Three Finger Drag" under Accessibility > Pointer Control > Trackpad Options |
| fn + click does nothing | Another tool may be remapping fn, such as Karabiner. Choose a different key under **Middle Click Shortcut** |
| Icon is hidden | Open FreeWheel again from Spotlight or Finder |

## Limitations

- FreeWheel can't tell two mice apart, so auto-scroll settings apply to every mouse.
- Three-finger features use `MultitouchSupport`, a private Apple framework. If a future macOS removes it, those options gray out and the rest of the app keeps working.

## Project layout

| File | Purpose |
| --- | --- |
| `main.swift` | App delegate, menu, permissions, settings |
| `EventTapManager.swift` | Event tap, click rewriting, ignore lists, keyboard shortcut |
| `AutoScrollManager.swift` | Auto-scroll engine, on-screen marker, sensitivity slider |
| `TrackpadManager.swift` | Multitouch bridge and gesture recognition |
| `generate_icon.swift` | Draws the app and menu bar icons |
| `build.sh` / `make_dmg.sh` | Build the app and the disk image |
