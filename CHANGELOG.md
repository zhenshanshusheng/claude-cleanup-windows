# Changelog

## v1.1.0 - 2026-10-12

### Added

- 新增 PrepareRebootValidation。
- 新增 PostRebootValidate。
- 新增 PostBrowserValidate。
- FullUninstall 完成后自动生成重启前基线，并明确返回 FinalAcceptancePending=true。
- 验收基线记录 Windows BootTime、即时清理状态、关键配置 SHA256，以及 Skills / Plugins / Projects 文件数量与体积。
- PostRebootValidate 必须检测到真实的新 BootTime，否则返回 NOT_READY。
- BootTime 判定加入 5 秒容差，避免 Windows CIM 亚秒级精度抖动导致同一次开机被误判为“已重启”。
- PostBrowserValidate 要求 Chrome 真正处于运行状态，并检查 claude.exe --chrome-native-host、Native Messaging 注册和 Native Host 路径是否回生。
- Audit 增加 BootTime、ChromeRunning 和 NativeHostPaths。

### Fixed

- 修复 Remove-LocalLoginState 中两个路径被错误字符串替换破坏的问题。
- 正确路径为：
  - %USERPROFILE%\.claude\.credentials.json
  - %APPDATA%\Claude\buddy-tokens.json

### Changed

- Validate 明确定义为“即时状态验收”，不再等价于最终验收。
- 只有 PostRebootValidate 与 PostBrowserValidate 都 PASS，才允许报告“最终验收通过”。

## v1.0.0 - 2026-10-12

- 首个公开版本。
- 支持 Windows Claude Code / Claude Desktop 审计、卸载、缓存清理和即时验收。
- 支持 NVM4W 双路径识别。
- 支持 Claude in Chrome Native Host 识别和清理。
- 支持重复 Claude Desktop Appx/MSIX 与 Cowork 服务处理。

