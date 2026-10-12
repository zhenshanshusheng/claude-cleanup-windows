# Claude Cleanup for Windows

一个经过真实 Windows 环境验证的 Claude Code / Claude Desktop 审计、卸载、缓存清理和验收 Skill。

这份 Skill 来源于一次真实故障排查：Windows 上同时存在 Claude Code、Claude in Chrome Native Messaging Host、两套 Claude Desktop Appx/MSIX 包和两套 Cowork 后台服务。清理流程是在实际机器上逐步执行、验证，再沉淀为可重复使用的自动化流程。

## 能解决什么

- 审计 Claude Code / Claude Desktop 在 Windows 上的真实安装状态
- 正确识别 NVM4W 下 where claude 出现“双路径”但实际只有一份安装的情况
- 区分普通 Claude Code 会话与 claude.exe --chrome-native-host
- 处理 Claude in Chrome Native Messaging Host
- 识别并卸载重复的 Claude Desktop Appx/MSIX 安装
- 处理 CoworkVMService 后台服务
- 清理可再生 Cache / Code Cache / GPU Cache / 日志 / VM 运行资源
- 清除已经废弃的本地 Claude 登录态
- 在清理前后验证 Skills / Plugins / Projects / Settings 等用户资产没有被误删

## 安全原则

本项目的目标是正常排障、卸载、重装和本地数据卫生，不用于绕过 Claude / Anthropic 的账号封禁或平台风控。

脚本默认保护：

- .claude\skills
- .claude\plugins
- .claude\projects
- .claude\hooks
- .claude\commands
- .claude\scripts
- .claude\agents
- .claude\mcp-configs
- CLAUDE.md
- settings.json
- settings.local.json
- Git / worktree / Git Credential
- SSH / GPG
- 代理、VPN、TUN
- 浏览器其他站点数据
- Windows、硬件及 Claude 设备标识

不会通过修改设备身份、浏览器指纹或网络身份规避平台风控。

## 快速开始

先执行只读审计：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode Audit

只清缓存：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode CleanCache -ConfirmToken CLEAN

卸载 Claude Code：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode UninstallCode -ConfirmToken UNINSTALL-CODE

卸载 Claude Desktop：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode UninstallDesktop -ConfirmToken UNINSTALL-DESKTOP

完整卸载与清理：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode FullUninstall -IncludeLargeRuntime -ConfirmToken FULL-UNINSTALL

最终验收：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode Validate

## 实战中发现的 Windows 坑

### 1. where claude 两条路径不一定是安装了两份

NVM4W 常见：

    D:\nvm4w\nodejs\claude.cmd
    D:\nvm\<version>\claude.cmd

D:\nvm4w\nodejs 可能只是指向当前 Node 版本目录的 SymbolicLink/Junction。

所以不能看到两条路径就卸载两次。

### 2. Chrome 会自动拉起 claude.exe

如果进程链类似：

    chrome.exe
      -> cmd.exe
         -> .claude\chrome\chrome-native-host.bat
            -> claude.exe --chrome-native-host

这是 Claude in Chrome 的 Native Messaging Host，不等同于用户主动打开了一个 Claude Code 交互会话。

### 3. Windows 可以同时存在两套 Claude Desktop

实测环境中同时发现：

- Developer/MSIX Claude
- Microsoft Store AnthropicPBC.Claude

两套包各自注册了 CoworkVMService。

正确做法是逐包正常 Remove-AppxPackage，再检查服务。正常卸载后 Cowork 服务会自动消失，不要一开始就 sc delete。

### 4. ProgramData 日志可能拒绝删除

C:\ProgramData\Claude\Logs 可能受 ACL 保护。

如果只剩少量日志：

- 报告路径和大小
- 不自动 takeown
- 不修改 ACL
- 不把它当成整体卸载失败

## 文件

- SKILL.md：给 AI Agent / Coding Agent 使用的完整操作规范
- scripts/claude_cleanup_windows.ps1：Windows PowerShell 执行脚本

## 说明

执行任何卸载或清理操作前，建议先阅读 SKILL.md 并先运行 Audit。

如果你在其他 Windows / NVM / Claude Desktop 版本上遇到不同情况，欢迎提交 Issue 或 PR。

## License

MIT
