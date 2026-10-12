# Claude Cleanup for Windows

一个经过真实 Windows 环境验证的 Claude Code / Claude Desktop 审计、卸载、缓存清理和验收 Skill。

项目来自一次真实排障：同一台 Windows 机器上同时发现了 Claude Code、Claude in Chrome Native Messaging Host、两套 Claude Desktop Appx/MSIX 包，以及两套 Cowork 后台服务。整个清理流程先在真实机器上执行，再把经验沉淀成可复用脚本。

## v1.1：把“最终验收”做实

第一版已经会检查文件、命令、Appx、服务和 Native Host，但社区反馈指出了一个很好的问题：

“最终验收到底只是核对文件和路径，还是实际启动后验证有没有东西再次被带起来？”

v1.1 因此加入真正的冷启动回归：

1. 清理完成后记录重启前基线。
2. 必须真实重启 Windows。
3. PostRebootValidate 会确认 BootTime 已变化，再重新检查进程、命令、Appx、Cowork 服务和 Native Host。
4. 然后真实打开 Chrome。
5. PostBrowserValidate 等待后检查 claude.exe --chrome-native-host 是否重新出现。

没有真实重启时会返回 NOT_READY，而不是假装通过。

另外，Windows CIM 的 LastBootUpTime 在不同查询间可能出现亚秒级精度抖动，因此 v1.1 要求 BootTime 至少相差 5 秒才认定为真实重启。

## 能解决什么

- 审计 Claude Code / Claude Desktop 的真实安装状态
- 正确识别 NVM4W 下 where claude 出现“双路径”但实际只有一份安装
- 区分普通 Claude Code 会话与 claude.exe --chrome-native-host
- 处理 Claude in Chrome Native Messaging Host
- 识别并卸载重复的 Claude Desktop Appx/MSIX 安装
- 处理 CoworkVMService* 后台服务
- 清理 Cache / Code Cache / GPU Cache / 日志 / VM 运行资源
- 移除废弃的本地 Claude 登录态
- 保护 Skills / Plugins / Projects / Settings 等开发资产
- 做即时验收、重启后验收、Chrome 启动后回生验收

## 安全原则

本项目用于正常排障、卸载、重装和本地数据卫生，不用于绕过 Claude / Anthropic 的账号封禁或平台风控。

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

## 快速开始

先只读审计：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode Audit

即时验收：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode Validate

只清缓存：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode CleanCache -ConfirmToken CLEAN

卸载 Claude Code：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode UninstallCode -ConfirmToken UNINSTALL-CODE

卸载 Claude Desktop：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode UninstallDesktop -ConfirmToken UNINSTALL-DESKTOP

完整卸载：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode FullUninstall -IncludeLargeRuntime -ConfirmToken FULL-UNINSTALL

完整卸载后，脚本会自动准备重启基线，并返回 FinalAcceptancePending=true。

重启 Windows 后：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode PostRebootValidate

确认 PASS 后，打开 Chrome，再执行：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode PostBrowserValidate

如果不是由 FullUninstall 触发，也可以手工准备基线：

    powershell -ExecutionPolicy Bypass -File scripts\claude_cleanup_windows.ps1 -Mode PrepareRebootValidation

## 最终 PASS 的定义

只有以下两项都 PASS，才算最终验收通过：

- PostRebootValidate
- PostBrowserValidate

普通 Validate 只是“当前这一刻看起来干净”，不能替代冷启动回归。

## 实战中发现的 Windows 坑

### 1. where claude 两条路径不一定是两份安装

NVM4W 常见：

    D:\nvm4w\nodejs\claude.cmd
    D:\nvm\<version>\claude.cmd

D:\nvm4w\nodejs 可能只是指向当前 Node 版本目录的 SymbolicLink/Junction，所以不能看到两条路径就卸载两次。

### 2. Chrome 会自动拉起 claude.exe

如果进程链类似：

    chrome.exe
      -> cmd.exe
         -> .claude\chrome\chrome-native-host.bat
            -> claude.exe --chrome-native-host

这是 Claude in Chrome 的 Native Messaging Host，不等同于用户主动打开了一个 Claude Code 交互会话。

### 3. Windows 可以同时存在两套 Claude Desktop

真实环境中同时发现：

- Developer/MSIX Claude
- Microsoft Store AnthropicPBC.Claude

两套包可以各自注册 CoworkVMService*。

正确做法是逐包正常 Remove-AppxPackage，再检查服务。正常卸载后 Cowork 服务会自动消失，不要一开始就 sc delete。

### 4. ProgramData 日志可能拒绝删除

C:\ProgramData\Claude\Logs 可能受 ACL 保护。

如果只剩少量日志：

- 报告路径和大小
- 不自动 takeown
- 不修改 ACL
- 不把它当成整体卸载失败

### 5. 登录态路径必须做真实执行验证

v1.1 修复了一个在重构脚本时暴露的问题：本地登录态路径曾被错误的字符串替换破坏。

现在实际路径固定为：

    %USERPROFILE%\.claude\.credentials.json
    %APPDATA%\Claude\buddy-tokens.json

这类 Bug 也是为什么本项目要求“脚本解析 + 实跑 + 验收”，不能只看代码文本。

## 文件

- SKILL.md：给 AI Agent / Coding Agent 使用的完整操作规范
- scripts/claude_cleanup_windows.ps1：Windows PowerShell 执行脚本
- CHANGELOG.md：版本变化与修复记录

## License

MIT

欢迎 Issue / PR。

