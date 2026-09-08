# Codex Cache Monitor

A lightweight, read-only Windows monitor for local Codex session telemetry. It shows input tokens, cached input, uncached input, cache hit rate, output tokens, reasoning output, total tokens, and recent context pressure from Codex rollout JSONL files.

一个轻量、只读的 Windows Codex 会话遥测监视器。它从本地 rollout JSONL 读取 token 数据，显示输入、缓存输入、未缓存输入、缓存命中率、输出、推理输出、总 token 与最近一次请求的上下文压力。

**Languages / 语言：** [English](#english) · [中文](#中文)

> Unofficial community utility. Not affiliated with or endorsed by OpenAI.
>
> 非官方社区工具，与 OpenAI 无隶属或背书关系。

---

## English

### What it does

Codex Cache Monitor watches the most recently updated local Codex rollout file and displays:

- Input tokens, including cached input
- Cached input tokens
- Uncached input tokens
- Cache hit rate
- Output tokens
- Reasoning output tokens
- Total tokens
- Session totals and the latest-request values side by side
- Latest-request context pressure when `model_context_window` is available
- Automatic follow of the newest Codex session, or manual selection of a rollout JSONL

The accounting used by the monitor is:

```text
Uncached input = Input - Cached input
Cache hit rate = Cached input / Input
```

`cached_input_tokens` is treated as a subset of `input_tokens`, not an additional amount on top of input.

### Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or later
- A local Codex installation that writes session rollout JSONL files

By default the monitor looks under:

```text
%CODEX_HOME%\sessions
```

If `CODEX_HOME` is not set, it falls back to:

```text
%USERPROFILE%\.codex\sessions
```

### Start the English version

Recommended, without a console window:

```text
Start-CodexCacheMonitor-English-Hidden.vbs
```

For troubleshooting, with a visible console:

```text
Start-CodexCacheMonitor-English.cmd
```

Or run it directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexCacheMonitor.en.ps1
```

To pin the monitor to a specific session file:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexCacheMonitor.en.ps1 -SessionFile "C:\Users\you\.codex\sessions\YYYY\MM\DD\rollout-....jsonl"
```

### Clean shutdown: no background resident process

The monitor is intentionally designed not to become a resident Windows utility.

It does **not** create or install:

- a Windows service
- a scheduled task
- a startup entry
- a tray-resident process
- a PowerShell background job
- a separate monitoring worker process

The GUI refresh loop uses a WinForms timer on the main PowerShell UI thread. The hidden VBS launcher exits immediately after starting the GUI process. When the monitor window is closed, the timer and UI resources are disposed and the PowerShell process exits. A single-instance mutex also prevents accidental duplicate monitor instances.

### Performance and privacy

- Rollout JSONL files are opened read-only.
- No Codex file is modified.
- The monitor does not upload telemetry or send session data anywhere.
- It checks for file changes before parsing.
- When parsing is needed, it scans backward from the file tail, up to 16 MB by default, instead of repeatedly loading an entire large session log.

You can change the refresh interval and tail scan budget:

```powershell
.\CodexCacheMonitor.en.ps1 -RefreshMilliseconds 2000 -MaxTailMB 32
```

### Known limitations

- Auto-follow tracks one most-recently-written rollout file; it does not aggregate multiple subagent rollout files.
- The monitor can only show telemetry fields actually present in the local rollout file. Cache-write telemetry may be absent in some Codex versions/builds, so the displayed cache statistic should be interpreted as observed cache reads.
- If one exceptionally large JSONL line is larger than the configured tail scan window, the monitor may temporarily retain the previous reading until a parsable `token_count` event appears near the tail.
- Local telemetry is not the same thing as your server-side subscription quota or remaining allowance.
- This utility does not estimate billing or subscription usage.

---

## 中文

### 它能做什么

Codex Cache Monitor 会跟随本机最近写入的 Codex rollout 文件，并显示：

- Input tokens（其中包含 cached input）
- Cached input tokens
- Uncached input tokens
- 缓存命中率
- Output tokens
- Reasoning output tokens
- Total tokens
- 本会话累计与最近一次请求的并排统计
- rollout 提供 `model_context_window` 时，显示最近一次请求的上下文压力
- 自动跟随最新 Codex 会话，也可以手动选择某个 rollout JSONL

本工具使用的口径是：

```text
未缓存输入 = Input - Cached input
缓存命中率 = Cached input / Input
```

也就是说，`cached_input_tokens` 被视为 `input_tokens` 的子集，而不是额外叠加在 Input 之外的一份 token。

### 环境要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或更高版本
- 本机 Codex 能生成 session rollout JSONL

默认读取：

```text
%CODEX_HOME%\sessions
```

如果没有设置 `CODEX_HOME`，则读取：

```text
%USERPROFILE%\.codex\sessions
```

### 启动中文版

推荐方式，无黑色控制台窗口：

```text
Start-CodexCacheMonitor-Hidden.vbs
```

排错方式，保留控制台：

```text
Start-CodexCacheMonitor.cmd
```

也可以手动运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexCacheMonitor.ps1
```

固定监视某个会话文件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexCacheMonitor.ps1 -SessionFile "C:\Users\你\.codex\sessions\YYYY\MM\DD\rollout-....jsonl"
```

### 正常关闭，不后台驻留

这个工具从设计上就不做 Windows 常驻插件。

它**不会**创建或安装：

- Windows 服务
- 计划任务
- 开机启动项
- 托盘常驻进程
- PowerShell 后台 Job
- 独立监控 worker 进程

GUI 刷新使用 WinForms 主 UI 线程上的 Timer。隐藏启动器 VBS 在拉起 GUI 后立即自行退出。关闭监视器窗口时，Timer 和界面资源都会释放，承载 GUI 的 PowerShell 进程随即结束。工具还使用单实例互斥锁，避免重复双击后堆出多个监视器。

### 性能与隐私

- 以只读方式打开 rollout JSONL。
- 不修改任何 Codex 文件。
- 不上传 telemetry，也不会把会话数据发送到其他地方。
- 文件没有变化时不会重新解析。
- 需要解析时从文件尾部向前扫描，默认最多 16 MB，不会周期性全量读取巨大的 session 日志。

可以调整刷新间隔与尾部扫描上限：

```powershell
.\CodexCacheMonitor.ps1 -RefreshMilliseconds 2000 -MaxTailMB 32
```

### 已知限制

- 自动跟随模式只跟踪“最近写入”的一个 rollout，不会汇总多个 subagent 的 rollout。
- 工具只能显示本地 rollout 实际提供的字段。某些 Codex 版本或构建可能不提供 cache-write telemetry，因此缓存统计应理解为可观察到的 cache read。
- 如果某一条 JSONL 单行异常巨大，超过尾部扫描上限，工具可能暂时保留上一份读数，直到文件尾再次出现可解析的 `token_count`。
- 本地 telemetry 不等于服务端订阅剩余额度。
- 本工具不估算账单或套餐消耗。

---

## Files / 文件

| File | Purpose |
| --- | --- |
| `CodexCacheMonitor.ps1` | Chinese GUI / 中文 GUI |
| `CodexCacheMonitor.en.ps1` | English GUI / 英文 GUI |
| `Start-CodexCacheMonitor-Hidden.vbs` | Chinese hidden launcher / 中文无控制台启动器 |
| `Start-CodexCacheMonitor.cmd` | Chinese troubleshooting launcher / 中文排错启动器 |
| `Start-CodexCacheMonitor-English-Hidden.vbs` | English hidden launcher / 英文无控制台启动器 |
| `Start-CodexCacheMonitor-English.cmd` | English troubleshooting launcher / 英文排错启动器 |

## License / 许可证

MIT License. See [`LICENSE`](LICENSE).

MIT 许可证，详见 [`LICENSE`](LICENSE)。

## Contributing / 贡献

Issues and pull requests are welcome, especially for rollout schema changes, compatibility reports, and small improvements that keep the monitor lightweight and non-resident.

欢迎提交 Issue 和 Pull Request，尤其是 Codex rollout 字段变化、兼容性反馈，以及保持工具轻量、不驻留前提下的小型改进。
