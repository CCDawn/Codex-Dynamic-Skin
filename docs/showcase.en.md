# Codex 动态壁纸 Showcase

[Project home](../README.en.md) · [中文](./showcase.md)

This gallery collects tested themes and concept directions. The sidebar, cards, project picker, and composer in real screenshots remain native Codex controls. Concept images contain UI and cannot be imported as wallpapers.

## Real injected themes

### Red-white sci-fi

<p align="center">
  <img src="images/screenshot-demo-art.png" alt="Codex 动态壁纸 red-white sci-fi theme" width="900">
</p>

### Windows immersive theme

<p align="center">
  <img src="images/screenshot-windows-hero.png" alt="Codex 动态壁纸 Windows immersive theme" width="900">
</p>

### macOS dark theme

<p align="center">
  <img src="images/screenshot-macos-home.png" alt="Codex 动态壁纸 macOS dark theme" width="900">
</p>

## Tested character preset: Arina Hashimoto

The “Arina Hashimoto / 桥本有菜” preset has been tested on the real Codex home screen in both light and dark appearances. The user-provided source PNG is `1672 × 941`; the preset's `2560 × 1440` JPEG is a standardized derivative that preserves the near-16:9 composition and does not add source detail.

<p align="center">
  <img src="images/presets/romantic-rose-light.jpg" alt="Arina Hashimoto light theme" width="900"><br>
  <sub>Light · real injected screenshot</sub>
</p>

<p align="center">
  <img src="images/presets/romantic-rose-dark.jpg" alt="Arina Hashimoto dark theme" width="900"><br>
  <sub>Dark · real injected screenshot</sub>
</p>

On Windows, switch through **已保存主题 → 桥本有菜** after installation. On macOS:

```bash
cd macos
./scripts/install-dream-skin-macos.sh --no-launch
~/.codex/codex-dream-skin-studio/scripts/switch-theme-macos.sh \
  --id preset-romantic-rose
```

The user source is [`images/presets/romantic-rose-source.png`](./images/presets/romantic-rose-source.png); the macOS preset uses [`../macos/presets/preset-romantic-rose/background.jpg`](../macos/presets/preset-romantic-rose/background.jpg).

> The screenshots above contain real UI and are previews only. The character background is a user-provided AI-generated example, not an official OpenAI/Codex visual or endorsement. Confirm likeness and asset rights before redistribution.

## Eight concept directions

Generate a UI-free `2560 × 1440` asset with the [reference prompt guide](./reference-background-prompt-guide.en.md). See the [concept prompt breakdown](./background-generation-prompts.md) for all eight directions.

| | |
|---|---|
| ![Pink Custom](images/gallery/skin-01.jpg) | ![God of Wealth](images/gallery/skin-02.jpg) |
| Pink Custom | God of Wealth |
| ![Red-White Sci-Fi](images/gallery/skin-03.jpg) | ![Clear Custom](images/gallery/skin-04.jpg) |
| Red-White Sci-Fi | Clear Custom |
| ![Inspiration](images/gallery/skin-05.jpg) | ![Purple Night](images/gallery/skin-06.jpg) |
| Inspiration | Purple Night |
| ![Cyan Virtual Singer](images/gallery/skin-07.jpg) | ![Stage Black-Gold](images/gallery/skin-08.jpg) |
| Cyan Virtual Singer | Stage Black-Gold |

---

[Download Windows EXE](https://github.com/CCDawn/Codex-Dynamic-Skin/releases/latest/download/CodexDreamSkinManager.exe) · [Project home](../README.en.md)
