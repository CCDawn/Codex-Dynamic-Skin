<h1 align="center">Codex 动态壁纸</h1>

<p align="center">
  <strong>给 Codex 桌面端换上主题、静态壁纸和动态壁纸。</strong><br>
  保留原生侧栏、任务、项目选择器与输入框，不修改官方安装包。
</p>

<p align="center">
  <strong>中文</strong> · <a href="./README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/CCDawn/Codex-Dream-Skin-Enhanced?style=flat-square&color=f47f9c"></a>
  <a href="https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/releases"><img alt="累计下载" src="https://img.shields.io/github/downloads/CCDawn/Codex-Dream-Skin-Enhanced/total?style=flat-square&color=ad6fe8"></a>
  <a href="https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/CCDawn/Codex-Dream-Skin-Enhanced/ci.yml?branch=main&style=flat-square&label=CI"></a>
  <a href="./LICENSE"><img alt="MIT License" src="https://img.shields.io/github/license/CCDawn/Codex-Dream-Skin-Enhanced?style=flat-square"></a>
</p>

<p align="center">
  <img src="docs/images/social-preview.png" alt="Codex 动态壁纸" width="100%">
</p>

<p align="center">
  <a href="https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/releases/latest/download/CodexDreamSkinManager.exe"><strong>下载 Windows EXE</strong></a>
  ·
  <a href="#macos-安装">macOS 安装</a>
  ·
  <a href="./docs/showcase.md">查看效果展厅</a>
  ·
  <a href="https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/discussions">加入讨论</a>
  ·
  <a href="https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/issues">反馈问题</a>
</p>

> 非 OpenAI 官方产品。Codex 动态壁纸通过仅绑定 `127.0.0.1` 的本机 CDP 注入主题，不修改 WindowsApps、`.app`、`app.asar` 或官方代码签名。

## 为什么用它

- **原生 UI 保持可用**：不是把一张假界面贴满窗口；侧栏、聊天、任务和输入框仍可正常交互。
- **Codex 内部动态壁纸**：Windows 支持本地 MP4/WebM 静音循环，不是修改桌面壁纸。
- **一键式 Windows 管理器**：浏览、搜索、预览和切换壁纸，调整透出度，暂停或恢复官方外观。
- **图片变主题**：导入喜欢的 PNG、JPEG 或 WebP，自动适配全窗背景与内容可读性。
- **可恢复、可审计**：不改官方二进制；随时停止注入并恢复 Codex 官方外观。
- **Windows + macOS**：Windows 提供自包含 EXE，macOS 提供菜单栏 Studio 与安装脚本。

## Windows：30 秒开始

1. 下载 [`CodexDreamSkinManager.exe`](https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/releases/latest/download/CodexDreamSkinManager.exe)。
2. 双击运行，点击「添加壁纸」导入 PNG、JPEG、WebP、MP4 或 WebM。
3. 点击「应用到 Codex」。需要时点击「启动 / 重新应用」。

管理器是自包含的单文件程序，内置经过测试的动态壁纸引擎与 Node.js 运行时；最终用户不需要安装 .NET SDK、Node.js 或手动执行 PowerShell。

> 当前发布版尚未进行代码签名，Windows 可能显示“未知发布者”。请只从本仓库的 [Releases](https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/releases) 下载，并使用同页 `.sha256` 文件核对。

### 壁纸透出

右侧滑杆控制主题蒙层与壁纸的关系：

- `100%`：显示原始壁纸/视频画面，整页主题蒙层降为零。
- 较低数值：提高文字区与主题蒙层可见度，适合任务页或高对比背景。

## macOS 安装

在仓库的 [`macos/`](./macos/) 目录双击：

```text
Install Codex Dream Skin.command
```

也可在终端执行：

```bash
cd macos
./scripts/install-dream-skin-macos.sh
```

安装后通过菜单栏 Studio 导入、保存和切换图片主题。完整说明见 [`macos/README.md`](./macos/README.md)。

## 功能对照

| 功能 | Windows | macOS |
|---|:---:|:---:|
| PNG / JPEG / WebP 图片主题 | ✅ | ✅ |
| MP4 / WebM 动态壁纸 | ✅ | — |
| 图形化主题管理 | ✅ 独立 EXE | ✅ 菜单栏 Studio |
| 壁纸库搜索与预览 | ✅ | ✅ |
| 保存与切换主题 | ✅ | ✅ |
| 壁纸透出度 | ✅ | — |
| 暂停注入 / 恢复官方外观 | ✅ | ✅ |
| 修改官方应用文件 | **不会** | **不会** |

## 真实效果

| Windows / 通用主题 | macOS 暗色主题 |
|---|---|
| ![Codex 动态壁纸红白科幻主题](docs/images/screenshot-demo-art.png) | ![Codex 动态壁纸 macOS 暗色主题](docs/images/screenshot-macos-home.png) |

更多实机截图、人物预设与八种概念方向见 [`docs/showcase.md`](./docs/showcase.md)。

## 工作原理

```text
本地壁纸 / 主题配置
          ↓
Codex 动态壁纸本地主题仓库
          ↓
127.0.0.1 回环 CDP
          ↓
Codex renderer 中的独立背景层
          ↓
原生侧栏、任务与输入框继续交互
```

Windows 视频会分块传入 renderer 并组装为 Blob URL；切换、暂停或清理时会释放播放器与 Blob。页面隐藏后自动暂停视频，避免无意义播放。

## 安全边界

- CDP 只绑定 `127.0.0.1`，不会对局域网开放调试端口。
- 不修改 WindowsApps、`.app`、`app.asar` 或官方签名。
- 不读取或改写 API Key、Base URL、模型供应商或 Codex 聊天内容。
- 主题运行期间不要运行来路不明的本机程序；本机恶意进程可能尝试访问调试端口。
- Codex 官方更新可能改变 DOM。若主题失效，请先使用管理器「启动 / 重新应用」，再查看 [Issues](https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/issues)。

## 从源码运行与构建

### Windows 脚本入口

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\windows\scripts\install-dream-skin.ps1
powershell.exe -ExecutionPolicy Bypass -File .\windows\scripts\start-dream-skin.ps1
```

### 构建单文件 EXE

需要 .NET 8 SDK 和 Node.js 22+：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\app\build-manager.ps1
```

输出位于 `windows/dist/`。构建会运行 Windows 回归测试、发布自包含 `win-x64` EXE，并执行发布后自检。

### 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\tests\run-tests.ps1
```

```bash
bash macos/tests/run-tests.sh
```

## 常见问题

<details>
<summary><strong>这是 Wallpaper Engine 的替代品吗？</strong></summary>

不是。它只控制 Codex 应用内部的主题背景。Windows 管理器可以扫描并直接引用 Wallpaper Engine 已下载到本地的 `type: video` MP4/WebM 项目；超过 1080p 时会生成本地流畅代理。`type: scene` 的 `scene.pkg` 目前可通过独立 GPL-3.0 侧车进行开发预览；Web 壁纸和项目脚本仍不会执行。
</details>

<details>
<summary><strong>为什么 Codex 更新后主题可能失效？</strong></summary>

动态壁纸引擎依赖 Codex 的 renderer DOM 和本机 CDP。官方更新可能调整结构；通常点击「启动 / 重新应用」即可恢复，兼容性修复会持续发布在本仓库。
</details>

<details>
<summary><strong>能否恢复完全原生的 Codex？</strong></summary>

可以。Windows 管理器提供「恢复官方外观」，macOS Studio 也提供卸载/恢复入口。项目不会修改官方应用包。
</details>

<details>
<summary><strong>壁纸文件会上传吗？</strong></summary>

不会。壁纸与主题保存在本机，注入只通过本机回环连接完成。
</details>

## 文档

- [Windows 使用说明](./windows/README.md)
- [macOS 使用说明](./macos/README.md)
- [平台与路径对照](./docs/platforms.md)
- [效果展厅](./docs/showcase.md)
- [参考生图提示词](./docs/reference-background-prompt-guide.md)
- [概念图提示词](./docs/background-generation-prompts.md)
- [项目记录](./docs/PROJECT.md)

## 赞助商

<p align="center">
  <a href="https://passion8.cc/register?aff=TuPe">
    <img src="docs/images/sponsor-passion8.png" alt="Passion8" height="64">
  </a>
</p>

感谢 [passion8.cc](https://passion8.cc/register?aff=TuPe) 赞助本项目。换肤与 API 配置互相独立，本项目不会自动改写模型供应商设置。

## 反馈与贡献

- 公告、主题分享与使用交流：[GitHub Discussions](https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/discussions)。
- 首个版本公告：[Codex 动态壁纸 v1.0.0 正式发布](https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/discussions/5)。
- 使用 [Bug / 功能 Issue 模板](./.github/ISSUE_TEMPLATE/) 提交问题。
- PR 请说明平台、复现或目标、验证命令与恢复测试。
- 贡献指南：[中文](./.github/CONTRIBUTING.md) · [English](./.github/CONTRIBUTING.en.md)

本仓库是 [Fei-Away/Codex-Dream-Skin](https://github.com/Fei-Away/Codex-Dream-Skin) 的增强派生版本，并保留完整上游历史。

## 许可与声明

[MIT License](./LICENSE)。非 OpenAI 官方产品；Codex 及相关商标归其权利人。随仓库预设与效果图中的人物/IP 素材仅作主题示意，公开再分发前请自行确认肖像、素材和商标权利。

---

如果 Codex 动态壁纸让你的工作空间更舒适，欢迎点一个 **Star**，也欢迎分享你的主题截图。
