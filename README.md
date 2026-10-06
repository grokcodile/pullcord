<img src="docs/icon.png" alt="Pullcord Icon" width="96"/>

# Pullcord

[![Latest release](https://img.shields.io/github/v/release/grokcodile/pullcord?sort=semver&label=release)](https://github.com/grokcodile/pullcord/releases/latest)
[![Homebrew](https://img.shields.io/badge/Homebrew-grokcodile%2Ftap-C9782E?logo=homebrew&logoColor=white)](https://github.com/grokcodile/homebrew-tap)
[![Downloads](https://img.shields.io/github/downloads/grokcodile/pullcord/total)](https://github.com/grokcodile/pullcord/releases)
[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-111111)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

**The most powerful things macOS can do are often the hardest to reach — Pullcord puts them at your fingertips.**

<img src="docs/Screenshot-dark.png" alt="The Pullcord settings window: twelve tools grouped into Spotlight Panels, System Utilities and Text Tools, each with its keyboard shortcut" width="608"/>

macOS ships the hard part and leaves out the key. Screen OCR, color sampling, sleep prevention, dictation, on-device text cleanup — the engines are all in the box, on-device, already paid for, and mostly a menu dive or a Settings pane away. That gap is a whole category of paid utilities: apps that bundle their own engine, or their own subscription, to sell you a keystroke. Pullcord is a dozen of those keystrokes in one background agent — no menu bar item, no account, no subscription, nothing leaving your Mac.

It's also built to be temporary wherever it can be. Each tool covers a convenience macOS misses by a hair, so when a future release closes that gap, the tool comes out. **The app getting smaller as the system gets better is a success, not a regression.**

## What it leverages instead of reinventing

Every tool here is a thin shortcut onto something macOS already does. Nothing bundles its own engine.

| Tool | What macOS does the work | Instead of |
|---|---|---|
| **Apps** | Spotlight's Applications panel | Alfred, Raycast, LaunchBar (paid tiers) |
| **Files** | Spotlight's Files panel — the same index Finder searches | Alfred / Raycast file search, Find Any File |
| **Actions** | Spotlight's Actions panel — Shortcuts and system actions by name | Raycast commands, Alfred workflows |
| **Clipboard** | Spotlight's own clipboard history | Paste, Copy'em, Raycast clipboard history |
| **System Settings** | System Settings, with a remembered "toggle back" | — |
| **Keep Awake** | **Power assertions** — the same mechanism as `caffeinate` | Amphetamine, Caffeine, KeepingYouAwake |
| **Color Picker** | The system's own **color loupe** | Sip, ColorSlurp (paid tiers) |
| **Color History** | Pullcord's own history of your picks | the paid tier of most color pickers |
| **Speak Text** | **Spoken Content** — macOS's own text-to-speech, its Siri voices, its shortcut | text-to-speech utilities |
| **Capture Text** | **Vision** — Apple's on-device text recognition | TextSniper (paid) |
| **Rewrite Text** | **Apple Intelligence**'s on-device model | Grammarly and friends (subscriptions) |
| **Dictate Text** | **macOS Dictation**, on-device | Wispr Flow, superwhisper (subscriptions) |

The four Spotlight panels are the starkest case: an app launcher, a file searcher, a command runner and a clipboard history are four separate paid utilities in most people's setups, and macOS 26 ships all four — behind one keystroke and a number. They just needed keys of their own.

Two more that make the point:

- **Dictate Text** — dictation apps sell push-to-talk with their own speech model and a monthly bill. Your Mac already transcribes on-device, for free, at least as well. The *only* thing it lacks is hold-to-talk: macOS dictation is toggle-only. So that's all this adds — the missing key, on top of Apple's transcription.
- **Rewrite Text** — cleaning up, restyling or translating text is exactly what an on-device LLM is for, and macOS 26 ships one. No API key, no per-token cost, no text uploaded anywhere.

## Features

**Spotlight Panels**

- A global shortcut for each of **Apps, Files, Actions, Clipboard**. One shortcut per panel; recording a combo another panel owns moves it over.
- **Apps** opens instantly and needs no permissions.
- **Files / Actions / Clipboard** open Spotlight straight to that panel, with an empty search field ready for typing.

**System Utilities**

- **System Settings** — with **Smart Toggle**, it opens with the cursor already in the search field, so you can type the setting you want instead of hunting for it, and pressing the shortcut again hides it and returns you to the app you came from.
- **Keep Awake** — stops your Mac sleeping; a cup appears in the menu bar while it's on (click to stop), and **Screen Sleep** lets the display sleep while the system stays up. It switches off automatically if Pullcord quits, so it can't strand your Mac awake.
- **Color Picker** — pops the system loupe and copies the pixel under your cursor as **Hex, RGB, HSL, or SwiftUI**, plus the raw color for dropping into a color well. A pill flashes the swatch and code, and every pick is saved to Color History.
- **Color History** — a window of everything you've picked. **Click** a swatch to re-copy its code, **drag** it out to save the swatch as a PNG, **pin** the keepers. Labels default to the hex and can be renamed. Keeps the last 20; pins persist at the top.

**Text Tools**

- **Speak Text** — reads the selected text aloud using macOS's own **Speak selection**, so you get the Siri voices, which apps can't use directly. The card shows the shortcut macOS has assigned it, and **Configure…** walks you through switching it on in Read & Speak.
- **Capture Text** — drag a region and its text is recognized on-device and copied, with a pill showing how much was grabbed. **Remove Breaks** flows it onto one line. A native TextSniper.
- **Rewrite Text** — **tap ⌃ twice** to rewrite the selected text with Apple Intelligence's on-device model; it asks you to select something if you haven't. It holds any number of named **rewrite actions** — **Clean Dictation** ships built in at the top, alongside Proofread, Professional, Friendly, Shorten, Translate to Spanish and Wrap in HTML — and the shortcut offers a menu of the ones you've selected. Tick none and it runs Clean Dictation; tick one and it runs straight through. Any action can also take a shortcut of its own, which skips the menu whether or not it's ticked.
- **Dictate Text** — hold **Right ⌥** or **Right ⌘** and it dictates; release and it stops. It's the same thing the dictation key does, on a key you can hold, and macOS shows its usual dictation indicator while you talk. Dictation keeps running for about a second after you let go, so macOS can finish the last of the transcription — press the key again in that window and it carries straight on. To tidy up what you said, select it and run **Clean Dictation** from Rewrite Text.

**Throughout**

- Every control has a one-line tooltip, and the **ⓘ** in the title bar opens About: the version, Website, User Guide and Bug Report, and ways to support the app. What each of the twelve tools does, with a couple of uses each, is in [HELP.md](HELP.md).
- Shortcut conflicts with other apps are shown in the settings window rather than failing silently.
- Runs as a background agent — no Dock icon, no menu bar item — and starts at login. Opening it again brings up settings.

## Install

### Homebrew (easiest — also handles updates)

```sh
brew install --cask grokcodile/tap/pullcord
```

New versions arrive with `brew upgrade --cask pullcord`.

### Download the disk image

1. Download the latest **[Pullcord.dmg](https://github.com/grokcodile/pullcord/releases/latest/download/Pullcord.dmg)** (or browse [all releases](https://github.com/grokcodile/pullcord/releases)).
2. Open the `.dmg` and drag **Pullcord** into your `Applications` folder.

Pullcord is signed and notarized by Apple, so it opens normally — no "unidentified developer" warning. macOS may show a one-time "downloaded from the Internet" confirmation; just click **Open**.

> **Apple Silicon, macOS 26 or later.**

### Updates

Pullcord checks for a new release when you open it and each time you open its settings. It never checks in the background while you work: when it starts at login it checks once, and shows its window only if there's an update waiting.

When one is available, a blue strip with an **Update** button appears across the bottom of the settings window. A Homebrew install upgrades and reopens on the new version by itself. A disk-image install downloads the new `.dmg`, opens it, and quits so you can drag the new version over the old one.

That update check is the only network request Pullcord makes — see [PRIVACY.md](PRIVACY.md).

### Build from source

On an Apple Silicon Mac with macOS 26 and Apple's command-line tools (`xcode-select --install`):

```sh
bash install.sh
```

This builds Pullcord, installs it to `/Applications` and launches it.

## Requirements

- **macOS 26 or later** (the four-panel Spotlight), on an **Apple Silicon** Mac.
- **Accessibility** — for anything that presses keys or menu items for you: Files, Actions, Clipboard, the System Settings shortcut, Dictate Text, and Rewrite Text.
- **Screen Recording** — for **Capture Text** only (macOS requires it for the region selector).
- **Apple Intelligence** — for **Rewrite Text**, which uses the on-device model. Without it that one tool is unavailable; everything else is unaffected.

Nothing needs setting up in advance: macOS prompts the first time a shortcut needs a permission. The settings window shows a light for each, and clicking a red one asks for it directly.

**Apps, Color Picker, Color History, Keep Awake and Speak Text need no permissions at all.**

## First run

1. Launch **Pullcord**. Its settings window opens.
2. Record a shortcut for each tool you want, then click **Done**. It keeps running in the background and starts at login — silently, without showing the window.
3. The first time you fire a shortcut that needs a permission, macOS asks. The light turns green once granted.

## Shortcuts

A fresh install comes with a working set already assigned — **⌃⌥⌘ plus a key under your right hand**:

| | | | |
|---|---|---|---|
| ⌃⌥⌘. Applications | ⌃⌥⌘/ Files | ⌃⌥⌘\\ Actions | ⌃⌥⌘V Clipboard |
| ⌃⌥⌘, System Settings | ⌃⌥⌘K Keep Awake | ⌃⌥⌘P Color Picker | ⌃⌥⌘H Color History |
| ⌃⌥⌘O Capture Text | Hold **Right ⌥** to dictate | Rewrite Text: **tap ⌃ twice** | Speak Text: macOS's own |

Three modifiers look heavy written down, but your left hand holds them as one shape and never moves, so every trigger key sits under the right. It's also a combination other apps rarely claim.

The keys are easy to remember. **`/` finds and `\` does** — mirrored symbols, one for paths, one for escapes. **`,`** is the preferences key every Mac app already uses, **`V`** the paste key for the paste history. The rest are initials: **P**icker, **H**istory, **K**eep awake, **O**CR.

**Return and Delete can't be assigned**, and the recorder refuses them: Return would land in the panel the shortcut just opened, and Delete is how you clear a binding.

Change any of them by clicking the field and recording, or press **Delete** while recording to clear it. Defaults are only ever applied to a tool that has no shortcut yet, so they can't overwrite something you've set.

Two tools work differently:

- **Dictate Text** takes a **held key** (Right ⌥ or Right ⌘) rather than a chord, because push-to-talk needs to know when you let go.
- **Speak Text** has no Pullcord shortcut at all. It shows the one **macOS** has assigned to Speak selection, since that feature is macOS's own.

Each card carries one option: **Smart Toggle** for System Settings (on), **Screen Sleep** for Keep Awake (on), the copy **format** for Color Picker (Hex), **View…** for Color History, **Remove Breaks** for Capture Text (on), **Settings** for Rewrite Text, and the **hold key** for Dictate Text (Right ⌥).

## How it works

**Shortcuts** are ordinary system-wide hotkeys, so Pullcord doesn't watch everything you type. The one exception is Dictate Text, which watches only the modifier key you hold to talk.

**Apps** opens macOS's own Apps launcher directly. The other **Spotlight panels** are opened the way you'd open them yourself — ⌘Space, then the panel's number — after which Pullcord clears any leftover search text.

**Color Picker** uses the system's color loupe. macOS does the sampling, not Pullcord, so Pullcord never reads your screen and doesn't need Screen Recording. Each pick is copied as code text plus the color itself, for pasting into a color well.

**Capture Text** uses macOS's screenshot region selector, then Apple's on-device text recognition. Nothing leaves your Mac.

**Keep Awake** holds the same kind of power assertion `caffeinate` uses — the display or the system variant, depending on Screen Sleep. Quitting Pullcord always releases it.

**Dictate Text** presses **Edit ▸ Start Dictation** in the app you're using, through the Accessibility API, so your own dictation settings — language, microphone — are used unchanged. It stops about a second after you let go, so macOS can finish transcribing.

**Rewrite Text** sends the selected text to Apple Intelligence's on-device model with the action's instructions — no account, no API key, nothing uploaded. Pullcord copies the selection, rewrites it, and pastes the result over it; the result also stays on the clipboard, and ⌘Z undoes it. Short selections come back in about a second, long ones can take much longer; after 45 seconds it gives up and says **Took Too Long**. If the selection disappears while the model is working, Pullcord asks you to select again rather than pasting in the wrong place.

## Built on macOS, and moving with it

Pullcord targets **macOS 26** and deliberately uses what that release ships — the four-panel Spotlight, on-device text recognition, Spoken Content, macOS Dictation, Apple Intelligence's local model. That's the point of the app, and also its exposure: it is a thin layer over Apple's own behavior, so when that behavior moves, this moves with it.

Some of what's here rests on things Apple never promised to keep still — the Spotlight ⌘Space gesture and its panel numbers, the **Edit ▸ Start Dictation** menu item that Dictate Text presses, the Spoken Content preference that Speak Text reads. Those work today. A future macOS could rename a menu item, restructure a pane, or change how a panel opens, and the tool that leans on it would need adjusting.

**The better outcome is that Apple absorbs some of this.** Several of these tools exist purely because a convenience is missing by a hair: dictation transcribes beautifully but is toggle-only; the Spotlight panels have numbers but no global keys; the loupe samples a color but keeps no history. If macOS grows push-to-talk dictation, or lets you bind a panel directly, then that card has served its purpose and should be removed rather than defended. Pullcord is meant to be scaffolding over the gaps, not a permanent parallel implementation.

So: expect this to track macOS releases, expect the occasional fix when Apple shifts something underneath, and expect features to retire when the system makes them unnecessary.

## Uninstall

1. Open Pullcord, toggle the switch to **Disabled** (this removes the login item), then click **Quit**. (Or just `killall Pullcord`.)
2. Delete **Pullcord.app** from `Applications`.
3. Optionally remove its entry under System Settings → Privacy & Security → Accessibility.

Installed with Homebrew, steps 1 and 2 are `brew uninstall --cask pullcord`; add `--zap` to remove its preferences too.

## The name

You pull a cord without looking for it — that's the bar: the thing you want, on, in one motion, from anywhere. A pull cord is the switch you can work in the dark, with your hands where they already are, which is the whole argument for a keyboard shortcut. And it stays out of the way: no Dock icon, no menu bar item, no data collection.

## Why it isn't on the Mac App Store

Pullcord presses keys and menu items in other apps to drive Spotlight and Dictation, which the App Store's sandbox doesn't allow. It's distributed directly instead — signed and notarized by Apple.

## License

Released under the [MIT License](LICENSE).

## Author

Built by **Ethan Darling** — [@grokcodile](https://github.com/grokcodile) on GitHub · [u/grokcodile](https://www.reddit.com/user/grokcodile) on Reddit · [LinkedIn](https://www.linkedin.com/in/ethandarling/).
