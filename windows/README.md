# Codex 动态壁纸

<p align="center">
  <strong>中文</strong> · <a href="./README.en.md">English</a>
</p>

Codex 动态壁纸通过本机回环 CDP 给官方 Codex Windows 桌面应用加载外部主题。它保留原生侧栏、项目选择、任务内容和输入框，不修改 WindowsApps、`app.asar` 或应用签名。

## 普通用户：下载 EXE

1. 下载 [`CodexDreamSkinManager.exe`](https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/releases/latest/download/CodexDreamSkinManager.exe)。
2. 双击运行，点击「添加壁纸」导入图片或视频。
3. 选择壁纸并点击「应用到 Codex」；需要时点击「启动 / 重新应用」。

发布版是自包含的单文件程序，内置经过验证的动态壁纸引擎和 Node.js 运行时。普通用户不需要安装 Node.js、.NET SDK，也不需要手动运行 PowerShell。程序不需要管理员权限。

> 当前发布版尚未进行代码签名，Windows 可能显示“未知发布者”。请只从本仓库 Releases 下载，并核对同页 SHA256。

## 管理器功能

管理器支持：

- 浏览、搜索并预览桌面壁纸库中的 PNG、JPEG、WebP、MP4 和 WebM。
- 扫描 Wallpaper Engine 本地 Workshop 中的视频和 `scene.pkg` 场景；Scene 通过独立 GPL-3.0 本地渲染侧车输出回环 fMP4 流，Web 壁纸暂不支持。
- 一键启动或重新应用动态壁纸、切换壁纸、暂停/恢复以及还原官方外观。
- 调整「壁纸透出」程度，100% 时视频保持原始画面且整页主题蒙层为零。
- 系统托盘控制和可选的当前用户开机启动。

## 开发者：构建与脚本安装

开发者可使用下列命令构建单文件版本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\app\build-manager.ps1
```

构建脚本会运行 Windows 回归测试、嵌入本机可信的 Node.js 22+ 运行时、发布自包含
`win-x64` EXE，并执行发布后自检。输出位于 `windows/dist`。

### 源码与脚本运行要求

- 从 Microsoft Store 安装且已注册到当前用户的官方 `OpenAI.Codex` 应用。
- Node.js 22 或更高版本，`node.exe` 可从 `PATH` 找到。
- Windows PowerShell 5.1 或更高版本。

这些依赖只适用于源码脚本和本地构建，不适用于上面的发布版 EXE。安装脚本需要在 Codex 完全退出后运行。

### 从源码安装

在 PowerShell 中进入仓库的 `windows` 目录，然后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-dream-skin.ps1
```

安装器会校验官方 Codex Store 包和 Node.js，保存可恢复的外观配置，并初始化本地主题仓库。默认还会创建这些快捷方式：

- `Codex 动态壁纸`：启动或重新应用壁纸。
- `Codex 动态壁纸 - 托盘控制`：打开系统托盘控制。
- `Codex 动态壁纸 - 恢复官方外观`：恢复官方外观并关闭已保存的 CDP 会话。

如需使用自定义端口，可以在安装时传入 `-Port`。端口范围必须是 `1024` 到 `65535`。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-dream-skin.ps1 -Port 9444
```

## 启动与验证

推荐从 `Codex 动态壁纸` 快捷方式启动。它发现 Codex 已经运行时会先询问是否重启。

命令行启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-dream-skin.ps1 -PromptRestart
```

启动后运行验证脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-dream-skin.ps1 `
  -ScreenshotPath "$env:TEMP\codex-dream-skin.png"
```

验证脚本会自动确认：

- CDP 端点只绑定本机回环地址，并且属于当前官方 Codex 包。
- 当前渲染页已经加载预期版本的皮肤。
- 原生侧栏和输入框仍然存在。
- 皮肤装饰层不会拦截鼠标事件。
- 当前为首页时，首页主题结构已经正确加载。

随后用生成的截图检查横向溢出和文字对比度，再分别在首页与普通任务页手动检查项目菜单和输入框交互。完整视觉检查项见 [`references/qa-inventory.md`](./references/qa-inventory.md)。

## 更换和保存主题

打开 `Codex 动态壁纸 - 托盘控制` 后可以：

- 更换 PNG、JPEG、WebP 背景图，或 MP4、WebM 动态壁纸。
- 使用「壁纸透出」滑杆调整覆盖在壁纸上的主题面板：100% 时视频保持原始画面，整页主题蒙层为零；设置会随主题持久化。
- 保存当前主题并从「已保存主题」切换。
- 暂停或继续显示皮肤。
- 重新应用主题，或完整恢复 Codex。

导入图片必须是纯背景，不要使用包含窗口、侧栏、输入框、文字或按钮的效果截图。图片上限为 16 MB；宽或高不能超过 16384 像素，总像素不能超过 5000 万。

动态壁纸始终静音、循环且不拦截鼠标操作；Codex 页面隐藏时会自动暂停。视频上限为 128 MB，并通过有界 CDP 分块传入当前 renderer，不会上传到网络，也不会把整段视频嵌入启动脚本。Wallpaper Engine 的超 1080p 视频在首次应用时会生成本地 1080p 流畅代理，缓存位于 `%LOCALAPPDATA%\CodexDreamSkin\media-cache`；原 Workshop 文件不会被修改，仍会在每次刷新时校验。当前 MVP 不提供声音、播放列表或 Live2D。

Scene 支持目前是开发预览：`SceneViewer.exe` 必须作为独立组件放在 `%LOCALAPPDATA%\CodexDreamSkin\scene-runtime`，并随附 GPL-3.0 许可证与对应源码信息。主程序只通过标准输入和带随机令牌的 `127.0.0.1` HTTP 接口与其通信；不会把 GPL 二进制嵌入 MIT 管理器。发布前仍需完成独立侧车包、源码提供说明和更多场景兼容性验证。

## 恢复与卸载快捷方式

恢复官方外观；如果 Codex 正在运行，确认后关闭并重新打开：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-dream-skin.ps1 `
  -RestoreBaseTheme -PromptRestart
```

如需同时删除动态壁纸工具创建的快捷方式，再增加 `-Uninstall`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-dream-skin.ps1 `
  -RestoreBaseTheme -PromptRestart -Uninstall
```

`-RecoverConfigBackup` 用于明确恢复安装前的完整 `config.toml` 备份。它会先保存当前配置，只应在配置损坏且普通的 `-RestoreBaseTheme` 无法解决时使用。

## 文件与日志位置

| 用途 | 路径 |
|------|------|
| 动态壁纸状态根目录 | `%LOCALAPPDATA%\CodexDreamSkin` |
| 当前主题 | `%LOCALAPPDATA%\CodexDreamSkin\active-theme` |
| 已保存主题 | `%LOCALAPPDATA%\CodexDreamSkin\themes` |
| 导入图片归档 | `%LOCALAPPDATA%\CodexDreamSkin\images` |
| 会话状态 | `%LOCALAPPDATA%\CodexDreamSkin\state.json` |
| 注入器日志 | `%LOCALAPPDATA%\CodexDreamSkin\injector.log` |
| 注入器错误日志 | `%LOCALAPPDATA%\CodexDreamSkin\injector-error.log` |
| 验证日志 | `%LOCALAPPDATA%\CodexDreamSkin\verify.log` |
| Codex 配置 | `%USERPROFILE%\.codex\config.toml` |

更完整的平台路径说明见 [`../docs/platforms.md`](../docs/platforms.md)。

## 常见问题

### 找不到 Node.js

运行 `node --version`，确认版本为 22 或更高，并重新打开 PowerShell 让新的 `PATH` 生效。

### 找不到官方 Codex 包

运行：

```powershell
Get-AppxPackage -Name OpenAI.Codex
```

脚本只接受已注册的官方 Store 包，不会从任意可执行文件路径启动 Codex。

### 安装器要求关闭 Codex

关闭所有 Codex 窗口后再运行安装器。安装期间必须保持配置和应用状态稳定。

### 端口被占用

没有显式指定 `-Port` 时，启动脚本会从默认端口 `9335` 开始寻找空闲端口。显式端口被其他进程占用时，改用另一个端口，不要关闭身份不明的监听进程。

### 验证找不到 CDP 端点

通过 `Codex 动态壁纸` 快捷方式启动 Codex，再运行验证脚本。普通 Codex 启动方式不会打开动态壁纸所需的调试会话。

### Codex 更新后皮肤失效

重新运行安装器和启动快捷方式。脚本会重新发现当前注册的 Store 包，不依赖旧版本的可执行文件路径。

提交问题时请从仓库的 [Issue 提交页](https://github.com/CCDawn/Codex-Dream-Skin-Enhanced/issues/new/choose) 选择 Bug 模板，附上系统版本、Codex 来源、复现步骤和相关日志片段。请删除密钥、`auth.json`、中转 token 和私人对话内容。

## 安全边界

- CDP 只绑定 `127.0.0.1`。皮肤运行期间不要运行来路不明的本机程序。
- 不修改官方 Codex 安装目录、WindowsApps、`app.asar` 或签名。
- 不写入 API Key、Base URL 或模型供应商配置。
- 恢复脚本只会控制经过包身份、进程路径和会话状态校验的 Codex 进程。

维护者和代理使用的实现约束见 [`SKILL.md`](./SKILL.md)，运行时排错细节见 [`references/runtime-notes.md`](./references/runtime-notes.md)。
