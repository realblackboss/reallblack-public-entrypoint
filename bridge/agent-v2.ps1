# REALLBLACK BRIDGE V2
$ErrorActionPreference = 'Continue'

$Version = '2.7.0'
$Repo = 'realblackboss/twitch-gpt-gemini-2026'
$Issue = 1
$Trusted = 'realblackboss'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$StateFile = Join-Path $BaseDir 'state-v2.json'
$LogFile = Join-Path $BaseDir 'bridge-v2.log'
$AgentFile = Join-Path $BaseDir 'agent-v2.ps1'
$HealthFile = Join-Path $BaseDir 'health-v2.json'
$WatchdogFile = Join-Path $BaseDir 'watchdog-v2.ps1'
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
$HealthFile = Join-Path $BaseDir 'health-v2.json'
$mutex = New-Object System.Threading.Mutex($false, 'Local\REALLBLACK_BRIDGE_WATCHDOG_V2')
if (-not $mutex.WaitOne(0)) { exit }

while ($true) {
  $restart = $false
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*ReallBlackBridge*agent-v2.ps1*' })

  if ($procs.Count -eq 0) {
    $restart = $true
  } elseif (Test-Path $HealthFile) {
    try {
      $age = ((Get-Date) - (Get-Item $HealthFile).LastWriteTime).TotalSeconds
      if ($age -gt 60) {
        foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force } catch {} }
        $restart = $true
      }
    } catch {}
  }

  if ($restart -and (Test-Path $AgentFile)) {
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$AgentFile) -WindowStyle Hidden
  }

  Start-Sleep -Seconds 15
}
'@

    Set-Content -Path $WatchdogFile -Value $watchdogCode -Encoding UTF8
    $startup = [Environment]::GetFolderPath('Startup')
    $launch = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $WatchdogFile + '"'
    Set-Content -Path (Join-Path $startup 'REALLBLACK-BRIDGE-WATCHDOG.cmd') -Value ('@echo off' + [Environment]::NewLine + $launch) -Encoding ASCII

    $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -like '*ReallBlackBridge*watchdog-v2.ps1*' })
    if ($existing.Count -eq 0) {
      Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$WatchdogFile) -WindowStyle Hidden
    }
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
  $sinceIso = [uri]::EscapeDataString($Since.ToUniversalTime().ToString('o'))
  $uri = "$ApiBase/repos/$Repo/issues/$Issue/comments?per_page=100&since=$sinceIso"

  $headers = @{}
  foreach ($key in $script:GitHubHeaders.Keys) { $headers[$key] = $script:GitHubHeaders[$key] }
  if (-not [string]::IsNullOrWhiteSpace([string]$script:CommentsEtag)) {
    $headers['If-None-Match'] = $script:CommentsEtag
  }

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $uri -Headers $headers -TimeoutSec 15
    $etag = [string]$response.Headers['ETag']
    if (-not [string]::IsNullOrWhiteSpace($etag)) { $script:CommentsEtag = $etag }
    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) { return @() }
    return @($response.Content | ConvertFrom-Json)
  } catch {
    $status = 0
    try { $status = [int]$_.Exception.Response.StatusCode } catch {}
    if ($status -eq 304) { return @() }
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

    default {
      throw 'operation_not_allowed'
    }
  }
}

function Check-SelfUpdate {
  try {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $manifest = Invoke-RestMethod -UseBasicParsing -Uri ($ManifestUrl + '?t=' + $stamp) -TimeoutSec 15
    if ([string]$manifest.version -eq $Version) { return }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.url) -or [string]::IsNullOrWhiteSpace([string]$manifest.sha256)) {
      throw 'invalid_update_manifest'
    }

    $tmp = Join-Path $BaseDir 'agent-v2.new.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri ([string]$manifest.url) -OutFile $tmp -TimeoutSec 20
    $newHash = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = ([string]$manifest.sha256).ToLowerInvariant()
    if ($newHash -ne $expectedHash) {
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
      throw 'update_hash_mismatch'
    }

    Move-Item $tmp $AgentFile -Force
    Write-Log ('Self-update verificado: ' + [string]$manifest.version)
    try { $script:BridgeMutex.ReleaseMutex() } catch {}
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$AgentFile) -WindowStyle Hidden
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

$lastUpdateCheck = Get-Date
$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-10)
$pollDelayMs = 4000
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

    if ((Get-Date) -lt $activeUntil) { $pollDelayMs = 1000 } else { $pollDelayMs = 4000 }
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
