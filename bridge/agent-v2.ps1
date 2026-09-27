# REALLBLACK BRIDGE V2
$ErrorActionPreference = 'Continue'

$Version = '3.8.1'
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
$PublicRepo = 'realblackboss/reallblack-public-entrypoint'
$ManifestPath = 'bridge/manifest-v2.json'
$PublicAgentPath = 'bridge/agent-v2.ps1'
$ApiBase = 'https://api.github.com'

$script:BridgeMutex = New-Object System.Threading.Mutex($false, 'Local\REALLBLACK_BRIDGE_V2')
$script:BridgeMutexAcquired = $false
try {
  $script:BridgeMutexAcquired = $script:BridgeMutex.WaitOne(15000)
} catch [System.Threading.AbandonedMutexException] {
  $script:BridgeMutexAcquired = $true
}
if (-not $script:BridgeMutexAcquired) {
  try {
    New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
    Add-Content -Path $LogFile -Value ("[{0}] startup blocked: bridge mutex busy" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
  } catch {}
  exit
}

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

function Write-Health([int]$PollDelayMs, [bool]$Ready = $true, [string]$Phase = 'ready') {
  try {
    @{
      version = $Version
      pid = $PID
      pollDelayMs = $PollDelayMs
      ready = $Ready
      phase = $Phase
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
    $sinceIso = $Since.ToUniversalTime().ToString('o')
    $raw = (& gh api --paginate -X GET "repos/$Repo/issues/$Issue/comments" -f per_page=100 -f since=$sinceIso --slurp 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'github_poll_failed' }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    $pages = $raw | ConvertFrom-Json
    $all = @()
    foreach ($page in @($pages)) {
      foreach ($item in @($page)) { $all += $item }
    }
    return @($all)
  } catch {
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


function Ensure-RBInputNative {
  if ('RBInputNative' -as [type]) { return }
  Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class RBInputNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT {
    public UInt32 type;
    public InputUnion U;
  }

  [StructLayout(LayoutKind.Explicit)]
  public struct InputUnion {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
    [FieldOffset(0)] public HARDWAREINPUT hi;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSEINPUT {
    public Int32 dx;
    public Int32 dy;
    public UInt32 mouseData;
    public UInt32 dwFlags;
    public UInt32 time;
    public UIntPtr dwExtraInfo;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct KEYBDINPUT {
    public UInt16 wVk;
    public UInt16 wScan;
    public UInt32 dwFlags;
    public UInt32 time;
    public UIntPtr dwExtraInfo;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct HARDWAREINPUT {
    public UInt32 uMsg;
    public UInt16 wParamL;
    public UInt16 wParamH;
  }

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int X, int Y);

  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out POINT lpPoint);

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int X;
    public int Y;
  }

  [DllImport("user32.dll")]
  public static extern void mouse_event(UInt32 dwFlags, UInt32 dx, UInt32 dy, Int32 dwData, UIntPtr dwExtraInfo);

  [DllImport("user32.dll", SetLastError=true)]
  public static extern UInt32 SendInput(UInt32 nInputs, INPUT[] pInputs, Int32 cbSize);

  [DllImport("user32.dll")]
  public static extern void keybd_event(byte bVk, byte bScan, UInt32 dwFlags, UIntPtr dwExtraInfo);

  public const UInt32 INPUT_KEYBOARD = 1;
  public const UInt32 KEYEVENTF_KEYUP = 0x0002;
  public const UInt32 KEYEVENTF_UNICODE = 0x0004;

  public const UInt32 MOUSEEVENTF_LEFTDOWN = 0x0002;
  public const UInt32 MOUSEEVENTF_LEFTUP = 0x0004;
  public const UInt32 MOUSEEVENTF_RIGHTDOWN = 0x0008;
  public const UInt32 MOUSEEVENTF_RIGHTUP = 0x0010;
  public const UInt32 MOUSEEVENTF_MIDDLEDOWN = 0x0020;
  public const UInt32 MOUSEEVENTF_MIDDLEUP = 0x0040;
  public const UInt32 MOUSEEVENTF_WHEEL = 0x0800;

  public static bool TypeText(string text) {
    if (text == null) return false;
    foreach (char ch in text) {
      INPUT down = new INPUT();
      down.type = INPUT_KEYBOARD;
      down.U.ki = new KEYBDINPUT();
      down.U.ki.wScan = ch;
      down.U.ki.dwFlags = KEYEVENTF_UNICODE;

      INPUT up = down;
      up.U.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;

      INPUT[] pair = new INPUT[] { down, up };
      if (SendInput(2, pair, Marshal.SizeOf(typeof(INPUT))) != 2) return false;
    }
    return true;
  }

  public static void KeyTap(byte vk) {
    keybd_event(vk, 0, 0, UIntPtr.Zero);
    keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
  }

  public static void KeyCombo(byte modifier, byte key) {
    keybd_event(modifier, 0, 0, UIntPtr.Zero);
    keybd_event(key, 0, 0, UIntPtr.Zero);
    keybd_event(key, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    keybd_event(modifier, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
  }
}
'@
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



    'SCREENSHOT' {
      Add-Type -AssemblyName System.Windows.Forms
      Add-Type -AssemblyName System.Drawing

      $screens = @([System.Windows.Forms.Screen]::AllScreens)
      $screen = [System.Windows.Forms.Screen]::PrimaryScreen
      $screenIndex = [Array]::IndexOf($screens, $screen)

      $prop = $CmdArgs.PSObject.Properties['screenIndex']
      if ($null -ne $prop) {
        $requested = [int]$CmdArgs.screenIndex
        if ($requested -lt 0 -or $requested -ge $screens.Count) { throw 'screen_index_out_of_range' }
        $screen = $screens[$requested]
        $screenIndex = $requested
      }

      $bounds = $screen.Bounds
      $src = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
      $g = [System.Drawing.Graphics]::FromImage($src)
      try {
        $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)

        $targetWidth = [Math]::Min(720, $bounds.Width)
        $targetHeight = [Math]::Max(1, [int]([Math]::Round($bounds.Height * ($targetWidth / [double]$bounds.Width))))
        $dst = New-Object System.Drawing.Bitmap $targetWidth, $targetHeight
        $g2 = [System.Drawing.Graphics]::FromImage($dst)
        try {
          $g2.DrawImage($src, 0, 0, $targetWidth, $targetHeight)
          $ms = New-Object IO.MemoryStream
          try {
            $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
            $params = New-Object System.Drawing.Imaging.EncoderParameters 1
            $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]32)
            $dst.Save($ms, $codec, $params)
            $bytes = $ms.ToArray()
            if ($bytes.Length -gt 42000) { throw 'screenshot_too_large_for_transport' }
            return @{
              mime = 'image/jpeg'
              screenIndex = $screenIndex
              sourceX = $bounds.X
              sourceY = $bounds.Y
              sourceWidth = $bounds.Width
              sourceHeight = $bounds.Height
              width = $targetWidth
              height = $targetHeight
              bytes = $bytes.Length
              imageBase64 = [Convert]::ToBase64String($bytes)
            }
          } finally { $ms.Dispose() }
        } finally {
          $g2.Dispose()
          $dst.Dispose()
        }
      } finally {
        $g.Dispose()
        $src.Dispose()
      }
    }

    'FOREGROUND_WINDOW' {
      if (-not ('RBForegroundNative' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class RBForegroundNative {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
}
'@
      }

      $h = [RBForegroundNative]::GetForegroundWindow()
      $pidValue = [uint32]0
      [RBForegroundNative]::GetWindowThreadProcessId($h,[ref]$pidValue) | Out-Null
      $sb = New-Object Text.StringBuilder 1024
      [RBForegroundNative]::GetWindowText($h,$sb,$sb.Capacity) | Out-Null
      $processName = ''
      try { $processName = (Get-Process -Id ([int]$pidValue) -ErrorAction Stop).ProcessName } catch {}
      return @{ pid=[int]$pidValue; process=$processName; title=$sb.ToString(); handle=[string]$h }
    }

    'WINDOWS_LIST' {
      $items = @(Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
      } | ForEach-Object {
        [ordered]@{
          pid = $_.Id
          process = $_.ProcessName
          title = $_.MainWindowTitle
          handle = [string]$_.MainWindowHandle
        }
      } | Select-Object -First 100)
      return @{ windows = @($items) }
    }

    'WINDOW_ACTIVATE' {
      $pidTarget = [int]$CmdArgs.pid
      $p = Get-Process -Id $pidTarget -ErrorAction Stop
      if ($p.MainWindowHandle -eq 0) { throw 'window_not_found' }

      if (-not ('RBWindowNative' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RBWindowNative {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@
      }

      [RBWindowNative]::ShowWindowAsync($p.MainWindowHandle, 9) | Out-Null
      Start-Sleep -Milliseconds 120
      $ok = [RBWindowNative]::SetForegroundWindow($p.MainWindowHandle)
      return @{ pid=$pidTarget; title=$p.MainWindowTitle; activated=[bool]$ok }
    }

    'WINDOW_MOVE' {
      $pidTarget = [int]$CmdArgs.pid
      $x = [int]$CmdArgs.x
      $y = [int]$CmdArgs.y
      $width = [int]$CmdArgs.width
      $height = [int]$CmdArgs.height
      if ($width -lt 100 -or $height -lt 100 -or $width -gt 10000 -or $height -gt 10000) { throw 'invalid_window_size' }

      $p = Get-Process -Id $pidTarget -ErrorAction Stop
      if ($p.MainWindowHandle -eq 0) { throw 'window_not_found' }

      if (-not ('RBWindowMoveNative' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RBWindowMoveNative {
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool repaint);
}
'@
      }

      $ok = [RBWindowMoveNative]::MoveWindow($p.MainWindowHandle, $x, $y, $width, $height, $true)
      return @{ pid=$pidTarget; moved=[bool]$ok; x=$x; y=$y; width=$width; height=$height }
    }


    'CLIPBOARD_GET' {
      $text = ''
      try { $text = [string](Get-Clipboard -Raw -ErrorAction Stop) } catch { $text = '' }
      if ($text.Length -gt 32768) { $text = $text.Substring(0,32768) }
      return @{ text=$text; length=$text.Length }
    }

    'CLIPBOARD_SET' {
      $text = [string]$CmdArgs.text
      if ($text.Length -gt 32768) { throw 'clipboard_too_large' }
      Set-Clipboard -Value $text
      return @{ set=$true; length=$text.Length }
    }

    'OPEN_APP' {
      $app = ([string]$CmdArgs.app).ToLowerInvariant()
      $target = $null
      $arguments = @()

      switch ($app) {
        'notepad' { $target = 'notepad.exe' }
        'calculator' { $target = 'calc.exe' }
        'paint' { $target = 'mspaint.exe' }
        'explorer' { $target = 'explorer.exe' }
        'taskmgr' { $target = 'taskmgr.exe' }
        'cmd' { $target = 'cmd.exe' }
        'powershell' { $target = 'powershell.exe'; $arguments = @('-NoExit') }
        'edge' { $target = 'msedge.exe' }
        'obs' {
          $candidates = @(
            'C:\Program Files\obs-studio\bin\64bit\obs64.exe',
            'C:\Program Files (x86)\obs-studio\bin\64bit\obs64.exe'
          )
          $target = $candidates | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
        }
        'opera' {
          $candidates = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Opera\opera.exe'),
            'C:\Program Files\Opera\opera.exe',
            'C:\Program Files (x86)\Opera\opera.exe'
          )
          $target = $candidates | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
        }
        default { throw 'app_not_allowed' }
      }

      if ([string]::IsNullOrWhiteSpace([string]$target)) { throw 'app_not_found' }
      $p = Start-Process -FilePath $target -ArgumentList $arguments -PassThru
      return @{ app=$app; pid=$p.Id; started=$true }
    }

    'RUN_DIAGNOSTIC' {
      $tool = ([string]$CmdArgs.tool).ToLowerInvariant()
      $exe = $null
      $args = @()

      switch ($tool) {
        'whoami' { $exe='whoami.exe' }
        'ipconfig' { $exe='ipconfig.exe'; $args=@('/all') }
        'tasklist' { $exe='tasklist.exe' }
        'powercfg-active' { $exe='powercfg.exe'; $args=@('/getactivescheme') }
        'driverquery' { $exe='driverquery.exe'; $args=@('/FO','CSV') }
        'netstat' { $exe='netstat.exe'; $args=@('-ano') }
        'nvidia-smi' { $exe='nvidia-smi.exe' }
        'winget-list' { $exe='winget.exe'; $args=@('list','--disable-interactivity') }
        default { throw 'diagnostic_not_allowed' }
      }

      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = $exe
      $psi.Arguments = ($args -join ' ')
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.CreateNoWindow = $true

      $p = New-Object Diagnostics.Process
      $p.StartInfo = $psi
      if (-not $p.Start()) { throw 'diagnostic_start_failed' }
      if (-not $p.WaitForExit(15000)) {
        try { $p.Kill() } catch {}
        throw 'diagnostic_timeout'
      }

      $stdout = $p.StandardOutput.ReadToEnd()
      $stderr = $p.StandardError.ReadToEnd()
      if ($stdout.Length -gt 24000) { $stdout = $stdout.Substring(0,24000) }
      if ($stderr.Length -gt 8000) { $stderr = $stderr.Substring(0,8000) }
      return @{ tool=$tool; exitCode=$p.ExitCode; stdout=$stdout; stderr=$stderr }
    }


    'MOUSE_POSITION' {
      Ensure-RBInputNative
      $pt = New-Object RBInputNative+POINT
      [RBInputNative]::GetCursorPos([ref]$pt) | Out-Null
      return @{ x=$pt.X; y=$pt.Y }
    }

    'MOUSE_MOVE' {
      Ensure-RBInputNative
      $x = [int]$CmdArgs.x
      $y = [int]$CmdArgs.y
      if ($x -lt -10000 -or $x -gt 20000 -or $y -lt -10000 -or $y -gt 20000) { throw 'invalid_coordinates' }
      $ok = [RBInputNative]::SetCursorPos($x,$y)
      return @{ moved=[bool]$ok; x=$x; y=$y }
    }

    'MOUSE_CLICK' {
      Ensure-RBInputNative
      $button = ([string]$CmdArgs.button).ToLowerInvariant()
      $clicks = [int]$CmdArgs.clicks
      if ($clicks -lt 1) { $clicks = 1 }
      if ($clicks -gt 2) { throw 'too_many_clicks' }

      switch ($button) {
        'left' { $down=[RBInputNative]::MOUSEEVENTF_LEFTDOWN; $up=[RBInputNative]::MOUSEEVENTF_LEFTUP }
        'right' { $down=[RBInputNative]::MOUSEEVENTF_RIGHTDOWN; $up=[RBInputNative]::MOUSEEVENTF_RIGHTUP }
        'middle' { $down=[RBInputNative]::MOUSEEVENTF_MIDDLEDOWN; $up=[RBInputNative]::MOUSEEVENTF_MIDDLEUP }
        default { throw 'mouse_button_not_allowed' }
      }

      for ($i=0; $i -lt $clicks; $i++) {
        [RBInputNative]::mouse_event($down,0,0,0,[UIntPtr]::Zero)
        [RBInputNative]::mouse_event($up,0,0,0,[UIntPtr]::Zero)
        if ($clicks -gt 1) { Start-Sleep -Milliseconds 90 }
      }
      return @{ clicked=$true; button=$button; clicks=$clicks }
    }

    'MOUSE_SCROLL' {
      Ensure-RBInputNative
      $lines = [int]$CmdArgs.lines
      if ($lines -lt -10 -or $lines -gt 10) { throw 'scroll_out_of_range' }
      [RBInputNative]::mouse_event([RBInputNative]::MOUSEEVENTF_WHEEL,0,0,($lines * 120),[UIntPtr]::Zero)
      return @{ scrolled=$true; lines=$lines }
    }

    'TYPE_TEXT' {
      Ensure-RBInputNative
      $text = [string]$CmdArgs.text
      if ($text.Length -gt 2000) { throw 'text_too_large' }
      $ok = [RBInputNative]::TypeText($text)
      return @{ typed=[bool]$ok; length=$text.Length }
    }

    'KEY_PRESS' {
      Ensure-RBInputNative
      $key = ([string]$CmdArgs.key).ToUpperInvariant()
      $map = @{
        'BACKSPACE'=0x08; 'TAB'=0x09; 'ENTER'=0x0D; 'ESC'=0x1B; 'SPACE'=0x20
        'PGUP'=0x21; 'PGDN'=0x22; 'END'=0x23; 'HOME'=0x24
        'LEFT'=0x25; 'UP'=0x26; 'RIGHT'=0x27; 'DOWN'=0x28
        'DELETE'=0x2E
        'F1'=0x70; 'F2'=0x71; 'F3'=0x72; 'F4'=0x73; 'F5'=0x74; 'F6'=0x75
        'F7'=0x76; 'F8'=0x77; 'F9'=0x78; 'F10'=0x79; 'F11'=0x7A; 'F12'=0x7B
      }
      if (-not $map.ContainsKey($key)) { throw 'key_not_allowed' }
      [RBInputNative]::KeyTap([byte]$map[$key])
      return @{ pressed=$true; key=$key }
    }

    'KEY_COMBO' {
      Ensure-RBInputNative
      $combo = ([string]$CmdArgs.combo).ToUpperInvariant()
      switch ($combo) {
        'CTRL+A' { $mod=0x11; $key=0x41 }
        'CTRL+C' { $mod=0x11; $key=0x43 }
        'CTRL+V' { $mod=0x11; $key=0x56 }
        'CTRL+X' { $mod=0x11; $key=0x58 }
        'CTRL+Z' { $mod=0x11; $key=0x5A }
        'CTRL+L' { $mod=0x11; $key=0x4C }
        'CTRL+S' { $mod=0x11; $key=0x53 }
        'ALT+TAB' { $mod=0x12; $key=0x09 }
        'WIN+D' { $mod=0x5B; $key=0x44 }
        default { throw 'combo_not_allowed' }
      }
      [RBInputNative]::KeyCombo([byte]$mod,[byte]$key)
      return @{ pressed=$true; combo=$combo }
    }


    'CAPABILITIES' {
      return @{
        version = $Version
        transport = 'github-cli-paginated'
        safety = @('allowlist','sha256','syntax-parse','health-check','last-good-backup','watchdog-rollback')
        operations = @(
          'PING','BRIDGE_INFO','SYSINFO','SELF_UPDATE','RESTART_AGENT',
          'MKDIR','EXISTS','LIST','READ_TEXT','WRITE_TEXT','APPEND_TEXT','MOVE','COPY',
          'PROC_LIST','PROC_STOP',
          'SCREENSHOT','SCREENS_LIST','FOREGROUND_WINDOW',
          'WINDOWS_LIST','WINDOW_ACTIVATE','WINDOW_MOVE','WINDOW_STATE',
          'CLIPBOARD_GET','CLIPBOARD_SET',
          'OPEN_APP','RUN_DIAGNOSTIC',
          'MOUSE_POSITION','MOUSE_MOVE','MOUSE_CLICK','MOUSE_SCROLL',
          'TYPE_TEXT','KEY_PRESS','KEY_COMBO',
          'FILE_INFO','FILE_HASH',
          'KEYBOARD_DIAG','KBD_DEEP_AUDIT','FIX_QUESTION_KEY'
        )
      }
    }

    'SCREENS_LIST' {
      Add-Type -AssemblyName System.Windows.Forms
      $screens = @()
      $index = 0
      foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $screens += [ordered]@{
          index = $index
          deviceName = $s.DeviceName
          primary = $s.Primary
          x = $s.Bounds.X
          y = $s.Bounds.Y
          width = $s.Bounds.Width
          height = $s.Bounds.Height
          workingX = $s.WorkingArea.X
          workingY = $s.WorkingArea.Y
          workingWidth = $s.WorkingArea.Width
          workingHeight = $s.WorkingArea.Height
        }
        $index++
      }
      return @{ screens=@($screens); count=$screens.Count }
    }

    'WINDOW_STATE' {
      $pidTarget = [int]$CmdArgs.pid
      $state = ([string]$CmdArgs.state).ToLowerInvariant()
      $p = Get-Process -Id $pidTarget -ErrorAction Stop
      if ($p.MainWindowHandle -eq 0) { throw 'window_not_found' }

      if (-not ('RBWindowStateNative' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RBWindowStateNative {
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@
      }

      switch ($state) {
        'minimize' { $code=6 }
        'maximize' { $code=3 }
        'restore' { $code=9 }
        default { throw 'window_state_not_allowed' }
      }

      $ok = [RBWindowStateNative]::ShowWindowAsync($p.MainWindowHandle,$code)
      return @{ pid=$pidTarget; state=$state; changed=[bool]$ok }
    }

    'FILE_INFO' {
      $p = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.path)
      if (-not (Test-Path $p)) { throw 'file_not_found' }
      $i = Get-Item -LiteralPath $p -Force
      return @{
        path=$p
        name=$i.Name
        isDirectory=[bool]$i.PSIsContainer
        length=if ($i.PSIsContainer) { $null } else { $i.Length }
        created=$i.CreationTime.ToString('o')
        modified=$i.LastWriteTime.ToString('o')
        attributes=[string]$i.Attributes
      }
    }

    'FILE_HASH' {
      $p = Resolve-SafePath ([string]$CmdArgs.root) ([string]$CmdArgs.path)
      if (-not (Test-Path $p -PathType Leaf)) { throw 'file_not_found' }
      $i = Get-Item -LiteralPath $p
      if ($i.Length -gt 1073741824) { throw 'file_too_large_for_hash' }
      $h = Get-FileHash -LiteralPath $p -Algorithm SHA256
      return @{ path=$p; sha256=$h.Hash.ToLowerInvariant(); length=$i.Length }
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


function Get-PublicRepoRawHeaders {
  $h = @{}
  foreach ($k in $script:GitHubHeaders.Keys) { $h[$k] = $script:GitHubHeaders[$k] }
  $h['Accept'] = 'application/vnd.github.raw+json'
  return $h
}

function Get-PublicRepoFileText([string]$Path) {
  $uri = $ApiBase + '/repos/' + $PublicRepo + '/contents/' + $Path + '?ref=main'
  $r = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $uri -Headers (Get-PublicRepoRawHeaders) -TimeoutSec 20
  $raw = $r.Content
  if ($raw -is [byte[]]) {
    return [Text.Encoding]::UTF8.GetString($raw)
  }
  return [string]$raw
}

function Download-PublicRepoFile([string]$Path, [string]$Destination) {
  $uri = $ApiBase + '/repos/' + $PublicRepo + '/contents/' + $Path + '?ref=main'
  Invoke-WebRequest -UseBasicParsing -Method Get -Uri $uri -Headers (Get-PublicRepoRawHeaders) -OutFile $Destination -TimeoutSec 25
}

function Check-SelfUpdate {
  try {
    $manifestText = Get-PublicRepoFileText $ManifestPath
    if ([string]::IsNullOrWhiteSpace($manifestText)) { throw 'manifest_empty' }
    $manifest = $manifestText | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace([string]$manifest.sha256)) {
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
    Download-PublicRepoFile $PublicAgentPath $tmp

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
Write-Health 1000 $false 'bootstrap'
Initialize-GitHubApi
Write-Health 1000 $false 'github-authenticated'
Ensure-Watchdog
Write-Health 1000 $false 'watchdog-ready'

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
Write-Health 1000 $true 'ready'
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
    Write-Health $pollDelayMs $true 'ready'
    $lastHealthWrite = Get-Date
  }

  if (((Get-Date) - $lastUpdateCheck).TotalMinutes -ge 2) {
    Check-SelfUpdate
    $lastUpdateCheck = Get-Date
  }

  Start-Sleep -Milliseconds $pollDelayMs
}
# manifest-trigger-v35
# final-validation-trigger-v38
# endpoint-validation-trigger
# installer-health-validation-trigger
# publish-v381-manifest
