# Cthugha (macOS 26)

A modern, native reimagining of **Cthugha**, the mid‑1990s "oscilloscope on
acid" music visualizer by Kevin "Zaph" Burfitt. It captures the audio your Mac
is playing (Spotify, Apple Music, browser, anything) and renders classic
Cthugha‑style flames — a feedback buffer that is warped, decayed and smeared
every frame with the audio waveform drawn on top and a rotating colour palette.

Built with Swift + Metal + ScreenCaptureKit. No Xcode project required.

It ships with a custom app icon, a Dock badge showing the active audio source
(`SYS`/`MIC`), and a **now‑playing overlay** that reads the current track from
Spotify or Apple Music.

## Build

```bash
./build.sh
```

This compiles `Sources/*.swift`, precompiles the Metal shaders into a bundled
`Contents/Resources/default.metallib` (falling back to runtime compilation if
the Metal toolchain is missing), bundles `Cthugha.app`, and signs it.

> The Metal command‑line toolchain is required to bake the `.metallib`. Install
> it once with: `xcodebuild -downloadComponent MetalToolchain`. Without it the
> app still works — it just compiles the shaders at launch.

### Code signing (keeps your permissions)
`build.sh`/`install.sh` sign with a **stable identity** so macOS privacy grants
(Screen Recording, Automation) survive rebuilds — ad‑hoc signing changes the
code hash every build and makes macOS forget them. By default it uses the
`Developer ID Application: qualified.ink GmbH (5R57LQA4MP)` certificate with the
**hardened runtime** enabled and the entitlements in `Cthugha.entitlements`
(audio‑input + Apple Events); override the identity with `CODESIGN_IDENTITY="…"`
(e.g. an Apple Development cert), or it falls back to ad‑hoc if the identity
isn't in your keychain. The first install after switching identities asks you to
grant permissions once more; after that, rebuilds keep them.

### Notarization (release builds)
The published release build is **notarized by Apple and stapled**, so it launches
with no Gatekeeper warning. To notarize your own build:

```bash
# one-time: store an App Store Connect API key as a keychain profile
xcrun notarytool store-credentials cthugha-notary \
  --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>

./build.sh
ditto -c -k --keepParent Cthugha.app Cthugha.zip
xcrun notarytool submit Cthugha.zip --keychain-profile cthugha-notary --wait
xcrun stapler staple Cthugha.app
```

Notarization requires the hardened runtime (already set by `build.sh`) and an
in‑effect Apple Developer Program License Agreement for the signing team.

## Install

```bash
./install.sh
```

Builds and copies `Cthugha.app` to **/Applications** (or `~/Applications` if the
system folder isn't writable), then re‑signs it so it lives alongside your other
apps.

## Run

```bash
open Cthugha.app                       # windowed
open Cthugha.app --args --fullscreen   # start in full screen
```

You can also make full screen the default: in the menu bar choose
**View → Start in Full Screen** (persisted across launches), or launch with the
`--fullscreen` flag.

### Audio permission (important)
Cthugha captures **system audio** through ScreenCaptureKit, which macOS gates
behind the **Screen Recording** privacy permission (only the audio is used —
no screen frames are consumed).

1. On first launch macOS will either prompt you or silently deny.
2. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
3. Enable **Cthugha**, then relaunch.

If system audio is unavailable/denied, Cthugha automatically falls back to the
**microphone / line‑in** (matching the original, which used mic/line/CD input).
Press **i** to switch sources at any time. The Dock badge shows `SYS` or `MIC`.

### Source menu — visualise a single app
The menu bar has a **Source** menu that lists **All System Audio**, the
**Microphone**, and every application that is currently producing sound
(Spotify, Apple Music, a browser, …). Pick one to visualise just that app's
output. This uses **Core Audio process taps** (macOS 14.4+) and needs **no
Screen Recording permission** — selecting Spotify works instantly, and the app
keeps playing normally while you watch. The menu refreshes each time you open
it, so start playback first if an app isn't listed yet. The Dock badge shows a
short tag for the selected app (e.g. `SPO`).

### Style menu — one‑tap look presets
Beyond the individual palette/motion controls, a **Style** menu (and the `v`
key) cycles between named looks inspired by the classic Cthugha screenshots:

- **Current** — whatever you've dialled in by hand (your live custom look).
- **Solar Flare** — hot, punchy orange‑yellow flames.
- **Oil Shimmer** — iridescent, oily rainbow sheen with a quad kaleidoscope fold.
- **Metallic Lightning** — electric steel‑blue / silver arcs, mirrored left‑right.
- **Blue Fire** — cool blue flames.

Press `v` to step forward through the presets and `⇧v` to step back. Selecting a
preset from the menu jumps straight to it. Your hand‑tuned settings are preserved
as **Current**: any manual tweak (palette, decay, swirl, …) returns you there, so
you never lose your own look by trying a variation.

### Now-playing overlay
A subtle pill in the bottom‑left shows the current **Spotify / Apple Music**
track. The first time it reads a track, macOS asks to allow Cthugha to control
that app (**Automation** permission) — approve it, or manage it later under
**System Settings → Privacy & Security → Automation**. Only apps that are
already running are queried; Cthugha never launches them.

### App icon
The icon is generated from `tools/MakeIcon.swift`. Regenerate it with:

```bash
./tools/makeicon.sh     # writes Assets/AppIcon.icns
```

`build.sh` bundles `Assets/AppIcon.icns` into the app automatically.

## Controls

| Key | Action |
| --- | --- |
| `space` / `m` | Next motion mode (Flame → Swirl → Ripple → Tunnel) |
| `p` | Next palette (Fire, Ice, Acid, Plasma, Mono, Rainbow) |
| `←` `↓` / `→` `↑` | Previous / next colour palette |
| `v` / `⇧v` | Next / previous **style** preset |
| `c` | Toggle automatic colour cycling |
| `i` | Toggle audio source (system ↔ microphone) |
| Source menu | Pick a specific app to visualise (Spotify, Music, a browser…) |
| Style menu | Jump straight to a look preset |
| `+` / `-` | Wave amplitude |
| `,` / `.` | Feedback decay (trail length) |
| `[` / `]` | Intensity / brightness |
| `9` / `0` | Swirl strength |
| `f` | Toggle full screen (also ⌃⌘F) |
| `esc` | Leave full screen |
| `h` | Print help to the console |

The current mode/palette/source is shown in the window title. Every command
above is also available from the **Controls** menu in the menu bar (with its
shortcut shown), so you can drive the visuals without memorising the keys.

## How it works

Each frame runs the classic Cthugha loop on the GPU:

1. **Warp + decay** (`warp` compute kernel): the previous frame's intensity
   buffer is resampled through a motion field (rise, swirl, ripple or tunnel),
   blurred slightly, and multiplied by a decay factor — this is the "flame map".
2. **Oscilloscope** (`waveVertex`/`waveFragment`): the latest 512 audio samples
   are drawn as an additive line strip into the intensity buffer, injecting
   fresh energy the flames spread from.
3. **Palette** (`presentVertex`/`presentFragment`): the single‑channel intensity
   buffer is coloured through a 256‑entry palette with an optional rotation
   offset for the classic colour‑cycling look.

Two `r16Float` textures are ping‑ponged for the feedback. Audio is captured as
mono with light auto‑gain so visuals stay lively regardless of volume.

## Files

- `Sources/Shaders.swift` — Metal shader source (bundled as `.metallib`, or compiled at runtime).
- `Sources/AudioEngine.swift` — system audio (ScreenCaptureKit) + mic fallback.
- `Sources/ProcessAudio.swift` — per‑app capture via Core Audio process taps + the Source menu's app list.
- `Sources/Renderer.swift` — Metal pipeline, feedback buffers, palettes.
- `Sources/NowPlaying.swift` — Spotify / Apple Music track monitor (AppleScript).
- `Sources/Overlay.swift` — the now‑playing overlay pill.
- `Sources/main.swift` — AppKit window, Metal view, keyboard controls, full‑screen preset, Dock badge.
- `tools/MakeIcon.swift`, `tools/makeicon.sh` — app icon generator.
- `Info.plist`, `build.sh`, `install.sh`.
