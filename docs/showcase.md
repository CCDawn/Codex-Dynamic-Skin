# Codex 动态壁纸效果展厅

[返回项目首页](../README.md) · [English](./showcase.en.md)

这里收录经过实机验证的主题与概念视觉方向。截图中的侧栏、卡片、项目选择器和输入框均为 Codex 原生控件；概念图包含 UI，不能直接作为背景导入。

## 真实注入效果

### 红白科幻

<p align="center">
  <img src="images/screenshot-demo-art.png" alt="Codex 动态壁纸红白科幻效果" width="900">
</p>

### Windows 沉浸式主题

<p align="center">
  <img src="images/screenshot-windows-hero.png" alt="Codex 动态壁纸 Windows 沉浸式主题" width="900">
</p>

### macOS 暗色主题

<p align="center">
  <img src="images/screenshot-macos-home.png" alt="Codex 动态壁纸 macOS 暗色主题" width="900">
</p>

## 实测人物预设：桥本有菜

「桥本有菜 / Arina Hashimoto」已在真实 Codex 首页分别验证浅色和暗色外观。用户提供的源 PNG 为 `1672 × 941`，主题包在保持近 16:9 构图的前提下派生导出 `2560 × 1440` JPEG，并不代表增加了源图细节。

<p align="center">
  <img src="images/presets/romantic-rose-light.jpg" alt="桥本有菜主题浅色实机效果" width="900"><br>
  <sub>浅色 · 真实注入截图</sub>
</p>

<p align="center">
  <img src="images/presets/romantic-rose-dark.jpg" alt="桥本有菜主题暗色实机效果" width="900"><br>
  <sub>暗色 · 真实注入截图</sub>
</p>

Windows 安装后可从「已保存主题 → 桥本有菜」切换。macOS 可执行：

```bash
cd macos
./scripts/install-dream-skin-macos.sh --no-launch
~/.codex/codex-dream-skin-studio/scripts/switch-theme-macos.sh \
  --id preset-romantic-rose
```

可下载的用户源图是 [`images/presets/romantic-rose-source.png`](./images/presets/romantic-rose-source.png)；macOS 预设使用 [`../macos/presets/preset-romantic-rose/background.jpg`](../macos/presets/preset-romantic-rose/background.jpg)。

> 上面的效果图包含真实 UI，只能用于预览，不能当作背景导入。人物背景为用户提供的 AI 生成示例，不代表 OpenAI/Codex 官方视觉或背书；公开再分发前请自行确认肖像与素材权利。

## 八种概念方向

使用[参考生图提示词](./reference-background-prompt-guide.md)生成无 UI 的 `2560 × 1440` 素材；完整提示词拆解见[概念图提示词](./background-generation-prompts.md)。

| | |
|---|---|
| ![粉系定制](images/gallery/skin-01.jpg) | ![财神打工](images/gallery/skin-02.jpg) |
| 粉系定制 | 财神打工 |
| ![红白科幻](images/gallery/skin-03.jpg) | ![清透定制](images/gallery/skin-04.jpg) |
| 红白科幻 | 清透定制 |
| ![灵感小宇宙](images/gallery/skin-05.jpg) | ![紫夜限定](images/gallery/skin-06.jpg) |
| 灵感小宇宙 | 紫夜限定 |
| ![青蓝虚拟歌姬](images/gallery/skin-07.jpg) | ![舞台黑金](images/gallery/skin-08.jpg) |
| 青蓝虚拟歌姬 | 舞台黑金 |

---

[下载 Windows EXE](https://github.com/CCDawn/Codex-Dynamic-Skin/releases/latest/download/CodexDreamSkinManager.exe) · [返回项目首页](../README.md)
