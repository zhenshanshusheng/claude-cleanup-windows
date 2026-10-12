param(
  [ValidateSet('Audit','CleanCache','UninstallCode','UninstallDesktop','FullUninstall','Validate')]
  [string]$Mode='Audit',
  [switch]$IncludeLargeRuntime,
  [string]$ConfirmToken=''
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$U=$env:USERPROFILE
$R=$env:APPDATA
$L=$env:LOCALAPPDATA
$PD=$env:ProgramData
$Stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup=Join-Path $U ".claude-cleanup-backups\$Stamp"

function Get-SizeMB([string]$P){
  if(!(Test-Path -LiteralPath $P)){return $null}
  $i=Get-Item -LiteralPath $P -Force
  if(!$i.PSIsContainer){return [math]::Round($i.Length/1MB,3)}
  $s=(Get-ChildItem -LiteralPath $P -Force -Recurse -File -ErrorAction SilentlyContinue|Measure-Object Length -Sum).Sum
  if($null -eq $s){$s=0}
  return [math]::Round($s/1MB,3)
}

function Get-ClaudeProcesses {
  @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {$_.Name -match '^(?i)claude(\.exe)?$'} |
    Select-Object ProcessId,ParentProcessId,Name,ExecutablePath,CommandLine,CreationDate)
}

function Get-DesktopPackages {
  @(Get-AppxPackage | Where-Object {$_.Name -match '(?i)^Claude$|AnthropicPBC\.Claude'} |
    Select-Object Name,PackageFullName,Version,InstallLocation,SignatureKind)
}

function Get-CoworkServices {
  @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object {$_.Name -match '^CoworkVMService'} |
    Select-Object Name,State,StartMode,PathName,ProcessId)
}

function Save-ProtectedSnapshot {
  New-Item -ItemType Directory -Path $Backup -Force | Out-Null
  $files=@(
    "$U\.claude.json",
    "$U\.claude\CLAUDE.md",
    "$U\.claude\settings.json",
    "$U\.claude\settings.local.json",
    "$R\Claude\claude_desktop_config.json"
  )
  $fm=@()
  foreach($p in $files){
    if(Test-Path -LiteralPath $p){
      $i=Get-Item -LiteralPath $p -Force
      $fm += [pscustomobject]@{Path=$p;Size=$i.Length;SHA256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
      $name=($p -replace '[:\\/]','_').Trim('_')
      Copy-Item -LiteralPath $p -Destination (Join-Path $Backup $name) -Force
    }
  }
  $dm=@()
  foreach($d in @("$U\.claude\skills","$U\.claude\plugins","$U\.claude\projects")){
    if(Test-Path -LiteralPath $d){
      $f=Get-ChildItem -LiteralPath $d -Force -Recurse -File -ErrorAction SilentlyContinue
      $s=($f|Measure-Object Length -Sum).Sum
      if($null -eq $s){$s=0}
      $dm += [pscustomobject]@{Path=$d;Files=$f.Count;SizeMB=[math]::Round($s/1MB,3)}
    }
  }
  [pscustomobject]@{CreatedAt=(Get-Date).ToString('o');Files=$fm;Directories=$dm} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Backup 'protected-assets-pre.json') -Encoding UTF8
}

function Stop-NativeHostOnly {
  $all=Get-ClaudeProcesses
  $interactive=@($all|Where-Object {$_.CommandLine -notmatch '--chrome-native-host'})
  if($interactive.Count -gt 0){throw 'Interactive Claude process exists. Close it normally before continuing.'}
  foreach($p in @($all|Where-Object {$_.CommandLine -match '--chrome-native-host'})){
    Stop-Process -Id $p.ProcessId -Force
  }
}

function Stop-CoworkServices {
  foreach($s in Get-CoworkServices){Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue}
}

function Remove-NativeHost {
  foreach($r in @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_code_browser_extension',
    'HKCU:\Software\Chromium\NativeMessagingHosts\com.anthropic.claude_code_browser_extension',
    'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.anthropic.claude_code_browser_extension'
  )){
    if(Test-Path $r){Remove-Item -LiteralPath $r -Force -Recurse}
  }
  foreach($p in @("$R\Claude Code\ChromeNativeHost","$U\.claude\chrome")){
    if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force -Recurse}
  }
}

function Invoke-CacheClean {
  $targets=@(
    "$U\.claude\cache","$U\.claude\stats-cache.json","$U\.claude\telemetry","$U\.claude\paste-cache",
    "$L\claude-cli-nodejs\Cache",
    "$R\Claude\Cache","$R\Claude\Code Cache","$R\Claude\GPUCache",
    "$R\Claude\DawnWebGPUCache","$R\Claude\DawnGraphiteCache","$R\Claude\Crashpad",
    "$R\Claude\logs","$R\Claude\sentry","$L\Claude\Logs"
  )
  if($IncludeLargeRuntime){$targets += @("$R\Claude\vm_bundles","$R\Claude\claude-code","$R\Claude\claude-code-vm")}
  $freed=0
  foreach($p in $targets){
    if(Test-Path -LiteralPath $p){
      $mb=Get-SizeMB $p
      try{
        Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction Stop
        if($null -ne $mb){$freed += $mb}
      }catch{Write-Warning "Could not remove $p : $($_.Exception.Message)"}
    }
  }
  if(Test-Path -LiteralPath "$PD\Claude\Logs"){
    try{Remove-Item -LiteralPath "$PD\Claude\Logs" -Force -Recurse -ErrorAction Stop}
    catch{Write-Warning "ProgramData Claude logs retained because of ACL: $($_.Exception.Message)"}
  }
  return [math]::Round($freed,3)
}

function Remove-LocalLoginState {
  foreach($p in @("$U.claude.credentials.json","$RClaudeuddy-tokens.json")){
    if(Test-Path -LiteralPath $p){
      Remove-Item -LiteralPath $p -Force
    }
  }
}

function Invoke-UninstallCode {
  Stop-NativeHostOnly
  $cmd=Get-Command npm.cmd -ErrorAction SilentlyContinue
  if($cmd){
    & $cmd.Source uninstall -g '@anthropic-ai/claude-code'
    if($LASTEXITCODE -ne 0){throw "npm uninstall failed: $LASTEXITCODE"}
  }
  Remove-NativeHost
}

function Invoke-UninstallDesktop {
  Stop-CoworkServices
  foreach($p in Get-DesktopPackages){
    Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
  }
}

function Get-Audit {
  $link=$null
  if(Test-Path -LiteralPath 'D:\nvm4w\nodejs'){
    $i=Get-Item -LiteralPath 'D:\nvm4w\nodejs' -Force
    $link=[pscustomobject]@{Path=$i.FullName;Attributes=$i.Attributes.ToString();LinkType=$i.LinkType;Target=$i.Target}
  }
  [pscustomobject]@{
    Mode=$Mode
    Processes=Get-ClaudeProcesses
    WhereClaude=@(& where.exe claude 2>$null)
    Nvm4wNodeLink=$link
    DesktopPackages=Get-DesktopPackages
    CoworkServices=Get-CoworkServices
    NativeHostRegistry=@(
      'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_code_browser_extension',
      'HKCU:\Software\Chromium\NativeMessagingHosts\com.anthropic.claude_code_browser_extension',
      'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.anthropic.claude_code_browser_extension'
    ) | ForEach-Object {[pscustomobject]@{Path=$_;Exists=(Test-Path $_)}}
    ProtectedAssets=@(
      "$U\.claude\skills","$U\.claude\plugins","$U\.claude\projects",
      "$U\.claude\settings.json","$U\.claude\settings.local.json","$U\.claude\CLAUDE.md"
    ) | ForEach-Object {[pscustomobject]@{Path=$_;Exists=(Test-Path -LiteralPath $_);SizeMB=Get-SizeMB $_}}
    DeviceStateFiles=@(
      "$R\Claude\ant-did","$R\Claude\ant-device-registry.json","$R\Claude\ccd-ids.json"
    ) | ForEach-Object {[pscustomobject]@{Path=$_;Exists=(Test-Path -LiteralPath $_)}}
  }
}

switch($Mode){
  'Audit' {Get-Audit|ConvertTo-Json -Depth 8}
  'Validate' {Get-Audit|ConvertTo-Json -Depth 8}
  'CleanCache' {
    if($ConfirmToken -ne 'CLEAN'){throw 'Use -ConfirmToken CLEAN'}
    Stop-NativeHostOnly
    Save-ProtectedSnapshot
    $freed=Invoke-CacheClean
    [pscustomobject]@{Mode=$Mode;Backup=$Backup;FreedMB=$freed;Validation=Get-Audit}|ConvertTo-Json -Depth 8
  }
  'UninstallCode' {
    if($ConfirmToken -ne 'UNINSTALL-CODE'){throw 'Use -ConfirmToken UNINSTALL-CODE'}
    Save-ProtectedSnapshot
    Invoke-UninstallCode
    [pscustomobject]@{Mode=$Mode;Backup=$Backup;Validation=Get-Audit}|ConvertTo-Json -Depth 8
  }
  'UninstallDesktop' {
    if($ConfirmToken -ne 'UNINSTALL-DESKTOP'){throw 'Use -ConfirmToken UNINSTALL-DESKTOP'}
    Save-ProtectedSnapshot
    Invoke-UninstallDesktop
    [pscustomobject]@{Mode=$Mode;Backup=$Backup;Validation=Get-Audit}|ConvertTo-Json -Depth 8
  }
  'FullUninstall' {
    if($ConfirmToken -ne 'FULL-UNINSTALL'){throw 'Use -ConfirmToken FULL-UNINSTALL'}
    Save-ProtectedSnapshot
    Stop-NativeHostOnly
    Stop-CoworkServices
    Invoke-UninstallCode
    Invoke-UninstallDesktop
    Remove-LocalLoginState
    $freed=Invoke-CacheClean
    [pscustomobject]@{Mode=$Mode;Backup=$Backup;FreedMB=$freed;Validation=Get-Audit}|ConvertTo-Json -Depth 8
  }
}

