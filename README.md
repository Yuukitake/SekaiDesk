<div align="center">

# ✨ SekaiDesk

**Project Sekai Pop-Comic Desktop Shell for Windows 10 & Windows 11**

[Showcase](#showcase) &nbsp;|&nbsp; [Features](#features) &nbsp;|&nbsp; [Requirements](#requirements) &nbsp;|&nbsp; [Installation](#installation) &nbsp;|&nbsp; [Keybinds](#keybinds) &nbsp;|&nbsp; [Credits](#credits)

<br>

<div align="left">

> ✨ **Native Windows 10 & Windows 11 (64-bit) Support**
>
> Built and verified across both **Windows 10** and **Windows 11 (22H2 / 23H2 / 24H2+)** — including native Win11 XAML System Tray capture via `SekaiTrayHook.dll`, AppBar workarea reservation, native taskbar suppression with `--restore` failsafe, and zero-overhead Game Mode (`Hibernate` & `Zero-Footprint`).

</div>

<br>

<img src="assets/shot-desktop-hero.png" alt="SekaiDesk running on Windows with Transparent Top Bar, Capsule Dock, and Clock desktop widget" width="100%">

<sub>Transparent Top Bar, Capsule Bottom Dock, real-time system stats (CPU / GPU / RAM), Windows 10 &amp; 11 system tray integration, weather readout, and interactive desktop widgets.</sub>

</div>

<img src="assets/divider.svg" alt="" width="100%">

<h2 id="showcase"><img src="assets/tag-showcase.svg" alt="Showcase" height="72"></h2>

<table>
<tr>
<td width="50%" valign="top">
<img src="assets/shot-quick-panel.png" alt="Quick Panel 2.5D smartphone overlay with Wi-Fi/Ethernet, Bluetooth, Volume, Brightness, Media card and Notifications" width="100%">
<br><b>Quick Panel: a 2.5D smartphone control center</b><br>
Slide up the portrait phone with <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>A</kbd> (or click the right status pill) for Ethernet/Wi-Fi &amp; Bluetooth toggles, Game Mode &amp; Power Rail flyout (with 2-step Quit confirmation), microphone/speaker sliders, display brightness control, active SMTC media card, and notification feed. Incoming notifications also peek from the bottom-right corner.
</td>
<td width="50%" valign="top">
<img src="assets/shot-settings-phone.png" alt="Landscape Settings Hub showing 01 Quick, 02 General, 03 Bar, 04 Desktop, 05 Hotkeys & System, and 06 About cards" width="100%">
<br><b>Settings: flip the phone sideways</b><br>
Rotates the Quick Panel into a landscape Settings Hub with SekaiPop slanted keycap tiles, active-band left-to-right hover gradient wipe, quick band dots, and six structured pages: <b>01 Quick</b>, <b>02 General</b> (Unit palettes, Wallpaper Match &amp; Clock/Weather), <b>03 Bar</b>, <b>04 Desktop</b>, <b>05 Hotkeys &amp; System</b> (Game Mode, RTSS Guard, Taskbar Hide), and <b>06 About</b>.
</td>
</tr>
<tr>
<td colspan="2" valign="top">
<img src="assets/shot-edit-desktop.png" alt="Edit Desktop mode with interactive resize handles on Calendar, Profile, To-Do, Weather, Visualizer, Notes, Lyrics, and Clock" width="100%">
<br><b>Edit Desktop: drag, resize &amp; customize everything live</b><br>
Toggle <b>Edit</b> from the Top Bar to freely drag widgets across monitors, resize them with live corner &amp; edge handles, and customize Bar styles (<i>Float, Straight, Transparent, Capsule</i>), Dock rounding, Views, Unit Themes, and Presets on the fly.
</td>
</tr>
</table>

<img src="assets/divider.svg" alt="" width="100%">

<h2 id="features"><img src="assets/tag-features.svg" alt="What It Has" height="72"></h2>

Built from the ground up with **Qt 6.8 Quick** and a native **C++20 Win32 / WinRT service layer** — no heavy Electron runtime, just crisp hardware-accelerated rendering and native Windows hooks.

<table>
<tr>
<td width="50%" valign="top">
<b>Cohesive Pop-Comic Block Language</b><br>
Every pill, toggle, slanted keycap tile, phone modal, and desktop widget shares the same ink outline, inner white ring, left-to-right active-band hover wipe, and hard offset drop shadow that springs cleanly on press.
</td>
<td width="50%" valign="top">
<b>7 Sekai Unit Themes + Live Wallpaper Match</b><br>
Switch instantly between <i>Virtual Singer</i>, <i>Leo/need</i>, <i>MORE MORE JUMP!</i>, <i>Vivid BAD SQUAD</i>, <i>Wonderlands×Showtime</i>, <i>Nightcord at 25:00</i>, and <i>Monochrome</i> — or extract a custom palette directly from your active Windows wallpaper.
</td>
</tr>
<tr>
<td valign="top">
<b>Interactive Multi-Monitor Desktop Widgets</b><br>
Draggable &amp; resizable widgets across multiple displays: <b>Clock</b> (Keys, Tower, Sticker, Stack styles), <b>Weather</b> (Open-Meteo °C/°F), <b>Calendar</b>, <b>Profile Card</b>, <b>To-Do</b>, <b>Notes</b>, Polaroid <b>Photo Frames</b> with Washi Tape, and real-time synced <b>Lyrics</b> (LRCLIB + Windows SMTC).
</td>
<td valign="top">
<b>Smart Top Bar, Capsule Dock &amp; Win10/11 Tray Hook</b><br>
Four styles (<i>Float, Straight, Transparent, Capsule</i>), active window &amp; media pill with seek/controls, live CPU/GPU/RAM telemetry, hybrid Windows 10 &amp; Windows 11 System Tray monitor (`SekaiTrayHook.dll` passive Explorer hook + `NOTIFYICON_VERSION_4`), pinned app launcher, and AppBar workarea reservation.
</td>
</tr>
<tr>
<td valign="top">
<b>True Zero-Overhead Game Mode</b><br>
Auto-detects fullscreen games (or toggle via <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>G</kbd>) with <b>Hibernate</b> mode (releases GPU textures, pauses services, enables Win11 EcoQoS, unhooks keyboard/WinEvent hooks for zero input latency) and <b>Zero-Footprint</b> mode (`--wait-game` ~2 MB pure-Win32 watchdog), plus 1-click RivaTuner (`RTSS`) hook exclusion.
</td>
<td valign="top">
<b>Custom Sekai OSD, GPU Shaders &amp; PowerTools</b><br>
Intercepts volume/brightness/theme keys with a Pop-Comic Sekai OSD, alongside an 11-mode hardware-accelerated `.qsb` WASAPI audio visualizer (<i>Tide, Ribbons, Aurora, Pulse, Scope, Mirror, Ring, Dots, Sekai, Bars, Wave</i>), <kbd>Alt</kbd> + <kbd>Space</kbd> Spotlight (works even over fullscreen games), Clipboard History, and Bookshelf Drop Shelf.
</td>
</tr>
<tr>
<td valign="top">
<b>Built-in Auto Updater (WinHTTP + SHA-256)</b><br>
Checks GitHub Releases silently on startup or on demand from <b>06 · About</b>, surfaces a floating SekaiPop update toast, verifies downloads against <code>SHA256SUMS.txt</code>, and self-updates both Installer (<code>/S</code>) and Portable ZIP builds with automatic relaunch.
</td>
<td valign="top">
<b>Stutter-Free RAM Cleaner (RamNuker Engine)</b><br>
Integrates native NT memory-list primitives from <b>RamNuker</b>: background auto-clean triggers safely at your RAM% threshold using <b>Priority-0 Standby List</b> only (zero game micro-stutter), plus a 1-click <b>CLEAN RAM (DEEP)</b> button in the TopBar telemetry popup &amp; Settings.
</td>
</tr>
</table>

<img src="assets/divider.svg" alt="" width="100%">

<h2 id="requirements"><img src="assets/tag-requirements.svg" alt="Requirements" height="72"></h2>

| Component | Requirement / Notes |
|---|---|
| **Operating System** | **Windows 10 &amp; Windows 11 (64-bit)** |
| **Graphics / Runtime** | Direct3D 11 capable GPU (Qt 6.8 Quick RHI D3D11 backend; Qt runtime DLLs bundled in installer &amp; portable zip) |
| **Permissions** | Runs per-user (no admin UAC required); `SekaiTrayHook.dll` attaches passively to `explorer.exe` and auto-unloads on exit |
| **Build Toolchain** *(source only)* | CMake 3.21+, C11 &amp; C++20 compiler (MinGW-w64 GCC / LLVM-MinGW), Qt 6.8+ (`Quick`, `QuickControls2`, `Svg`, `ShaderEffect`) |

<img src="assets/divider.svg" alt="" width="100%">

<h2 id="installation"><img src="assets/tag-installation.svg" alt="Installation" height="72"></h2>

### Option 1 — Windows Installer (Recommended)

1. Download **`SekaiDesk-Setup.exe`** from the [latest GitHub Release](https://github.com/Yuukitake/SekaiDesk/releases/latest).
2. Run the setup wizard — choose your preferred installation folder (defaults to `%LocalAppData%\Programs\SekaiDesk`, no admin prompt required), optionally enable **Start with Windows**, and leave **"Launch SekaiDesk now"** checked on the final page to start immediately.

### Option 2 — Portable ZIP Build

1. Download **`SekaiDesk-win64.zip`** from the [latest GitHub Release](https://github.com/Yuukitake/SekaiDesk/releases/latest).
2. Extract the archive to any folder (e.g., `D:\Apps\SekaiDesk\`) keeping `SekaiTrayHook.dll` beside `SekaiDesk.exe`, and launch **`SekaiDesk.exe`**.

First launch starts automatically with **Peek Phone** notifications, **Capsule Bottom Dock**, and **Transparent Top Bar**, and writes your settings to `%APPDATA%\SekaiDesk\sekaidesk.json`.

<details>
<summary>CLI flags &amp; emergency taskbar restore</summary>

- `SekaiDesk.exe --restore` — Immediately restores the native Windows 10/11 taskbar and exits.
- `SekaiDesk.exe --instance <tag>` — Launch an isolated instance with its own mutex name for testing.

</details>

### Option 3 — Build from Source

```powershell
git clone https://github.com/Yuukitake/SekaiDesk.git SekaiDesk
cd SekaiDesk
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build -j

# Deploy Qt 6 runtime DLLs & QML modules for standalone execution
New-Item -ItemType Directory -Force installer/stage | Out-Null
Copy-Item build/SekaiDesk.exe, build/SekaiTrayHook.dll installer/stage/
windeployqt --release --qmldir qml installer/stage/SekaiDesk.exe

# Optional: build Windows installer (requires NSIS / makensis)
makensis installer/SekaiDesk.nsi
```

> [!TIP]
> Ensure your Qt 6.8+ (`Core`, `Gui`, `Qml`, `Quick`, `Network`, plus QML runtime modules `Svg`, `QuickControls2`, `ShaderEffect`) bin folder and `windeployqt` are on `PATH`. Also include MinGW runtime DLLs (`libstdc++-6.dll`, `libgcc_s_seh-1.dll`, `libwinpthread-1.dll`) for `SekaiDesk.exe` (`SekaiTrayHook.dll` is pure Win32 C with zero MinGW runtime dependencies).

<img src="assets/divider.svg" alt="" width="100%">

<h2 id="keybinds"><img src="assets/tag-keybinds.svg" alt="Keybinds" height="72"></h2>

| Shortcut | Action |
|---|---|
| <kbd>Alt</kbd> + <kbd>Space</kbd> | Open **Spotlight** launcher, calculator &amp; quick commands (works over fullscreen games) |
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>A</kbd> | Toggle **2.5D Quick Panel** smartphone |
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>V</kbd> | Open **Clipboard History** popup |
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>G</kbd> | Toggle **Game Mode** (instant Hibernate / Zero-Footprint) |
| <kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>T</kbd> | Temporarily **Show / Hide native Windows Taskbar** |
| <kbd>Volume Up</kbd> / <kbd>Down</kbd> / <kbd>Mute</kbd> | Show custom **Sekai Volume OSD** |
| <kbd>Esc</kbd> | Close / back out of active phone, Settings, or tool popup |

<img src="assets/divider.svg" alt="" width="100%">

<h2 id="credits"><img src="assets/tag-credits.svg" alt="Credits" height="72"></h2>

SekaiDesk stands on the shoulders of awesome open-source projects and APIs:

- **[SekaiPop](https://github.com/Blapples/SekaiPop)** — The original Linux / Quickshell desktop shell whose Pop-Comic design system, 2.5D phone metaphors, Edit Desktop workflow, and unit themes inspired and guided this Windows port (distributed upstream under GPL-3.0).
- **[Flow Launcher](https://github.com/Flow-Launcher/Flow.Launcher)** — Reference and UX inspiration for fast Alt+Space Spotlight application search, calculation, and command filtering on Windows.
- **Libraries & Data Services**
  - [Qt 6 Quick](https://www.qt.io/) (D3D11 RHI scene graph & QML UI)
  - Windows Win32 / WinRT APIs (SMTC media control, WASAPI audio capture/peaks, DWM window thumbnails, Shell tray hooks)
  - [Open-Meteo](https://open-meteo.com/) for forecast weather data & [LRCLIB](https://lrclib.net/) for synchronized lyrics

> *Character themes and unit names are fan references to Project SEKAI COLORFUL STAGE! feat. Hatsune Miku. This is an unofficial fan project and is not affiliated with SEGA, Colorful Palette, or Crypton Future Media.*

<img src="assets/divider.svg" alt="" width="100%">
