param(
  [ValidateSet('Audit','CleanCache','UninstallCode','UninstallDesktop','FullUninstall','Validate','PrepareRebootValidation','PostRebootValidate','PostBrowserValidate')]
  [string]$Mode='Audit',
  [switch]$IncludeLargeRuntime,
  [string]$ConfirmToken='',
  [ValidateRange(0,120)]
  [int]$BrowserWaitSeconds=10
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$U=$env:USERPROFILE
$R=$env:APPDATA
$L=$env:LOCALAPPDATA
$PD=$env:ProgramData
$Stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup=Join-Path $U ".claude-cleanup-backups\$Stamp"
$ValidationRoot=Join-Path $U '.claude-cleanup-validation'
$RebootBaseline=Join-Path $ValidationRoot 'latest-reboot-baseline.json'

function Get-SizeMB([string]$P){
  if(!(Test-Path -LiteralPath $P)){return $null}
  $i=Get-Item -LiteralPath $P -Force
  if(!$i.PSIsContainer){return [math]::Round($i.Length/1MB,3)}
  $s=(Get-ChildItem -LiteralPath $P -Force -Recurse -File -ErrorAction SilentlyContinue|Measure-Object Length -Sum).Sum
  if($null -eq $s){$s=0}
  return [math]::Round($s/1MB,3)
}

function Get-SystemBootTime {
  return (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
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

function Get-NativeHostRegistryState {
  @(
    'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_code_browser_extension',
    'HKCU:\Software\Chromium\NativeMessagingHosts\com.anthropic.claude_code_browser_extension',
    'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.anthropic.claude_code_browser_extension'
  ) | ForEach-Object {[pscustomobject]@{Path=$_;Exists=(Test-Path $_)}}
}

function Get-NativeHostPathState {
  @(
    "$R\Claude Code\ChromeNativeHost",
    "$U\.claude\chrome"
  ) | ForEach-Object {[pscustomobject]@{Path=$_;Exists=(Test-Path -LiteralPath $_)}}
}

function Get-ProtectedFingerprint {
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
      $fm += [pscustomobject]@{
        Path=$p
        Exists=$true
        Size=$i.Length
        SHA256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
      }
    }else{
      $fm += [pscustomobject]@{Path=$p;Exists=$false;Size=$null;SHA256=$null}
    }
  }

  $dm=@()
  foreach($d in @("$U\.claude\skills","$U\.claude\plugins","$U\.claude\projects")){
    if(Test-Path -LiteralPath $d){
      $f=Get-ChildItem -LiteralPath $d -Force -Recurse -File -ErrorAction SilentlyContinue
      $s=($f|Measure-Object Length -Sum).Sum
      if($null -eq $s){$s=0}
      $dm += [pscustomobject]@{
        Path=$d
        Exists=$true
        Files=$f.Count
        SizeMB=[math]::Round($s/1MB,3)
      }
    }else{
      $dm += [pscustomobject]@{Path=$d;Exists=$false;Files=0;SizeMB=0}
    }
  }

  [pscustomobject]@{Files=$fm;Directories=$dm}
}

function Save-ProtectedSnapshot {
  New-Item -ItemType Directory -Path $Backup -Force | Out-Null
  $fingerprint=Get-ProtectedFingerprint

  foreach($f in $fingerprint.Files){
    if($f.Exists){
      $name=($f.Path -replace '[:\\/]','_').Trim('_')
      Copy-Item -LiteralPath $f.Path -Destination (Join-Path $Backup $name) -Force
    }
  }

  [pscustomobject]@{
    CreatedAt=(Get-Date).ToString('o')
    Fingerprint=$fingerprint
  } | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (Join-Path $Backup 'protected-assets-pre.json') -Encoding UTF8
}

function Compare-ProtectedFingerprint($Before) {
  $now=Get-ProtectedFingerprint
  $changes=@()

  foreach($old in @($Before.Files)){
    $new=@($now.Files|Where-Object {$_.Path -eq $old.Path})[0]
    if($old.Exists -ne $new.Exists){
      $changes += "File existence changed: $($old.Path)"
    }elseif($old.Exists -and $old.SHA256 -ne $new.SHA256){
      $changes += "File hash changed: $($old.Path)"
    }
  }

  foreach($old in @($Before.Directories)){
    $new=@($now.Directories|Where-Object {$_.Path -eq $old.Path})[0]
    if($old.Exists -ne $new.Exists){
      $changes += "Directory existence changed: $($old.Path)"
    }elseif($old.Exists -and (($old.Files -ne $new.Files) -or ([double]$old.SizeMB -ne [double]$new.SizeMB))){
      $changes += "Directory inventory changed: $($old.Path)"
    }
  }

  [pscustomobject]@{
    Passed=($changes.Count -eq 0)
    Changes=$changes
    Current=$now
  }
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
  if($IncludeLargeRuntime){
    $targets += @("$R\Claude\vm_bundles","$R\Claude\claude-code","$R\Claude\claude-code-vm")
  }

  $freed=0
  foreach($p in $targets){
    if(Test-Path -LiteralPath $p){
      $mb=Get-SizeMB $p
      try{
        Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction Stop
        if($null -ne $mb){$freed += $mb}
      }catch{
        Write-Warning "Could not remove $p : $($_.Exception.Message)"
      }
    }
  }

  if(Test-Path -LiteralPath "$PD\Claude\Logs"){
    try{
      Remove-Item -LiteralPath "$PD\Claude\Logs" -Force -Recurse -ErrorAction Stop
    }catch{
      Write-Warning "ProgramData Claude logs retained because of ACL: $($_.Exception.Message)"
    }
  }

  return [math]::Round($freed,3)
}

function Remove-LocalLoginState {
  foreach($p in @("$U\.claude\.credentials.json","$R\Claude\buddy-tokens.json")){
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
    $link=[pscustomobject]@{
      Path=$i.FullName
      Attributes=$i.Attributes.ToString()
      LinkType=$i.LinkType
      Target=$i.Target
    }
  }

  [pscustomobject]@{
    Mode=$Mode
    CheckedAt=(Get-Date).ToString('o')
    BootTime=(Get-SystemBootTime).ToString('o')
    Processes=Get-ClaudeProcesses
    WhereClaude=@(& where.exe claude 2>$null)
    Nvm4wNodeLink=$link
    DesktopPackages=Get-DesktopPackages
    CoworkServices=Get-CoworkServices
    NativeHostRegistry=Get-NativeHostRegistryState
    NativeHostPaths=Get-NativeHostPathState
    ChromeRunning=(@(Get-Process chrome -ErrorAction SilentlyContinue).Count -gt 0)
    ProtectedAssets=@(
      "$U\.claude\skills","$U\.claude\plugins","$U\.claude\projects",
      "$U\.claude\settings.json","$U\.claude\settings.local.json","$U\.claude\CLAUDE.md"
    ) | ForEach-Object {
      [pscustomobject]@{Path=$_;Exists=(Test-Path -LiteralPath $_);SizeMB=Get-SizeMB $_}
    }
    DeviceStateFiles=@(
      "$R\Claude\ant-did","$R\Claude\ant-device-registry.json","$R\Claude\ccd-ids.json"
    ) | ForEach-Object {
      [pscustomobject]@{Path=$_;Exists=(Test-Path -LiteralPath $_)}
    }
  }
}

function Get-CleanStateChecks($Audit) {
  $checks=[ordered]@{
    NoClaudeProcesses=(@($Audit.Processes).Count -eq 0)
    WhereClaudeEmpty=(@($Audit.WhereClaude).Count -eq 0)
    NoDesktopPackages=(@($Audit.DesktopPackages).Count -eq 0)
    NoCoworkServices=(@($Audit.CoworkServices).Count -eq 0)
    NoNativeHostRegistry=(@($Audit.NativeHostRegistry|Where-Object {$_.Exists}).Count -eq 0)
    NoNativeHostPaths=(@($Audit.NativeHostPaths|Where-Object {$_.Exists}).Count -eq 0)
  }

  $failed=@()
  foreach($kv in $checks.GetEnumerator()){
    if(-not $kv.Value){$failed += $kv.Key}
  }

  [pscustomobject]@{
    Passed=($failed.Count -eq 0)
    Checks=[pscustomobject]$checks
    Failed=$failed
  }
}

function Save-RebootBaseline {
  New-Item -ItemType Directory -Path $ValidationRoot -Force | Out-Null
  $audit=Get-Audit
  $clean=Get-CleanStateChecks $audit
  $baseline=[pscustomobject]@{
    SchemaVersion=1
    CreatedAt=(Get-Date).ToString('o')
    BootTime=(Get-SystemBootTime).ToString('o')
    CleanState=$clean
    ProtectedFingerprint=Get-ProtectedFingerprint
  }
  $baseline|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $RebootBaseline -Encoding UTF8
  return $baseline
}

function Invoke-PostRebootValidation {
  if(!(Test-Path -LiteralPath $RebootBaseline)){
    return [pscustomobject]@{
      Status='NOT_READY'
      Passed=$false
      Reason='No reboot baseline found. Run PrepareRebootValidation first.'
      BaselinePath=$RebootBaseline
    }
  }

  $baseline=Get-Content -LiteralPath $RebootBaseline -Raw|ConvertFrom-Json
  $beforeBoot=[datetimeoffset]::Parse($baseline.BootTime)
  $currentBoot=[datetimeoffset](Get-SystemBootTime)
  $bootDeltaSeconds=($currentBoot - $beforeBoot).TotalSeconds
  $rebootConfirmed=($bootDeltaSeconds -ge 5)
  $audit=Get-Audit
  $clean=Get-CleanStateChecks $audit
  $protected=Compare-ProtectedFingerprint $baseline.ProtectedFingerprint

  $passed=$rebootConfirmed -and $clean.Passed -and $protected.Passed
  $status=if(-not $rebootConfirmed){'NOT_READY'}elseif($passed){'PASS'}else{'FAIL'}

  [pscustomobject]@{
    Status=$status
    Passed=$passed
    RebootConfirmed=$rebootConfirmed
    BaselineBootTime=$beforeBoot.ToString('o')
    CurrentBootTime=$currentBoot.ToString('o')
    BootTimeDeltaSeconds=[math]::Round($bootDeltaSeconds,3)
    CleanState=$clean
    ProtectedState=$protected
    Audit=$audit
    NextStep=if(-not $rebootConfirmed){'Reboot Windows, then run PostRebootValidate again.'}elseif($passed){'Start Chrome, wait a few seconds, then run PostBrowserValidate.'}else{'Resolve failed checks before final acceptance.'}
  }
}

function Invoke-PostBrowserValidation {
  if(!(Test-Path -LiteralPath $RebootBaseline)){
    return [pscustomobject]@{
      Status='NOT_READY'
      Passed=$false
      Reason='No reboot baseline found. Run PrepareRebootValidation first.'
    }
  }

  $baseline=Get-Content -LiteralPath $RebootBaseline -Raw|ConvertFrom-Json
  $beforeBoot=[datetimeoffset]::Parse($baseline.BootTime)
  $currentBoot=[datetimeoffset](Get-SystemBootTime)
  $bootDeltaSeconds=($currentBoot - $beforeBoot).TotalSeconds
  $rebootConfirmed=($bootDeltaSeconds -ge 5)
  $chromeRunning=(@(Get-Process chrome -ErrorAction SilentlyContinue).Count -gt 0)

  if($chromeRunning -and $BrowserWaitSeconds -gt 0){
    Start-Sleep -Seconds $BrowserWaitSeconds
  }

  $audit=Get-Audit
  $nativeProcesses=@($audit.Processes|Where-Object {$_.CommandLine -match '--chrome-native-host'})
  $nativeRegistry=@($audit.NativeHostRegistry|Where-Object {$_.Exists})
  $nativePaths=@($audit.NativeHostPaths|Where-Object {$_.Exists})

  $checks=[ordered]@{
    RebootConfirmed=$rebootConfirmed
    BootTimeDeltaSeconds=[math]::Round($bootDeltaSeconds,3)
    ChromeRunning=$chromeRunning
    NoClaudeNativeHostProcess=($nativeProcesses.Count -eq 0)
    NoNativeHostRegistry=($nativeRegistry.Count -eq 0)
    NoNativeHostPaths=($nativePaths.Count -eq 0)
  }

  $failed=@()
  foreach($kv in $checks.GetEnumerator()){
    if(-not $kv.Value){$failed += $kv.Key}
  }

  $passed=($failed.Count -eq 0)
  $status=if(-not $rebootConfirmed -or -not $chromeRunning){'NOT_READY'}elseif($passed){'PASS'}else{'FAIL'}

  [pscustomobject]@{
    Status=$status
    Passed=($status -eq 'PASS')
    Checks=[pscustomobject]$checks
    Failed=$failed
    NativeHostProcesses=$nativeProcesses
    Audit=$audit
  }
}

switch($Mode){
  'Audit' {
    Get-Audit|ConvertTo-Json -Depth 10
  }
  'Validate' {
    $audit=Get-Audit
    [pscustomobject]@{
      Audit=$audit
      CleanState=Get-CleanStateChecks $audit
    }|ConvertTo-Json -Depth 10
  }
  'PrepareRebootValidation' {
    $baseline=Save-RebootBaseline
    [pscustomobject]@{
      Mode=$Mode
      BaselinePath=$RebootBaseline
      Baseline=$baseline
      NextStep='Reboot Windows, then run PostRebootValidate.'
    }|ConvertTo-Json -Depth 10
  }
  'PostRebootValidate' {
    Invoke-PostRebootValidation|ConvertTo-Json -Depth 12
  }
  'PostBrowserValidate' {
    Invoke-PostBrowserValidation|ConvertTo-Json -Depth 12
  }
  'CleanCache' {
    if($ConfirmToken -ne 'CLEAN'){throw 'Use -ConfirmToken CLEAN'}
    Stop-NativeHostOnly
    Save-ProtectedSnapshot
    $freed=Invoke-CacheClean
    [pscustomobject]@{
      Mode=$Mode
      Backup=$Backup
      FreedMB=$freed
      Validation=Get-Audit
    }|ConvertTo-Json -Depth 10
  }
  'UninstallCode' {
    if($ConfirmToken -ne 'UNINSTALL-CODE'){throw 'Use -ConfirmToken UNINSTALL-CODE'}
    Save-ProtectedSnapshot
    Invoke-UninstallCode
    [pscustomobject]@{
      Mode=$Mode
      Backup=$Backup
      Validation=Get-Audit
    }|ConvertTo-Json -Depth 10
  }
  'UninstallDesktop' {
    if($ConfirmToken -ne 'UNINSTALL-DESKTOP'){throw 'Use -ConfirmToken UNINSTALL-DESKTOP'}
    Save-ProtectedSnapshot
    Invoke-UninstallDesktop
    [pscustomobject]@{
      Mode=$Mode
      Backup=$Backup
      Validation=Get-Audit
    }|ConvertTo-Json -Depth 10
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
    $liveAudit=Get-Audit
    $liveChecks=Get-CleanStateChecks $liveAudit
    $baseline=Save-RebootBaseline
    [pscustomobject]@{
      Mode=$Mode
      Backup=$Backup
      FreedMB=$freed
      LiveValidation=$liveChecks
      RebootBaselinePath=$RebootBaseline
      FinalAcceptancePending=$true
      NextStep='Reboot Windows, run PostRebootValidate, then open Chrome and run PostBrowserValidate.'
    }|ConvertTo-Json -Depth 10
  }
}


