# 兼容档案维护手册（compat profile runbook）

面向维护者的操作手册。背景与设计动机见 `docs/compat-profile-design.md`；本文以已落地的实现为准（分发端点是 GitHub RAW，不是设计稿里的 api.dreamskin.cc）。

机制一句话：双端 injector 启动时异步拉取 GitHub RAW 上的 ed25519 签名档案，经过七步 fail-closed 校验后，仅覆盖内置选择器合同中已存在 key 的选择器字符串；任何一步失败就整份丢弃、回落 `assets/selectors.json` 内置合同，永不阻塞换肤。

- 共享客户端：`tools/compat-profile-client.mjs`（由 `tools/sync-runtime-assets.mjs` 原样同步到 `macos/assets/` 与 `windows/assets/`，双端只有这一份实现）
- 分发端点：`https://raw.githubusercontent.com/CCDawn/Codex-Dynamic-Skin/main/compat/profile.json`
- 签发工具：`tools/build-compat-profile.mjs`（从 `tools/selectors.json` 导出并签名）

## 首次启用

1. 生成密钥对：

   ```
   node tools/generate-compat-keypair.mjs
   ```

   默认输出到 `.local-evidence/keys/`（已在 .gitignore；目录不存在时必须显式 `--out <dir>`，且拒绝覆盖已有密钥）。产出：
   - `compat-profile-private.pem` — PKCS8 PEM 私钥。**永不提交、永不打印、不进任何日志**。私钥丢失或泄露 = 档案链作废，必须轮换公钥并发版。
   - `compat-profile-public.txt` — SPKI DER base64 公钥 + sha256 指纹（可提交的内容只有这个 base64 字符串）。

2. 把公钥 base64 填进 `tools/compat-profile-client.mjs` 的 `COMPAT_PROFILE_PUBLIC_KEYS` 数组（替换占位值），然后 `node tools/sync-runtime-assets.mjs` 重新生成双端副本，跑双端测试。

3. 签发档案：

   ```
   node tools/build-compat-profile.mjs --key .local-evidence/keys/compat-profile-private.pem --revision 1
   ```

   默认 `--min-client 1.7.2`、`--expires-days 180`、输出 `compat/profile.json`（可调参数见 `--help`）。工具在写盘前会用派生公钥自校验签名。

4. 提交 `compat/profile.json` 并 push。GitHub RAW 对新 commit 分钟级生效（CDN 缓存最长约 5 分钟）。

## 日常发新档案（选择器漂移时）

1. 修改 `tools/selectors.json`。注意 provenance 规则：**同一 commit 必须更新 `verifiedAgainst`**（date 与 codexVersions，最新在前，evidence 以 maintainer / reporter / fixture 开头），CI 会强制拦截。
2. `--revision` 递增（必须大于线上值，客户端只接受比缓存更新的 revision）后重签：

   ```
   node tools/build-compat-profile.mjs --key <私钥> --revision <n+1>
   ```

3. 提交 `compat/profile.json` 并 push。

`selectors[]` 由 `tools/selectors.json` 原样深拷贝（含 notes 等全部字段），`tools/selectors.json` 仍是唯一可编辑源。

## 公钥轮换

1. `node tools/generate-compat-keypair.mjs --out <新目录>`（工具拒绝覆盖旧密钥，先移走或换目录）。
2. 向 `COMPAT_PROFILE_PUBLIC_KEYS` 数组**追加**新公钥，旧公钥**保留**——数组内任一公钥验签通过即接受，已签发的旧档案继续有效。
3. `sync` + 正常发版，让携带双公钥的客户端铺开。
4. 确认旧档案不再被引用后，下一个版本再从数组移除旧公钥。

## 故障排查

- 一键关闭：环境变量 `DREAMSKIN_COMPAT_PROFILE=0`，injector 完全不发请求（双端一致）。
- 日志走 stderr（stdout 是 JSON 通道）：失败单行 `[dream-skin] compat profile not applied: <原因码>`；成功单行 `[dream-skin] compat profile revision <n> active (<k> selector overrides)`。
- 本地缓存（只存已通过校验的档案，仅作 revision 基线；拉取失败从不回放缓存）：
  - Windows：`%LOCALAPPDATA%\CodexDreamSkin\compat-profile.json`
  - macOS：`~/Library/Application Support/CodexDreamSkin/compat-profile.json`

  删除缓存文件可让客户端重新接受当前线上 revision。

原因码表（七步校验链按序短路，任何一步不过即整份丢弃）：

| 阶段 | 原因码 | 含义 |
| --- | --- | --- |
| 1 固定源 | `origin`、`bad-url` | URL 或 origin 与固定端点不符（含内嵌凭据、异常端口） |
| 1 固定源 | `redirect` | 固定端点不该重定向；一切 3xx 都拒绝，跨源重定向在构造上不可能 |
| 2 有界读取 | `too-large` | 响应体超过 64 KiB 上限，读到位即断开 |
| 2 有界读取 | `content-type` | 既非 json 也非 text/*（RAW 实际回 text/plain，故放宽） |
| 传输 | `http-<状态码>`、`timeout`、`dns`、`connection-refused`、`network` | 非 200 / 超时（5 秒）/ 域名解析失败 / 拒连 / 其他网络错误 |
| 解析 | `json` | 响应体不是合法 JSON |
| 3 结构 | `shape`、`schema`、`revision-shape`、`issuedAt-shape`、`expiresAt-shape`、`minClient-shape`、`signature-shape`、`selectors-shape`、`selector-shape`、`selector-key`、`selector-value`、`css-unsupported` | 字段类型/格式不合法；`css` 字段本迭代不支持，出现即整份拒绝 |
| 4 单调性 | `revision-not-newer` | revision 不大于本地缓存基线 |
| 5 签名 | `signature` | 任一受信公钥都验签失败 |
| 6 时效 | `expired`、`client-too-old`、`client-version` | 档案过期 / 客户端低于 minClient / 客户端自身版本号不合法 |
| 7 键交集 | `unknown-key`、`local-contract`、`overrides` | 档案含内置合同没有的 key / 本地合同为空 / 合并失败 |

## 档案字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `schema` | string | 固定 `dreamskin-compat-profile/1` |
| `revision` | int | 正整数、单调递增；客户端只接受大于缓存值的 revision |
| `issuedAt` | ISO 8601 | 签发时间（`--issued-at` 可固定，用于可复现输出） |
| `expiresAt` | ISO 8601 | 过期即整份作废，回落内置合同（默认签发后 180 天） |
| `minClient` | semver | 低于此版本的客户端忽略本档案（`client-too-old`） |
| `selectors` | array | `tools/selectors.json` selectors[] 的原样拷贝；客户端只投影 key/selector，key 必须在内置合同中已存在，重复 key 拒绝 |
| `signature` | string | `ed25519:` + base64；对除 signature 外全部顶层字段的规范化 JSON（键名逐层字典序、无空白）UTF-8 字节签名 |
