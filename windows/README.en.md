# Codex 动态壁纸

<p align="center">
  <a href="./README.md">中文</a> · <strong>English</strong>
</p>

Codex 动态壁纸 loads an external theme into the official Codex Windows desktop app through loopback CDP. The native sidebar, project picker, task content, and composer remain interactive. The tool does not modify WindowsApps, `app.asar`, or the app signature.

## For users: download the EXE

1. Download [`CodexDreamSkinManager.exe`](https://github.com/CCDawn/Codex-Dynamic-Skin/releases/latest/download/CodexDreamSkinManager.exe).
2. Run it and choose **添加壁纸** to import an image or video.
3. Select a wallpaper and choose **应用到 Codex**. Use **启动 / 重新应用** when needed.

The release is a self-contained, single-file app with the tested wallpaper engine and Node.js runtime embedded. End users do not need Node.js, the .NET SDK, manual PowerShell commands, or administrator access.

> The current release is unsigned, so Windows may show an “Unknown publisher” warning. Download only from this repository’s Releases page and verify the published SHA256.

## Manager features

The manager browses and previews PNG, JPEG, WebP, MP4, and WebM libraries; starts, reapplies, pauses,
restores, and switches wallpapers; controls wallpaper reveal; exposes tray actions; and offers optional
per-user startup.

## For developers: build and script install

Build it with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\build-manager.ps1
```

The build runs the Windows regression suite, embeds a trusted local Node.js 22+ runtime, publishes a
self-contained `win-x64` executable, and runs a post-publish self-test. Output is written to
`windows/dist`.

### Source and script requirements

- The official `OpenAI.Codex` app installed from Microsoft Store and registered for the current user.
- Node.js 22 or newer, with `node.exe` available on `PATH`.
- Windows PowerShell 5.1 or newer.

These dependencies apply only to source scripts and local builds, not to the release EXE above. Run the installer after Codex has fully exited.

### Install from source

Open PowerShell in the repository's `windows` directory and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-dream-skin.ps1
```

The installer validates the official Codex Store package and Node.js, saves a recoverable appearance baseline, and initializes the local theme store. By default it also creates these shortcuts:

- `Codex 动态壁纸`: launch or reapply the wallpaper.
- `Codex 动态壁纸 - 托盘控制`: open the system tray controls.
- `Codex 动态壁纸 - 恢复官方外观`: restore the stock appearance and close the saved CDP session.

Pass `-Port` during installation to use a fixed custom port. Valid ports range from `1024` through `65535`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-dream-skin.ps1 -Port 9444
```

## Launch and verify

The `Codex 动态壁纸` shortcut is the recommended launcher. It asks for confirmation before restarting an open Codex window.

Command-line launch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-dream-skin.ps1 -PromptRestart
```

Run verification after launch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-dream-skin.ps1 `
  -ScreenshotPath "$env:TEMP\codex-dream-skin.png"
```

The verification script confirms:

- The CDP endpoint is bound to loopback and belongs to the current official Codex package.
- The current renderer has loaded the expected skin version.
- The native sidebar and composer remain present.
- The decorative skin layer does not intercept pointer events.
- When the current route is home, the themed home structure has loaded.

Next, use the generated screenshot to check horizontal overflow and text contrast. On both the home and normal task routes, manually check the project menu and composer interaction. See [`references/qa-inventory.md`](./references/qa-inventory.md) for the complete visual checklist.

## Change and save themes

Open `Codex 动态壁纸 - 托盘控制` to:

- Import a PNG, JPEG, or WebP background, or an MP4/WebM animated wallpaper.
- Adjust wallpaper reveal: at 100% the video stays at its original opacity while the full-window theme veil reaches zero; the value persists with the theme.
- Save the active theme and switch through saved themes.
- Pause or resume the skin.
- Reapply the theme or fully restore Codex.

Import a UI-free wallpaper rather than a preview containing a window, sidebar, composer, text, or buttons. Images may be at most 16 MB, 16384 pixels on either side, and 50 million total pixels.

Animated wallpapers are always muted, looped, pointer-transparent, and paused while the Codex page is hidden. Videos may be at most 128 MB and are transferred to the current renderer in bounded CDP chunks; they are not uploaded or embedded wholesale in the bootstrap script. Audio, playlists, and Live2D are outside this MVP.

## Restore and remove shortcuts

Restore the stock appearance. If Codex is running, confirm its closure and relaunch:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-dream-skin.ps1 `
  -RestoreBaseTheme -PromptRestart
```

Add `-Uninstall` to also remove the shortcuts created by the wallpaper tool:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-dream-skin.ps1 `
  -RestoreBaseTheme -PromptRestart -Uninstall
```

`-RecoverConfigBackup` restores the complete pre-install `config.toml` backup and saves the current configuration first. Reserve it for a damaged configuration that normal `-RestoreBaseTheme` recovery cannot resolve.

## Files and logs

| Purpose | Path |
|---------|------|
| Wallpaper state root | `%LOCALAPPDATA%\CodexDreamSkin` |
| Active theme | `%LOCALAPPDATA%\CodexDreamSkin\active-theme` |
| Saved themes | `%LOCALAPPDATA%\CodexDreamSkin\themes` |
| Imported image archive | `%LOCALAPPDATA%\CodexDreamSkin\images` |
| Session state | `%LOCALAPPDATA%\CodexDreamSkin\state.json` |
| Injector log | `%LOCALAPPDATA%\CodexDreamSkin\injector.log` |
| Injector error log | `%LOCALAPPDATA%\CodexDreamSkin\injector-error.log` |
| Verification log | `%LOCALAPPDATA%\CodexDreamSkin\verify.log` |
| Codex configuration | `%USERPROFILE%\.codex\config.toml` |

See [`../docs/platforms.md`](../docs/platforms.md) for the complete platform path reference.

## Troubleshooting

### Node.js is missing

Run `node --version`, confirm that it reports version 22 or newer, and reopen PowerShell so an updated `PATH` takes effect.

### The official Codex package is missing

Run:

```powershell
Get-AppxPackage -Name OpenAI.Codex
```

The scripts accept only a registered official Store package. They do not launch Codex from an arbitrary executable path.

### The installer asks you to close Codex

Close every Codex window and run the installer again. Installation requires stable app and configuration state.

### The port is occupied

When `-Port` is omitted, the launcher searches for a free port beginning at `9335`. If another process owns an explicitly requested port, choose a different port rather than stopping an unknown listener.

### Verification cannot find a CDP endpoint

Launch Codex through the `Codex 动态壁纸` shortcut, then run verification. A normal Codex launch does not open the debug session used by the wallpaper engine.

### The skin stops working after a Codex update

Run the installer and launch shortcut again. The scripts rediscover the currently registered Store package instead of trusting an executable path from an older app version.

Open the repository's [new issue page](https://github.com/CCDawn/Codex-Dynamic-Skin/issues/new/choose) and choose the bug form when reporting a problem. Include the Windows version, Codex source, reproduction steps, and relevant log lines. Remove secrets, `auth.json`, relay tokens, and private conversation content.

## Security boundaries

- CDP binds only to `127.0.0.1`. Avoid untrusted local software while the skin is active.
- The tool does not modify the official Codex installation, WindowsApps, `app.asar`, or signatures.
- It does not write API keys, Base URLs, or model provider settings.
- Restore controls only Codex processes that pass package identity, executable path, and recorded session checks.

Maintainer and agent constraints live in [`SKILL.md`](./SKILL.md). See [`references/runtime-notes.md`](./references/runtime-notes.md) for deeper runtime troubleshooting.
