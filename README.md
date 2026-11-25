# Playerr

Playerr is a vinyl-inspired, always-on-top music player for Windows. It turns the current track’s artwork into a spinning record and uses a color from the cover to light the player.

I built it to make listening while working feel more personal and convenient. Once music is playing, the controls stay within reach so you can pause, skip, or seek without switching back to Spotify, YouTube, or another media player.

## Demo

[Watch the live OBS demo](https://chatgpt.com/library?file_id=libfile_10e98bad7ed4819197702790f023d193&account_id=personal)

A live OBS walkthrough showing Spotify Web Player in both layouts, with narration and optional English captions.

## Features

- **Album art and ambient lighting.** The record spins while the track plays. The artwork and lighting update together when the track changes.
- **Full player and disc mode.** Double-click the player to switch layouts. The disc stays in place, with a thin color-matched glow in disc mode.
- **Playback controls.** Play, pause, skip forward or back, and seek when the media source supports it. Spotify has separate Repeat and Repeat One buttons.
- **Size, position, and opacity.** Drag the player to move it. Use the corner grip or Ctrl + mouse wheel to resize. Adjust opacity or reset the layout from the menu.
- **Click-through.** The player starts locked so you can click the window underneath. Click the padlock or press Ctrl + Alt + L to use the controls.

## Run locally

You’ll need Windows, Git, and Node.js with npm.

```powershell
git clone https://github.com/avish006/Playerr.git
cd Playerr
npm.cmd ci
npm.cmd start
```

Start playback in Spotify or another supported media source. In VS Code, you can also open the project folder and press **F5** to launch the included **Run Vinyl Float** configuration. Use the system tray icon to quit the app.

## How it was built

- **Electron and Node.js** handle the transparent desktop window, system tray, and keyboard shortcut. A separate small window keeps the padlock clickable when the player is locked.
- **HTML, CSS, and JavaScript** render the rotating disc and playback controls. The renderer samples album art to find a dominant color for the glow.
- **Windows PowerShell, WinRT, and System Media Transport Controls** read the active media session and relay playback commands. Spotify repeat uses the native media session where available and falls back to Windows UI Automation.

## Media support

Playerr was designed for Spotify Web Player and the Spotify Windows app. YouTube and other players can also provide track information and basic controls when they expose a Windows media session. Available controls depend on the source.

For Repeat and Repeat One in Spotify Web Player, keep Spotify selected in a browser window that isn’t minimized. It can sit behind your other apps. The repeat fallback uses Spotify’s English accessibility labels.

Playerr runs as a standalone desktop app with no browser extension or local server.
