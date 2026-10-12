---
name: claude-cleanup-windows
description: Windows 下审计、备份、缓存清理、卸载和验收 Claude Code / Claude Desktop；覆盖 NVM4W、Claude in Chrome Native Host、重复 Appx/MSIX、Cowork 服务、本地登录态，以及重启后/浏览器启动后的回生验证。
---

# Claude Cleanup for Windows

本 Skill 用于 Windows 上 Claude Code / Claude Desktop 的排障、干净卸载、缓存清理和重装前检查。

从 v1.1 开始，“文件和路径已删除”不再等于最终验收通过。完整卸载只有在重启 Windows 后重新检查一次，并在启动 Chrome 后再次确认 Claude Native Host 没有被重新拉起，才算最终通过。

## 安全边界

始终保护 .claude 下的 skills、plugins、projects、hooks、commands、scripts、agents、mcp-configs、CLAUDE.md、settings.json、settings.local.json，以及项目目录、Git/worktree、Git Credential、SSH/GPG、代理/VPN/TUN 和浏览器其他站点数据。

设备状态文件只检查是否存在，不读取、不修改。不得通过本 Skill 修改 Windows、硬件、Claude 或网络设备身份。

## 标准模式

Audit：只读审计当前状态。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode Audit

Validate：即时验收当前状态。它不证明“重启后不会回生”。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode Validate

CleanCache：清理可再生缓存/日志。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode CleanCache -ConfirmToken CLEAN

UninstallCode：安全卸载 Claude Code。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode UninstallCode -ConfirmToken UNINSTALL-CODE

UninstallDesktop：卸载当前用户的所有 Claude Desktop Appx/MSIX 包。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode UninstallDesktop -ConfirmToken UNINSTALL-DESKTOP

FullUninstall：保护资产快照、卸载 Code/Desktop、移除废弃本地登录态、清缓存、清 Native Host，并自动创建“重启前基线”。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode FullUninstall -IncludeLargeRuntime -ConfirmToken FULL-UNINSTALL

FullUninstall 返回 FinalAcceptancePending=true 时，表示即时清理完成，但最终验收还没有完成。

PrepareRebootValidation：单独记录一次重启前基线。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode PrepareRebootValidation

PostRebootValidate：重启 Windows 后执行。只有检测到系统 BootTime 确实晚于基线 BootTime，才允许进入 PASS 判定。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode PostRebootValidate

PostBrowserValidate：PostRebootValidate 通过后，实际启动 Chrome，等待数秒，再检查 Claude Native Host 是否被重新拉起。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode PostBrowserValidate

默认等待 10 秒，也可以指定：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode PostBrowserValidate -BrowserWaitSeconds 20

## 最终验收门槛

完整卸载的最终 PASS 必须按顺序满足：

1. 即时 Validate 中以下项目全部通过：
   - 无 claude.exe
   - where claude 为空
   - 无 Claude Desktop Appx/MSIX
   - 无 CoworkVMService*
   - 无 Claude Code Native Messaging 注册
   - 无 Native Host 文件目录
2. FullUninstall 或 PrepareRebootValidation 已写入重启前基线。
3. 用户真实重启 Windows。
4. PostRebootValidate 返回 PASS。
5. 用户真实打开 Chrome。
6. PostBrowserValidate 返回 PASS，确认：
   - 没有 claude.exe --chrome-native-host
   - Native Messaging 注册没有恢复
   - Native Host 文件没有恢复

如果没有真实重启，PostRebootValidate 必须返回 NOT_READY，不能把当前状态冒充为冷启动验证结果。

为避免 Windows CIM 的亚秒级 BootTime 精度抖动造成误判，只有当前 BootTime 比基线至少晚 5 秒，才认定为发生过真实重启。

如果 Chrome 没有真正运行，PostBrowserValidate 必须返回 NOT_READY。

## 为什么不把“重新启动 Claude 本体”作为卸载验收

FullUninstall 的目标就是让 Claude Code / Desktop 不再存在，因此成功卸载后没有 Claude 本体可启动。

为了验证“有没有东西被系统重新带起来”，更合理的回归是：

- 真实重启 Windows，验证服务、Appx、命令和 Native Host 不回生；
- 再真实启动 Chrome，验证 Claude in Chrome 不会重新拉起 claude.exe --chrome-native-host。

如果用户以后重新安装 Claude，应在安装后重新运行 Audit / Validate，这属于“重装后的环境验收”，不是“卸载成功”的必要条件。

## Claude Code / NVM4W 规则

where claude 可能同时显示 D:\nvm4w\nodejs\claude.cmd 和 D:\nvm\<version>\claude.cmd。

必须先检查 D:\nvm4w\nodejs 的 LinkType/Target。如果它指向当前 NVM Node 目录，则两条路径是同一份安装，只允许执行一次：

    npm uninstall -g @anthropic-ai/claude-code

卸载后验证 where claude 为空，并检查 @anthropic-ai\claude-code 包目录不存在。

## Claude in Chrome Native Host

若进程链为 chrome.exe -> cmd.exe -> .claude\chrome\chrome-native-host.bat -> claude.exe --chrome-native-host，则它是浏览器 Native Messaging Host，不等于用户主动打开了一个交互式 Claude Code 会话。

只有当命令行明确包含 --chrome-native-host 时，脚本才允许结束这个子进程。普通交互式 claude.exe 存在时必须停止写操作并要求用户正常退出。

卸载 Code 后清理：

- %USERPROFILE%\.claude\chrome
- %APPDATA%\Claude Code\ChromeNativeHost
- Chrome / Chromium / Edge 的 com.anthropic.claude_code_browser_extension Native Messaging 注册

默认不删除 Claude in Chrome 浏览器扩展本身。

## Claude Desktop 规则

可能同时存在：

- Claude，SignatureKind=Developer
- AnthropicPBC.Claude，Microsoft Store 包

两套安装可以各自注册 CoworkVMService*。

标准流程：

1. 枚举所有 Claude Appx/MSIX 包。
2. 停止 CoworkVMService*。
3. 对当前用户逐包 Remove-AppxPackage。
4. 再检查 Appx 包和 Cowork 服务。
5. 实测正常卸载包后 Cowork 服务会自动消失，因此不要预先 sc delete。
6. 如果卸载后只剩失效 orphan service，报告即可，默认不强删。

## 可再生数据

普通缓存候选：

- %USERPROFILE%\.claude\cache
- %USERPROFILE%\.claude\stats-cache.json
- %USERPROFILE%\.claude\telemetry
- %USERPROFILE%\.claude\paste-cache
- %LOCALAPPDATA%\claude-cli-nodejs\Cache
- %APPDATA%\Claude\Cache
- %APPDATA%\Claude\Code Cache
- %APPDATA%\Claude\GPUCache
- %APPDATA%\Claude\DawnWebGPUCache
- %APPDATA%\Claude\DawnGraphiteCache
- %APPDATA%\Claude\Crashpad
- %APPDATA%\Claude\logs
- %APPDATA%\Claude\sentry
- %LOCALAPPDATA%\Claude\Logs

IncludeLargeRuntime 额外处理：

- %APPDATA%\Claude\vm_bundles
- %APPDATA%\Claude\claude-code
- %APPDATA%\Claude\claude-code-vm

%ProgramData%\Claude\Logs 如果因 ACL 拒绝删除，只记录路径和大小，不 takeown、不改 ACL、不将其视为卸载失败。

## 本地登录态

FullUninstall 默认直接移除以下废弃本地登录态，不复制到备份目录：

- %USERPROFILE%\.claude\.credentials.json
- %APPDATA%\Claude\buddy-tokens.json

脚本不输出其内容，也不保留这些旧登录材料的副本。

## 备份与验收基线

写操作前的普通保护快照：

    %USERPROFILE%\.claude-cleanup-backups\<timestamp>\

重启回归基线：

    %USERPROFILE%\.claude-cleanup-validation\latest-reboot-baseline.json

基线记录：

- 创建时间
- 当时 Windows BootTime
- 清理后的即时状态
- 关键配置 SHA256
- Skills / Plugins / Projects 的文件数量与体积

PostRebootValidate 会将重启后的状态与这份基线比较。

只复制普通小体积配置；旧登录材料默认不备份。Skills/Plugins/Projects 不重复复制，以文件数量、体积和关键配置 SHA256 做前后核验。

## 结果报告

必须分别报告：

- 已卸载内容
- 已清理内容
- 释放空间
- 保留资产
- 非阻塞残留
- 即时验收状态
- 重启后验收状态
- Chrome 启动后回生验收状态

任何失败必须标记为部分完成。

只有 PostRebootValidate 和 PostBrowserValidate 都 PASS，才能使用“最终验收通过”这个结论。

