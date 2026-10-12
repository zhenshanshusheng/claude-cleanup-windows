---
name: claude-cleanup-windows
description: Windows 下审计、备份、缓存清理、卸载和验收 Claude Code / Claude Desktop；覆盖 NVM4W、Claude in Chrome Native Host、重复 Appx/MSIX、Cowork 服务和本地登录态。默认保护 skills/plugins/projects/settings/Git/SSH/代理及设备标识。
---

# Claude Cleanup for Windows

本 Skill 用于 Windows 上 Claude Code / Claude Desktop 的排障、干净卸载、缓存清理和重装前检查。

## 安全边界

始终保护 .claude 下的 skills、plugins、projects、hooks、commands、scripts、agents、mcp-configs、CLAUDE.md、settings.json、settings.local.json，以及项目目录、Git/worktree、Git Credential、SSH/GPG、代理/VPN/TUN 和浏览器其他站点数据。

设备状态文件只检查是否存在，不读取、不修改。不得通过本 Skill 修改 Windows、硬件、Claude 或网络设备身份。

## 标准模式

Audit：只读审计。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode Audit

CleanCache：清理可再生缓存/日志。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode CleanCache -ConfirmToken CLEAN

UninstallCode：安全卸载 Claude Code。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode UninstallCode -ConfirmToken UNINSTALL-CODE

UninstallDesktop：卸载当前用户的所有 Claude Desktop Appx/MSIX 包。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode UninstallDesktop -ConfirmToken UNINSTALL-DESKTOP

FullUninstall：保护资产快照、卸载 Code/Desktop、直接移除废弃的本地登录态、清缓存、清 Native Host、最终验收。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode FullUninstall -IncludeLargeRuntime -ConfirmToken FULL-UNINSTALL

Validate：只读验收。

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode Validate

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

FullUninstall 默认直接移除以下废弃本地登录态，不再复制到备份目录：
- %USERPROFILE%\.claude\.credentials.json
- %APPDATA%\Claude\buddy-tokens.json

脚本不输出其内容，也不保留这些旧登录材料的副本。

## 备份与验收

所有写操作前创建：

    %USERPROFILE%\.claude-cleanup-backups\<timestamp>\

只复制普通小体积配置；旧登录材料默认不备份。Skills/Plugins/Projects 不重复复制，以文件数量、体积和关键配置 SHA256 做前后核验。

结果必须分别报告：
- 已卸载内容
- 已清理内容
- 释放空间
- 保留资产
- 非阻塞残留
- 验收状态

任何失败都必须标记为部分完成。

