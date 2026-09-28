# REALLBLACK BRIDGE SAFE V4
$ErrorActionPreference = 'Continue'

$Version = '4.2.9'
$Repo = 'realblackboss/twitch-gpt-gemini-2026'
$Issue = 1
$Trusted = 'realblackboss'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$StateFile = Join-Path $BaseDir 'state-v4.json'
$HealthFile = Join-Path $BaseDir 'health-v4.json'
$LogFile = Join-Path $BaseDir 'bridge-v4.log'
$HeartbeatIdFile = Join-Path $BaseDir 'heartbeat-comment-id.txt'
$HeartbeatSeconds = 60
$PollSecondsNormal = 2
$PollSecondsGame = 5

$ReadRoots = @{
  desktop = [Environment]::GetFolderPath('Desktop')
  documents = [Environment]::GetFolderPath('MyDocuments')
  downloads = Join-Path $env:USERPROFILE 'Downloads'
  bridge = $BaseDir
}

$Capabilities = @(
  'PING','BRIDGE_INFO','CAPABILITIES','SYSINFO',
  'PROC_LIST','WINDOWS_LIST','SERVICE_LIST',
  'FILE_INFO','LIST','READ_TEXT','SCREEN_INFO','BRIDGE_DIAG','RESOURCE_SNAPSHOT','APP_STATUS','UPDATE_CHECK',
  'OBS_STATUS','OBS_KICK_TUNE'
)

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
try { (Get-Process -Id $PID -ErrorAction Stop).PriorityClass = 'BelowNormal' } catch {}

$script:BridgeMutex = New-Object System.Threading.Mutex($false, 'Local\REALLBLACK_BRIDGE_SAFE_V4')
$acquired = $false
try {
  $acquired = $script:BridgeMutex.WaitOne(3000)
} catch {
  try { $acquired = $script:BridgeMutex.WaitOne(0) } catch {}
}
if (-not $acquired) { exit }

function Write-Log([string]$Message) {
  try {
    Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message)
    $item = Get-Item $LogFile -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt 1048576) {
      Move-Item $LogFile ($LogFile + '.1') -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}

function Encode-Json($Object) {
  $json = $Object | ConvertTo-Json -Compress -Depth 6
  [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
}

function Decode-Json([string]$Base64) {
  if ([string]::IsNullOrWhiteSpace($Base64)) { return [pscustomobject]@{} }
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
  $json | ConvertFrom-Json
}

function Post-Comment([string]$Body) {
  try {
    $null = & gh api -X POST ("repos/{0}/issues/{1}/comments" -f $Repo,$Issue) -f ("body={0}" -f $Body) 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'github_post_failed' }
    return $true
  } catch {
    Write-Log ('Post falhou: ' + $_.Exception.Message)
    return $false
  }
}

function Update-Heartbeat {
  try {
    $payload = [ordered]@{
      status = 'online'
      version = $Version
      pid = $PID
      machine = $env:COMPUTERNAME
      mode = 'safe-limited-control'
      pollErrors = $script:PollErrorCount
      lastPollOk = if ($script:LastPollOk) { $script:LastPollOk.ToString('o') } else { $null }
      timestamp = (Get-Date).ToString('o')
      intervalSeconds = $HeartbeatSeconds
    }
    $body = 'RB2_HEARTBEAT' + [Environment]::NewLine + (Encode-Json $payload)
    [long]$commentId = 0
    if (Test-Path $HeartbeatIdFile -PathType Leaf) {
      try { $commentId = [long](Get-Content $HeartbeatIdFile -Raw).Trim() } catch {}
    }
    if ($commentId -gt 0) {
      $null = & gh api -X PATCH ("repos/{0}/issues/comments/{1}" -f $Repo,$commentId) -f ("body={0}" -f $body) 2>$null
      if ($LASTEXITCODE -eq 0) { return $true }
    }
    $newId = & gh api -X POST ("repos/{0}/issues/{1}/comments" -f $Repo,$Issue) -f ("body={0}" -f $body) --jq '.id' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$newId)) { throw 'heartbeat_post_failed' }
    Set-Content -Path $HeartbeatIdFile -Value ([string]$newId).Trim() -Encoding ASCII
    return $true
  } catch {
    Write-Log ('Heartbeat falhou: ' + $_.Exception.Message)
    return $false
  }
}

function Reply([string]$Id, [bool]$Ok, $Data, [string]$ErrorText) {
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

function Get-State {
  if (Test-Path $StateFile -PathType Leaf) {
    try { return (Get-Content $StateFile -Raw | ConvertFrom-Json) } catch {}
  }
  [pscustomobject]@{ lastCommentId = 0 }
}

function Save-State([long]$Id) {
  @{ lastCommentId = $Id } | ConvertTo-Json -Compress | Set-Content -Path $StateFile -Encoding UTF8
}

function Get-MaxCommentId {
  try {
    $raw = (& gh api --paginate ("repos/{0}/issues/{1}/comments?per_page=100" -f $Repo,$Issue) --slurp 2>$null) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return [long]0 }
    $pages = $raw | ConvertFrom-Json
    [long]$max = 0
    foreach ($page in @($pages)) {
      foreach ($c in @($page)) {
        try {
          [long]$id = [long]$c.id
          if ($id -gt $max) { $max = $id }
        } catch {}
      }
    }
    return $max
  } catch {
    Write-Log ('Get-MaxCommentId falhou: ' + $_.Exception.Message)
    return [long]0
  }
}

function Poll-Comments([datetime]$Since) {
  $sinceIso = [uri]::EscapeDataString($Since.ToUniversalTime().ToString('o'))
  $endpoint = "repos/$Repo/issues/$Issue/comments?per_page=100&since=$sinceIso"
  $raw = (& gh api --paginate $endpoint --slurp 2>$null) -join [Environment]::NewLine
  if ($LASTEXITCODE -ne 0) { throw 'github_poll_failed' }
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

  $pages = $raw | ConvertFrom-Json
  $items = @()
  foreach ($page in @($pages)) {
    foreach ($c in @($page)) { $items += $c }
  }
  return @($items)
}

function Write-Health {
  try {
    [ordered]@{
      status = 'online'
      version = $Version
      pid = $PID
      machine = $env:COMPUTERNAME
      mode = 'safe-limited-control'
      timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -Path $HealthFile -Encoding UTF8
  } catch {}
}

function Resolve-ReadPath([string]$RootName, [string]$RelativePath) {
  if ([string]::IsNullOrWhiteSpace($RootName)) { throw 'root_required' }
  $key = $RootName.ToLowerInvariant()
  if (-not $ReadRoots.ContainsKey($key)) { throw 'root_not_allowed' }

  $root = [IO.Path]::GetFullPath([string]$ReadRoots[$key]).TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $root }
  if ([IO.Path]::IsPathRooted($RelativePath)) { throw 'absolute_path_not_allowed' }

  $full = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
  if ($full -ne $root -and -not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'path_escape_blocked'
  }
  return $full
}

function Get-ArgString($ArgsObject, [string]$Name, [string]$DefaultValue = '') {
  try {
    if ($null -ne $ArgsObject -and $ArgsObject.PSObject.Properties[$Name]) {
      return [string]$ArgsObject.$Name
    }
  } catch {}
  return $DefaultValue
}

function Get-ArgInt($ArgsObject, [string]$Name, [int]$DefaultValue) {
  try {
    if ($null -ne $ArgsObject -and $ArgsObject.PSObject.Properties[$Name]) {
      return [int]$ArgsObject.$Name
    }
  } catch {}
  return $DefaultValue
}

function Get-ArgBool($ArgsObject, [string]$Name, [bool]$DefaultValue) {
  try {
    if ($null -ne $ArgsObject -and $ArgsObject.PSObject.Properties[$Name]) {
      return [bool]$ArgsObject.$Name
    }
  } catch {}
  return $DefaultValue
}

function Get-ScreenInfo {
  Add-Type -AssemblyName System.Windows.Forms
  $items = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
    [ordered]@{
      device = $_.DeviceName
      primary = $_.Primary
      x = $_.Bounds.X
      y = $_.Bounds.Y
      width = $_.Bounds.Width
      height = $_.Bounds.Height
      workingX = $_.WorkingArea.X
      workingY = $_.WorkingArea.Y
      workingWidth = $_.WorkingArea.Width
      workingHeight = $_.WorkingArea.Height
    }
  })
  return @{ screens=$items; count=$items.Count }
}

function Get-BridgeDiag {
  $startupFile = Join-Path ([Environment]::GetFolderPath('Startup')) 'REALLBLACK-PC-BRIDGE-SAFE-V4.cmd'
  $desktopLauncher = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LIGAR PONTE - REALLBLACK.cmd'
  $screenHelper = Join-Path $BaseDir 'ScreenHelper\screen-helper.ps1'
  $fileHelper = Join-Path $BaseDir 'FileHelper\file-helper.ps1'

  $taskState = 'missing'
  try {
    $task = Get-ScheduledTask -TaskName 'REALLBLACK-PC-BRIDGE-SAFE-V4' -ErrorAction Stop
    $taskState = [string]$task.State
  } catch {}

  $healthAgeSeconds = $null
  try {
    if (Test-Path $HealthFile -PathType Leaf) {
      $h = Get-Content $HealthFile -Raw | ConvertFrom-Json
      $healthAgeSeconds = [Math]::Round(((Get-Date) - ([datetime]$h.timestamp)).TotalSeconds,1)
    }
  } catch {}

  $ghPresent = [bool](Get-Command gh -ErrorAction SilentlyContinue)
  $ghAuthenticated = $false
  if ($ghPresent) {
    try {
      $null = & gh auth status -h github.com 2>$null
      $ghAuthenticated = ($LASTEXITCODE -eq 0)
    } catch {}
  }

  return [ordered]@{
    version = $Version
    pid = $PID
    machine = $env:COMPUTERNAME
    mode = 'safe-limited-control'
    heartbeatSeconds = $HeartbeatSeconds
    healthAgeSeconds = $healthAgeSeconds
    scheduledTask = $taskState
    startupLauncher = (Test-Path $startupFile -PathType Leaf)
    desktopLauncher = (Test-Path $desktopLauncher -PathType Leaf)
    heartbeatCommentIdFile = (Test-Path $HeartbeatIdFile -PathType Leaf)
    githubCli = $ghPresent
    githubAuthenticated = $ghAuthenticated
    screenHelperInstalled = (Test-Path $screenHelper -PathType Leaf)
    fileHelperInstalled = (Test-Path $fileHelper -PathType Leaf)
  }
}

function Get-ResourceSnapshot {
  $cpu = $null
  try {
    $vals = @(Get-CimInstance Win32_Processor | ForEach-Object { [double]$_.LoadPercentage })
    if ($vals.Count -gt 0) { $cpu = [Math]::Round((($vals | Measure-Object -Average).Average),1) }
  } catch {}

  $memory = $null
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $free = [double]$os.FreePhysicalMemory * 1KB
    $memory = [ordered]@{
      totalGB = [Math]::Round($total / 1GB,2)
      usedGB = [Math]::Round(($total-$free) / 1GB,2)
      freeGB = [Math]::Round($free / 1GB,2)
      usedPercent = if ($total -gt 0) { [Math]::Round((($total-$free)/$total)*100,1) } else { $null }
    }
  } catch {}

  $disks = @()
  try {
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID | ForEach-Object {
      [ordered]@{
        drive = $_.DeviceID
        sizeGB = if ($_.Size) { [Math]::Round([double]$_.Size/1GB,1) } else { $null }
        freeGB = if ($_.FreeSpace) { [Math]::Round([double]$_.FreeSpace/1GB,1) } else { 0 }
        freePercent = if ($_.Size) { [Math]::Round(([double]$_.FreeSpace/[double]$_.Size)*100,1) } else { $null }
      }
    })
  } catch {}

  $gpu = $null
  try {
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($smi) {
      $line = & $smi.Source '--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
      if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
        $p = @(([string]$line).Split(',') | ForEach-Object { $_.Trim() })
        if ($p.Count -ge 5) {
          $gpu = [ordered]@{ name=$p[0]; utilizationPercent=[double]$p[1]; memoryUsedMB=[double]$p[2]; memoryTotalMB=[double]$p[3]; temperatureC=[double]$p[4] }
        }
      }
    }
  } catch {}

  return [ordered]@{ cpuPercent=$cpu; memory=$memory; disks=$disks; gpu=$gpu; timestamp=(Get-Date).ToString('o') }
}

function Get-AppStatus {
  $groups = [ordered]@{
    lol = @('LeagueClient','LeagueClientUx','LeagueClientUxRender','League of Legends')
    obs = @('obs64')
    discord = @('Discord')
    opera = @('opera')
    chatgpt = @('ChatGPT')
  }
  $all = @(Get-Process -ErrorAction SilentlyContinue)
  $result = [ordered]@{}
  foreach ($key in $groups.Keys) {
    $names = @($groups[$key])
    $matches = @($all | Where-Object { $names -contains $_.ProcessName })
    $result[$key] = [ordered]@{
      running = ($matches.Count -gt 0)
      count = $matches.Count
      pids = @($matches | ForEach-Object { $_.Id })
      memoryMB = [Math]::Round((($matches | Measure-Object WorkingSet64 -Sum).Sum / 1MB),1)
    }
  }
  return $result
}

function Get-UpdateCheck {
  try {
    $uri = 'https://raw.githubusercontent.com/realblackboss/reallblack-public-entrypoint/main/bridge/manifest-v2.json?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $m = Invoke-RestMethod -UseBasicParsing -Uri $uri -TimeoutSec 15
    $latest = [string]$m.version
    return [ordered]@{
      installed = $Version
      latest = $latest
      updateAvailable = (-not [string]::IsNullOrWhiteSpace($latest) -and $latest -ne $Version)
      sha256 = [string]$m.sha256
      checkedAt = (Get-Date).ToString('o')
    }
  } catch {
    return [ordered]@{ installed=$Version; latest=$null; updateAvailable=$null; error=$_.Exception.Message; checkedAt=(Get-Date).ToString('o') }
  }
}


function Get-IniValue([string]$Path, [string]$Section, [string]$Key) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $inSection = $false
  foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
    $trim = ([string]$line).Trim()
    if ($trim -match '^\[(.+)\]
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $disks = @(
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
      [ordered]@{
        drive = $_.DeviceID
        sizeGB = if ($_.Size) { [Math]::Round($_.Size / 1GB, 1) } else { $null }
        freeGB = if ($_.FreeSpace) { [Math]::Round($_.FreeSpace / 1GB, 1) } else { $null }
      }
    }
  )
  [ordered]@{
    computer = $env:COMPUTERNAME
    user = $env:USERNAME
    os = $os.Caption
    cpu = $cpu.Name
    memoryGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    freeMemoryGB = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
    disks = $disks
  }
}

function Invoke-AllowedOperation([string]$Op, $CmdArgs) {
  switch ($Op.ToUpperInvariant()) {
    'PING' {
      return @{ pong = $true; mode = 'safe-limited-control' }
    }
    'BRIDGE_INFO' {
      return @{
        version = $Version
        pid = $PID
        mode = 'safe-limited-control'
        roots = @($ReadRoots.Keys | Sort-Object)
        capabilities = @($Capabilities)
        heartbeatSeconds = $HeartbeatSeconds
        transport = 'github-comments'
        processPriority = 'BelowNormal'
        pollSecondsNormal = $PollSecondsNormal
        pollSecondsGame = $PollSecondsGame
      }
    }
    'CAPABILITIES' {
      return @{ mode='safe-limited-control'; roots=@($ReadRoots.Keys | Sort-Object); capabilities=@($Capabilities) }
    }
    'SYSINFO' {
      return Get-SystemInfo
    }
    'PROC_LIST' {
      $max = Get-ArgInt $CmdArgs 'max' 100
      $max = [Math]::Max(1,[Math]::Min($max,200))
      $items = @(Get-Process | Sort-Object CPU -Descending | Select-Object -First $max | ForEach-Object {
        $started = $null
        try { $started = $_.StartTime.ToString('o') } catch {}
        [ordered]@{
          pid = $_.Id
          name = $_.ProcessName
          cpu = if ($null -eq $_.CPU) { 0 } else { [Math]::Round([double]$_.CPU,1) }
          memoryMB = [Math]::Round($_.WorkingSet64 / 1MB,1)
          started = $started
        }
      })
      return @{ processes=$items; count=$items.Count }
    }
    'WINDOWS_LIST' {
      $items = @(Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
      } | Select-Object -First 100 | ForEach-Object {
        [ordered]@{
          pid = $_.Id
          process = $_.ProcessName
          title = $_.MainWindowTitle
          handle = [string]$_.MainWindowHandle
        }
      })
      return @{ windows=$items; count=$items.Count }
    }
    'SERVICE_LIST' {
      $max = Get-ArgInt $CmdArgs 'max' 200
      $max = [Math]::Max(1,[Math]::Min($max,400))
      $items = @(Get-CimInstance Win32_Service | Sort-Object Name | Select-Object -First $max | ForEach-Object {
        [ordered]@{
          name = $_.Name
          displayName = $_.DisplayName
          state = $_.State
          startMode = $_.StartMode
          pid = $_.ProcessId
        }
      })
      return @{ services=$items; count=$items.Count }
    }
    'FILE_INFO' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path)) { throw 'path_not_found' }
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      return [ordered]@{
        root = $rootName
        path = $relative
        name = $item.Name
        type = if ($item.PSIsContainer) { 'dir' } else { 'file' }
        length = if ($item.PSIsContainer) { $null } else { $item.Length }
        extension = if ($item.PSIsContainer) { '' } else { $item.Extension }
        attributes = [string]$item.Attributes
        created = $item.CreationTime.ToString('o')
        modified = $item.LastWriteTime.ToString('o')
      }
    }
    'LIST' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $max = Get-ArgInt $CmdArgs 'max' 100
      $max = [Math]::Max(1,[Math]::Min($max,300))
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'directory_not_found' }
      $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Sort-Object -Property @{Expression='PSIsContainer';Descending=$true}, Name | Select-Object -First $max | ForEach-Object {
        [ordered]@{
          name = $_.Name
          type = if ($_.PSIsContainer) { 'dir' } else { 'file' }
          length = if ($_.PSIsContainer) { $null } else { $_.Length }
          modified = $_.LastWriteTime.ToString('o')
          attributes = [string]$_.Attributes
        }
      })
      return @{ root=$rootName; path=$relative; items=$items; count=$items.Count }
    }
    'READ_TEXT' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $maxBytes = Get-ArgInt $CmdArgs 'maxBytes' 65536
      $maxBytes = [Math]::Max(1024,[Math]::Min($maxBytes,262144))
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'file_not_found' }
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      if ($item.Length -gt $maxBytes) { throw 'file_too_large' }
      $bytes = [IO.File]::ReadAllBytes($path)
      if ($bytes -contains 0) { throw 'binary_file_not_allowed' }
      $text = [Text.Encoding]::UTF8.GetString($bytes)
      return @{ root=$rootName; path=$relative; bytes=$bytes.Length; text=$text }
    }
    'SCREEN_INFO' {
      return Get-ScreenInfo
    }
    'BRIDGE_DIAG' {
      return Get-BridgeDiag
    }
    'RESOURCE_SNAPSHOT' {
      return Get-ResourceSnapshot
    }
    'APP_STATUS' {
      return Get-AppStatus
    }
    'UPDATE_CHECK' {
      return Get-UpdateCheck
    }
    'OBS_STATUS' {
      return Get-ObsStatus
    }
    'OBS_KICK_TUNE' {
      return Set-ObsKickTune $CmdArgs
    }
    default {
      throw 'operation_not_allowed_in_safe_mode'
    }
  }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Log 'GitHub CLI ausente.'
  exit
}

$null = & gh auth status -h github.com 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Log 'GitHub CLI sem autenticacao.'
  exit
}

$state = Get-State
[long]$lastId = 0
try { $lastId = [long]$state.lastCommentId } catch {}
if ($lastId -le 0) {
  $lastId = Get-MaxCommentId
  Save-State $lastId
}

Write-Log ("Agente seguro iniciado PID=$PID last=$lastId")
Post-Comment ("RB2_STATUS" + [Environment]::NewLine + (Encode-Json @{
  status = 'online'
  version = $Version
  pid = $PID
  machine = $env:COMPUTERNAME
  mode = 'safe-limited-control'
  timestamp = (Get-Date).ToString('o')
})) | Out-Null
Write-Health

$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-5)
$lastHealth = (Get-Date).AddMinutes(-1)
$lastHeartbeat = (Get-Date).AddMinutes(-5)
$currentPollSeconds = $PollSecondsNormal
$lastGameCheck = (Get-Date).AddMinutes(-5)
$script:PollErrorCount = 0
$script:LastPollOk = Get-Date
Update-Heartbeat | Out-Null

while ($true) {
  try {
    $comments = @(Poll-Comments $pollSince)
    $script:PollErrorCount = 0
    $script:LastPollOk = Get-Date
    if ($comments.Count -gt 0) {
      foreach ($c in @($comments | Sort-Object id)) {
        [long]$cid = 0
        try { $cid = [long]$c.id } catch { continue }
        if ($cid -le $lastId) { continue }

        $lastId = $cid
        Save-State $lastId

        if ([string]$c.user.login -ne $Trusted) { continue }
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

        $cmdArgs = [pscustomobject]@{}
        if ($lines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($lines[1])) {
          try {
            $cmdArgs = Decode-Json $lines[1].Trim()
          } catch {
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

      $latest = $null
      foreach ($c in @($comments)) {
        try {
          $dt = [DateTimeOffset]::Parse([string]$c.created_at).UtcDateTime
          if ($null -eq $latest -or $dt -gt $latest) { $latest = $dt }
        } catch {}
      }
      if ($null -ne $latest) { $pollSince = $latest.AddSeconds(-2) }
    }
  } catch {
    $script:PollErrorCount = [Math]::Min(($script:PollErrorCount + 1),10)
    Write-Log ('Loop error: ' + $_.Exception.Message)
  }

  if (((Get-Date) - $lastHealth).TotalSeconds -ge 10) {
    Write-Health
    $lastHealth = Get-Date
  }

  if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
    Update-Heartbeat | Out-Null
    $lastHeartbeat = Get-Date
  }

  if (((Get-Date) - $lastGameCheck).TotalSeconds -ge 30) {
    try {
      $inGame = ($null -ne (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue | Select-Object -First 1))
      $currentPollSeconds = if ($inGame) { $PollSecondsGame } else { $PollSecondsNormal }
    } catch { $currentPollSeconds = $PollSecondsNormal }
    $lastGameCheck = Get-Date
  }

  $backoffSeconds = 0
  if ($script:PollErrorCount -gt 0) {
    $backoffSeconds = [Math]::Min(60,[int][Math]::Pow(2,[Math]::Min($script:PollErrorCount,5)))
  }
  $sleepSeconds = [Math]::Max($currentPollSeconds,$backoffSeconds)
  Start-Sleep -Seconds $sleepSeconds
}
) {
      $inSection = ($matches[1] -eq $Section)
      continue
    }
    if ($inSection -and $trim -match ('^' + [regex]::Escape($Key) + '\s*=(.*)
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $disks = @(
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
      [ordered]@{
        drive = $_.DeviceID
        sizeGB = if ($_.Size) { [Math]::Round($_.Size / 1GB, 1) } else { $null }
        freeGB = if ($_.FreeSpace) { [Math]::Round($_.FreeSpace / 1GB, 1) } else { $null }
      }
    }
  )
  [ordered]@{
    computer = $env:COMPUTERNAME
    user = $env:USERNAME
    os = $os.Caption
    cpu = $cpu.Name
    memoryGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    freeMemoryGB = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
    disks = $disks
  }
}

function Invoke-AllowedOperation([string]$Op, $CmdArgs) {
  switch ($Op.ToUpperInvariant()) {
    'PING' {
      return @{ pong = $true; mode = 'safe-limited-control' }
    }
    'BRIDGE_INFO' {
      return @{
        version = $Version
        pid = $PID
        mode = 'safe-limited-control'
        roots = @($ReadRoots.Keys | Sort-Object)
        capabilities = @($Capabilities)
        heartbeatSeconds = $HeartbeatSeconds
        transport = 'github-comments'
        processPriority = 'BelowNormal'
        pollSecondsNormal = $PollSecondsNormal
        pollSecondsGame = $PollSecondsGame
      }
    }
    'CAPABILITIES' {
      return @{ mode='safe-limited-control'; roots=@($ReadRoots.Keys | Sort-Object); capabilities=@($Capabilities) }
    }
    'SYSINFO' {
      return Get-SystemInfo
    }
    'PROC_LIST' {
      $max = Get-ArgInt $CmdArgs 'max' 100
      $max = [Math]::Max(1,[Math]::Min($max,200))
      $items = @(Get-Process | Sort-Object CPU -Descending | Select-Object -First $max | ForEach-Object {
        $started = $null
        try { $started = $_.StartTime.ToString('o') } catch {}
        [ordered]@{
          pid = $_.Id
          name = $_.ProcessName
          cpu = if ($null -eq $_.CPU) { 0 } else { [Math]::Round([double]$_.CPU,1) }
          memoryMB = [Math]::Round($_.WorkingSet64 / 1MB,1)
          started = $started
        }
      })
      return @{ processes=$items; count=$items.Count }
    }
    'WINDOWS_LIST' {
      $items = @(Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
      } | Select-Object -First 100 | ForEach-Object {
        [ordered]@{
          pid = $_.Id
          process = $_.ProcessName
          title = $_.MainWindowTitle
          handle = [string]$_.MainWindowHandle
        }
      })
      return @{ windows=$items; count=$items.Count }
    }
    'SERVICE_LIST' {
      $max = Get-ArgInt $CmdArgs 'max' 200
      $max = [Math]::Max(1,[Math]::Min($max,400))
      $items = @(Get-CimInstance Win32_Service | Sort-Object Name | Select-Object -First $max | ForEach-Object {
        [ordered]@{
          name = $_.Name
          displayName = $_.DisplayName
          state = $_.State
          startMode = $_.StartMode
          pid = $_.ProcessId
        }
      })
      return @{ services=$items; count=$items.Count }
    }
    'FILE_INFO' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path)) { throw 'path_not_found' }
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      return [ordered]@{
        root = $rootName
        path = $relative
        name = $item.Name
        type = if ($item.PSIsContainer) { 'dir' } else { 'file' }
        length = if ($item.PSIsContainer) { $null } else { $item.Length }
        extension = if ($item.PSIsContainer) { '' } else { $item.Extension }
        attributes = [string]$item.Attributes
        created = $item.CreationTime.ToString('o')
        modified = $item.LastWriteTime.ToString('o')
      }
    }
    'LIST' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $max = Get-ArgInt $CmdArgs 'max' 100
      $max = [Math]::Max(1,[Math]::Min($max,300))
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'directory_not_found' }
      $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Sort-Object -Property @{Expression='PSIsContainer';Descending=$true}, Name | Select-Object -First $max | ForEach-Object {
        [ordered]@{
          name = $_.Name
          type = if ($_.PSIsContainer) { 'dir' } else { 'file' }
          length = if ($_.PSIsContainer) { $null } else { $_.Length }
          modified = $_.LastWriteTime.ToString('o')
          attributes = [string]$_.Attributes
        }
      })
      return @{ root=$rootName; path=$relative; items=$items; count=$items.Count }
    }
    'READ_TEXT' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $maxBytes = Get-ArgInt $CmdArgs 'maxBytes' 65536
      $maxBytes = [Math]::Max(1024,[Math]::Min($maxBytes,262144))
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'file_not_found' }
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      if ($item.Length -gt $maxBytes) { throw 'file_too_large' }
      $bytes = [IO.File]::ReadAllBytes($path)
      if ($bytes -contains 0) { throw 'binary_file_not_allowed' }
      $text = [Text.Encoding]::UTF8.GetString($bytes)
      return @{ root=$rootName; path=$relative; bytes=$bytes.Length; text=$text }
    }
    'SCREEN_INFO' {
      return Get-ScreenInfo
    }
    'BRIDGE_DIAG' {
      return Get-BridgeDiag
    }
    'RESOURCE_SNAPSHOT' {
      return Get-ResourceSnapshot
    }
    'APP_STATUS' {
      return Get-AppStatus
    }
    'UPDATE_CHECK' {
      return Get-UpdateCheck
    }
    default {
      throw 'operation_not_allowed_in_safe_mode'
    }
  }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Log 'GitHub CLI ausente.'
  exit
}

$null = & gh auth status -h github.com 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Log 'GitHub CLI sem autenticacao.'
  exit
}

$state = Get-State
[long]$lastId = 0
try { $lastId = [long]$state.lastCommentId } catch {}
if ($lastId -le 0) {
  $lastId = Get-MaxCommentId
  Save-State $lastId
}

Write-Log ("Agente seguro iniciado PID=$PID last=$lastId")
Post-Comment ("RB2_STATUS" + [Environment]::NewLine + (Encode-Json @{
  status = 'online'
  version = $Version
  pid = $PID
  machine = $env:COMPUTERNAME
  mode = 'safe-limited-control'
  timestamp = (Get-Date).ToString('o')
})) | Out-Null
Write-Health

$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-5)
$lastHealth = (Get-Date).AddMinutes(-1)
$lastHeartbeat = (Get-Date).AddMinutes(-5)
$currentPollSeconds = $PollSecondsNormal
$lastGameCheck = (Get-Date).AddMinutes(-5)
$script:PollErrorCount = 0
$script:LastPollOk = Get-Date
Update-Heartbeat | Out-Null

while ($true) {
  try {
    $comments = @(Poll-Comments $pollSince)
    $script:PollErrorCount = 0
    $script:LastPollOk = Get-Date
    if ($comments.Count -gt 0) {
      foreach ($c in @($comments | Sort-Object id)) {
        [long]$cid = 0
        try { $cid = [long]$c.id } catch { continue }
        if ($cid -le $lastId) { continue }

        $lastId = $cid
        Save-State $lastId

        if ([string]$c.user.login -ne $Trusted) { continue }
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

        $cmdArgs = [pscustomobject]@{}
        if ($lines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($lines[1])) {
          try {
            $cmdArgs = Decode-Json $lines[1].Trim()
          } catch {
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

      $latest = $null
      foreach ($c in @($comments)) {
        try {
          $dt = [DateTimeOffset]::Parse([string]$c.created_at).UtcDateTime
          if ($null -eq $latest -or $dt -gt $latest) { $latest = $dt }
        } catch {}
      }
      if ($null -ne $latest) { $pollSince = $latest.AddSeconds(-2) }
    }
  } catch {
    $script:PollErrorCount = [Math]::Min(($script:PollErrorCount + 1),10)
    Write-Log ('Loop error: ' + $_.Exception.Message)
  }

  if (((Get-Date) - $lastHealth).TotalSeconds -ge 10) {
    Write-Health
    $lastHealth = Get-Date
  }

  if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
    Update-Heartbeat | Out-Null
    $lastHeartbeat = Get-Date
  }

  if (((Get-Date) - $lastGameCheck).TotalSeconds -ge 30) {
    try {
      $inGame = ($null -ne (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue | Select-Object -First 1))
      $currentPollSeconds = if ($inGame) { $PollSecondsGame } else { $PollSecondsNormal }
    } catch { $currentPollSeconds = $PollSecondsNormal }
    $lastGameCheck = Get-Date
  }

  $backoffSeconds = 0
  if ($script:PollErrorCount -gt 0) {
    $backoffSeconds = [Math]::Min(60,[int][Math]::Pow(2,[Math]::Min($script:PollErrorCount,5)))
  }
  $sleepSeconds = [Math]::Max($currentPollSeconds,$backoffSeconds)
  Start-Sleep -Seconds $sleepSeconds
}
)) {
      return ([string]$matches[1]).Trim()
    }
  }
  return $null
}

function Set-IniValue([string]$Path, [string]$Section, [string]$Key, [string]$Value) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'ini_file_not_found' }

  $src = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
  $list = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in $src) { [void]$list.Add([string]$line) }

  $sectionStart = -1
  $sectionEnd = $list.Count
  for ($i=0; $i -lt $list.Count; $i++) {
    $trim = $list[$i].Trim()
    if ($trim -match '^\[(.+)\]
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $disks = @(
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
      [ordered]@{
        drive = $_.DeviceID
        sizeGB = if ($_.Size) { [Math]::Round($_.Size / 1GB, 1) } else { $null }
        freeGB = if ($_.FreeSpace) { [Math]::Round($_.FreeSpace / 1GB, 1) } else { $null }
      }
    }
  )
  [ordered]@{
    computer = $env:COMPUTERNAME
    user = $env:USERNAME
    os = $os.Caption
    cpu = $cpu.Name
    memoryGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    freeMemoryGB = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
    disks = $disks
  }
}

function Invoke-AllowedOperation([string]$Op, $CmdArgs) {
  switch ($Op.ToUpperInvariant()) {
    'PING' {
      return @{ pong = $true; mode = 'safe-limited-control' }
    }
    'BRIDGE_INFO' {
      return @{
        version = $Version
        pid = $PID
        mode = 'safe-limited-control'
        roots = @($ReadRoots.Keys | Sort-Object)
        capabilities = @($Capabilities)
        heartbeatSeconds = $HeartbeatSeconds
        transport = 'github-comments'
        processPriority = 'BelowNormal'
        pollSecondsNormal = $PollSecondsNormal
        pollSecondsGame = $PollSecondsGame
      }
    }
    'CAPABILITIES' {
      return @{ mode='safe-limited-control'; roots=@($ReadRoots.Keys | Sort-Object); capabilities=@($Capabilities) }
    }
    'SYSINFO' {
      return Get-SystemInfo
    }
    'PROC_LIST' {
      $max = Get-ArgInt $CmdArgs 'max' 100
      $max = [Math]::Max(1,[Math]::Min($max,200))
      $items = @(Get-Process | Sort-Object CPU -Descending | Select-Object -First $max | ForEach-Object {
        $started = $null
        try { $started = $_.StartTime.ToString('o') } catch {}
        [ordered]@{
          pid = $_.Id
          name = $_.ProcessName
          cpu = if ($null -eq $_.CPU) { 0 } else { [Math]::Round([double]$_.CPU,1) }
          memoryMB = [Math]::Round($_.WorkingSet64 / 1MB,1)
          started = $started
        }
      })
      return @{ processes=$items; count=$items.Count }
    }
    'WINDOWS_LIST' {
      $items = @(Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
      } | Select-Object -First 100 | ForEach-Object {
        [ordered]@{
          pid = $_.Id
          process = $_.ProcessName
          title = $_.MainWindowTitle
          handle = [string]$_.MainWindowHandle
        }
      })
      return @{ windows=$items; count=$items.Count }
    }
    'SERVICE_LIST' {
      $max = Get-ArgInt $CmdArgs 'max' 200
      $max = [Math]::Max(1,[Math]::Min($max,400))
      $items = @(Get-CimInstance Win32_Service | Sort-Object Name | Select-Object -First $max | ForEach-Object {
        [ordered]@{
          name = $_.Name
          displayName = $_.DisplayName
          state = $_.State
          startMode = $_.StartMode
          pid = $_.ProcessId
        }
      })
      return @{ services=$items; count=$items.Count }
    }
    'FILE_INFO' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path)) { throw 'path_not_found' }
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      return [ordered]@{
        root = $rootName
        path = $relative
        name = $item.Name
        type = if ($item.PSIsContainer) { 'dir' } else { 'file' }
        length = if ($item.PSIsContainer) { $null } else { $item.Length }
        extension = if ($item.PSIsContainer) { '' } else { $item.Extension }
        attributes = [string]$item.Attributes
        created = $item.CreationTime.ToString('o')
        modified = $item.LastWriteTime.ToString('o')
      }
    }
    'LIST' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $max = Get-ArgInt $CmdArgs 'max' 100
      $max = [Math]::Max(1,[Math]::Min($max,300))
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'directory_not_found' }
      $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Sort-Object -Property @{Expression='PSIsContainer';Descending=$true}, Name | Select-Object -First $max | ForEach-Object {
        [ordered]@{
          name = $_.Name
          type = if ($_.PSIsContainer) { 'dir' } else { 'file' }
          length = if ($_.PSIsContainer) { $null } else { $_.Length }
          modified = $_.LastWriteTime.ToString('o')
          attributes = [string]$_.Attributes
        }
      })
      return @{ root=$rootName; path=$relative; items=$items; count=$items.Count }
    }
    'READ_TEXT' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $maxBytes = Get-ArgInt $CmdArgs 'maxBytes' 65536
      $maxBytes = [Math]::Max(1024,[Math]::Min($maxBytes,262144))
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'file_not_found' }
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      if ($item.Length -gt $maxBytes) { throw 'file_too_large' }
      $bytes = [IO.File]::ReadAllBytes($path)
      if ($bytes -contains 0) { throw 'binary_file_not_allowed' }
      $text = [Text.Encoding]::UTF8.GetString($bytes)
      return @{ root=$rootName; path=$relative; bytes=$bytes.Length; text=$text }
    }
    'SCREEN_INFO' {
      return Get-ScreenInfo
    }
    'BRIDGE_DIAG' {
      return Get-BridgeDiag
    }
    'RESOURCE_SNAPSHOT' {
      return Get-ResourceSnapshot
    }
    'APP_STATUS' {
      return Get-AppStatus
    }
    'UPDATE_CHECK' {
      return Get-UpdateCheck
    }
    default {
      throw 'operation_not_allowed_in_safe_mode'
    }
  }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Log 'GitHub CLI ausente.'
  exit
}

$null = & gh auth status -h github.com 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Log 'GitHub CLI sem autenticacao.'
  exit
}

$state = Get-State
[long]$lastId = 0
try { $lastId = [long]$state.lastCommentId } catch {}
if ($lastId -le 0) {
  $lastId = Get-MaxCommentId
  Save-State $lastId
}

Write-Log ("Agente seguro iniciado PID=$PID last=$lastId")
Post-Comment ("RB2_STATUS" + [Environment]::NewLine + (Encode-Json @{
  status = 'online'
  version = $Version
  pid = $PID
  machine = $env:COMPUTERNAME
  mode = 'safe-limited-control'
  timestamp = (Get-Date).ToString('o')
})) | Out-Null
Write-Health

$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-5)
$lastHealth = (Get-Date).AddMinutes(-1)
$lastHeartbeat = (Get-Date).AddMinutes(-5)
$currentPollSeconds = $PollSecondsNormal
$lastGameCheck = (Get-Date).AddMinutes(-5)
$script:PollErrorCount = 0
$script:LastPollOk = Get-Date
Update-Heartbeat | Out-Null

while ($true) {
  try {
    $comments = @(Poll-Comments $pollSince)
    $script:PollErrorCount = 0
    $script:LastPollOk = Get-Date
    if ($comments.Count -gt 0) {
      foreach ($c in @($comments | Sort-Object id)) {
        [long]$cid = 0
        try { $cid = [long]$c.id } catch { continue }
        if ($cid -le $lastId) { continue }

        $lastId = $cid
        Save-State $lastId

        if ([string]$c.user.login -ne $Trusted) { continue }
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

        $cmdArgs = [pscustomobject]@{}
        if ($lines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($lines[1])) {
          try {
            $cmdArgs = Decode-Json $lines[1].Trim()
          } catch {
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

      $latest = $null
      foreach ($c in @($comments)) {
        try {
          $dt = [DateTimeOffset]::Parse([string]$c.created_at).UtcDateTime
          if ($null -eq $latest -or $dt -gt $latest) { $latest = $dt }
        } catch {}
      }
      if ($null -ne $latest) { $pollSince = $latest.AddSeconds(-2) }
    }
  } catch {
    $script:PollErrorCount = [Math]::Min(($script:PollErrorCount + 1),10)
    Write-Log ('Loop error: ' + $_.Exception.Message)
  }

  if (((Get-Date) - $lastHealth).TotalSeconds -ge 10) {
    Write-Health
    $lastHealth = Get-Date
  }

  if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
    Update-Heartbeat | Out-Null
    $lastHeartbeat = Get-Date
  }

  if (((Get-Date) - $lastGameCheck).TotalSeconds -ge 30) {
    try {
      $inGame = ($null -ne (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue | Select-Object -First 1))
      $currentPollSeconds = if ($inGame) { $PollSecondsGame } else { $PollSecondsNormal }
    } catch { $currentPollSeconds = $PollSecondsNormal }
    $lastGameCheck = Get-Date
  }

  $backoffSeconds = 0
  if ($script:PollErrorCount -gt 0) {
    $backoffSeconds = [Math]::Min(60,[int][Math]::Pow(2,[Math]::Min($script:PollErrorCount,5)))
  }
  $sleepSeconds = [Math]::Max($currentPollSeconds,$backoffSeconds)
  Start-Sleep -Seconds $sleepSeconds
}
) {
      if ($sectionStart -ge 0) { $sectionEnd = $i; break }
      if ($matches[1] -eq $Section) { $sectionStart = $i }
    }
  }

  if ($sectionStart -lt 0) {
    if ($list.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($list[$list.Count-1])) { [void]$list.Add('') }
    [void]$list.Add('[' + $Section + ']')
    [void]$list.Add($Key + '=' + $Value)
  } else {
    $found = $false
    for ($i=$sectionStart+1; $i -lt $sectionEnd; $i++) {
      if ($list[$i].Trim() -match ('^' + [regex]::Escape($Key) + '\s*=')) {
        $list[$i] = $Key + '=' + $Value
        $found = $true
        break
      }
    }
    if (-not $found) { $list.Insert($sectionEnd, $Key + '=' + $Value) }
  }

  [IO.File]::WriteAllLines($Path, $list, (New-Object Text.UTF8Encoding($false)))
}

function Get-ObsContext {
  $obsRoot = Join-Path $env:APPDATA 'obs-studio'
  $globalIni = Join-Path $obsRoot 'global.ini'
  if (-not (Test-Path -LiteralPath $globalIni -PathType Leaf)) { throw 'obs_config_not_found' }

  $profileDir = Get-IniValue $globalIni 'Basic' 'ProfileDir'
  if ([string]::IsNullOrWhiteSpace([string]$profileDir)) {
    $profileDir = Get-IniValue $globalIni 'Basic' 'Profile'
  }
  if ([string]::IsNullOrWhiteSpace([string]$profileDir)) { throw 'obs_profile_not_found' }

  $profilesRoot = [IO.Path]::GetFullPath((Join-Path $obsRoot 'basic\profiles')).TrimEnd('\')
  $profilePath = [IO.Path]::GetFullPath((Join-Path $profilesRoot $profileDir))
  if (-not $profilePath.StartsWith($profilesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'obs_profile_path_invalid'
  }

  $basicIni = Join-Path $profilePath 'basic.ini'
  if (-not (Test-Path -LiteralPath $basicIni -PathType Leaf)) { throw 'obs_basic_ini_not_found' }

  return [ordered]@{
    root = $obsRoot
    globalIni = $globalIni
    profileDir = $profileDir
    profilePath = $profilePath
    basicIni = $basicIni
    streamEncoder = (Join-Path $profilePath 'streamEncoder.json')
    service = (Join-Path $profilePath 'service.json')
  }
}

function Get-ObsStatus {
  $ctx = Get-ObsContext
  $serviceType = $null
  $serverConfigured = $false
  $keyConfigured = $false
  if (Test-Path -LiteralPath $ctx.service -PathType Leaf) {
    try {
      $svc = Get-Content -LiteralPath $ctx.service -Raw | ConvertFrom-Json
      $serviceType = [string]$svc.type
      if ($svc.settings) {
        $serverConfigured = -not [string]::IsNullOrWhiteSpace([string]$svc.settings.server)
        $keyConfigured = -not [string]::IsNullOrWhiteSpace([string]$svc.settings.key)
      }
    } catch {}
  }

  $encoderData = $null
  if (Test-Path -LiteralPath $ctx.streamEncoder -PathType Leaf) {
    try { $encoderData = Get-Content -LiteralPath $ctx.streamEncoder -Raw | ConvertFrom-Json } catch {}
  }

  return [ordered]@{
    profile = [string]$ctx.profileDir
    obsRunning = [bool](Get-Process -Name 'obs64' -ErrorAction SilentlyContinue | Select-Object -First 1)
    outputMode = (Get-IniValue $ctx.basicIni 'Output' 'Mode')
    encoder = (Get-IniValue $ctx.basicIni 'AdvOut' 'Encoder')
    outputWidth = (Get-IniValue $ctx.basicIni 'Video' 'OutputCX')
    outputHeight = (Get-IniValue $ctx.basicIni 'Video' 'OutputCY')
    fps = (Get-IniValue $ctx.basicIni 'Video' 'FPSCommon')
    sampleRate = (Get-IniValue $ctx.basicIni 'Audio' 'SampleRate')
    channels = (Get-IniValue $ctx.basicIni 'Audio' 'ChannelSetup')
    bitrate = if ($encoderData -and $encoderData.PSObject.Properties['bitrate']) { [int]$encoderData.bitrate } else { $null }
    rateControl = if ($encoderData -and $encoderData.PSObject.Properties['rate_control']) { [string]$encoderData.rate_control } else { $null }
    keyframeSeconds = if ($encoderData -and $encoderData.PSObject.Properties['keyint_sec']) { [int]$encoderData.keyint_sec } else { $null }
    preset = if ($encoderData -and $encoderData.PSObject.Properties['preset']) { [string]$encoderData.preset } else { $null }
    tune = if ($encoderData -and $encoderData.PSObject.Properties['tune']) { [string]$encoderData.tune } else { $null }
    multipass = if ($encoderData -and $encoderData.PSObject.Properties['multipass']) { [string]$encoderData.multipass } else { $null }
    profileH264 = if ($encoderData -and $encoderData.PSObject.Properties['profile']) { [string]$encoderData.profile } else { $null }
    serviceType = $serviceType
    serverConfigured = $serverConfigured
    streamKeyConfigured = $keyConfigured
    credentialsExposed = $false
  }
}

function Set-ObsKickTune($CmdArgs) {
  if (Get-Process -Name 'obs64' -ErrorAction SilentlyContinue | Select-Object -First 1) {
    throw 'obs_running_close_first'
  }

  $bitrate = Get-ArgInt $CmdArgs 'bitrate' 5000
  $bitrate = [Math]::Max(1000,[Math]::Min($bitrate,8000))
  $ctx = Get-ObsContext

  $currentEncoder = [string](Get-IniValue $ctx.basicIni 'AdvOut' 'Encoder')
  $encoder = $currentEncoder
  if ([string]::IsNullOrWhiteSpace($encoder) -or $encoder -notmatch '(?i)nvenc') {
    $encoder = 'obs_nvenc_h264_tex'
  }

  $backupDir = Join-Path $BaseDir ('obs-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  foreach ($p in @($ctx.globalIni,$ctx.basicIni,$ctx.streamEncoder,$ctx.service)) {
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      Copy-Item -LiteralPath $p -Destination (Join-Path $backupDir ([IO.Path]::GetFileName($p))) -Force
    }
  }

  Set-IniValue $ctx.basicIni 'Output' 'Mode' 'Advanced'
  Set-IniValue $ctx.basicIni 'Output' 'Reconnect' 'true'
  Set-IniValue $ctx.basicIni 'Output' 'RetryDelay' '2'
  Set-IniValue $ctx.basicIni 'Output' 'MaxRetries' '25'

  Set-IniValue $ctx.basicIni 'AdvOut' 'Encoder' $encoder
  Set-IniValue $ctx.basicIni 'AdvOut' 'ApplyServiceSettings' 'true'
  Set-IniValue $ctx.basicIni 'AdvOut' 'UseRescale' 'false'
  Set-IniValue $ctx.basicIni 'AdvOut' 'TrackIndex' '1'
  Set-IniValue $ctx.basicIni 'AdvOut' 'AudioEncoder' 'ffmpeg_aac'
  Set-IniValue $ctx.basicIni 'AdvOut' 'Track1Bitrate' '160'

  Set-IniValue $ctx.basicIni 'Video' 'OutputCX' '1280'
  Set-IniValue $ctx.basicIni 'Video' 'OutputCY' '720'
  Set-IniValue $ctx.basicIni 'Video' 'FPSType' '0'
  Set-IniValue $ctx.basicIni 'Video' 'FPSCommon' '60'
  Set-IniValue $ctx.basicIni 'Video' 'ScaleType' 'bicubic'
  Set-IniValue $ctx.basicIni 'Video' 'ColorFormat' 'NV12'
  Set-IniValue $ctx.basicIni 'Video' 'ColorSpace' '709'
  Set-IniValue $ctx.basicIni 'Video' 'ColorRange' 'Partial'

  Set-IniValue $ctx.basicIni 'Audio' 'SampleRate' '48000'
  Set-IniValue $ctx.basicIni 'Audio' 'ChannelSetup' 'Stereo'

  $enc = [ordered]@{
    rate_control = 'CBR'
    bitrate = $bitrate
    keyint_sec = 2
    preset = 'p6'
    tune = 'ull'
    multipass = 'disabled'
    profile = 'main'
    lookahead = $false
    adaptive_quantization = $true
    bf = 2
  }
  $json = $enc | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($ctx.streamEncoder, $json, (New-Object Text.UTF8Encoding($false)))

  $after = Get-ObsStatus
  return [ordered]@{
    applied = $true
    target = 'Kick'
    backup = $backupDir
    settings = [ordered]@{
      encoder = $after.encoder
      output = '1280x720'
      fps = 60
      bitrate = $after.bitrate
      rateControl = $after.rateControl
      keyframeSeconds = $after.keyframeSeconds
      preset = $after.preset
      tune = $after.tune
      multipass = $after.multipass
      profile = $after.profileH264
      audio = 'Stereo 48kHz / 160kbps'
    }
    streamDestinationPreserved = $true
    serverConfigured = $after.serverConfigured
    streamKeyConfigured = $after.streamKeyConfigured
    credentialsExposed = $false
  }
}

function Get-SystemInfo {
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $disks = @(
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
      [ordered]@{
        drive = $_.DeviceID
        sizeGB = if ($_.Size) { [Math]::Round($_.Size / 1GB, 1) } else { $null }
        freeGB = if ($_.FreeSpace) { [Math]::Round($_.FreeSpace / 1GB, 1) } else { $null }
      }
    }
  )
  [ordered]@{
    computer = $env:COMPUTERNAME
    user = $env:USERNAME
    os = $os.Caption
    cpu = $cpu.Name
    memoryGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    freeMemoryGB = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
    disks = $disks
  }
}

function Invoke-AllowedOperation([string]$Op, $CmdArgs) {
  switch ($Op.ToUpperInvariant()) {
    'PING' {
      return @{ pong = $true; mode = 'safe-limited-control' }
    }
    'BRIDGE_INFO' {
      return @{
        version = $Version
        pid = $PID
        mode = 'safe-limited-control'
        roots = @($ReadRoots.Keys | Sort-Object)
        capabilities = @($Capabilities)
        heartbeatSeconds = $HeartbeatSeconds
        transport = 'github-comments'
        processPriority = 'BelowNormal'
        pollSecondsNormal = $PollSecondsNormal
        pollSecondsGame = $PollSecondsGame
      }
    }
    'CAPABILITIES' {
      return @{ mode='safe-limited-control'; roots=@($ReadRoots.Keys | Sort-Object); capabilities=@($Capabilities) }
    }
    'SYSINFO' {
      return Get-SystemInfo
    }
    'PROC_LIST' {
      $max = Get-ArgInt $CmdArgs 'max' 100
      $max = [Math]::Max(1,[Math]::Min($max,200))
      $items = @(Get-Process | Sort-Object CPU -Descending | Select-Object -First $max | ForEach-Object {
        $started = $null
        try { $started = $_.StartTime.ToString('o') } catch {}
        [ordered]@{
          pid = $_.Id
          name = $_.ProcessName
          cpu = if ($null -eq $_.CPU) { 0 } else { [Math]::Round([double]$_.CPU,1) }
          memoryMB = [Math]::Round($_.WorkingSet64 / 1MB,1)
          started = $started
        }
      })
      return @{ processes=$items; count=$items.Count }
    }
    'WINDOWS_LIST' {
      $items = @(Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle)
      } | Select-Object -First 100 | ForEach-Object {
        [ordered]@{
          pid = $_.Id
          process = $_.ProcessName
          title = $_.MainWindowTitle
          handle = [string]$_.MainWindowHandle
        }
      })
      return @{ windows=$items; count=$items.Count }
    }
    'SERVICE_LIST' {
      $max = Get-ArgInt $CmdArgs 'max' 200
      $max = [Math]::Max(1,[Math]::Min($max,400))
      $items = @(Get-CimInstance Win32_Service | Sort-Object Name | Select-Object -First $max | ForEach-Object {
        [ordered]@{
          name = $_.Name
          displayName = $_.DisplayName
          state = $_.State
          startMode = $_.StartMode
          pid = $_.ProcessId
        }
      })
      return @{ services=$items; count=$items.Count }
    }
    'FILE_INFO' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path)) { throw 'path_not_found' }
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      return [ordered]@{
        root = $rootName
        path = $relative
        name = $item.Name
        type = if ($item.PSIsContainer) { 'dir' } else { 'file' }
        length = if ($item.PSIsContainer) { $null } else { $item.Length }
        extension = if ($item.PSIsContainer) { '' } else { $item.Extension }
        attributes = [string]$item.Attributes
        created = $item.CreationTime.ToString('o')
        modified = $item.LastWriteTime.ToString('o')
      }
    }
    'LIST' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $max = Get-ArgInt $CmdArgs 'max' 100
      $max = [Math]::Max(1,[Math]::Min($max,300))
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'directory_not_found' }
      $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction Stop | Sort-Object -Property @{Expression='PSIsContainer';Descending=$true}, Name | Select-Object -First $max | ForEach-Object {
        [ordered]@{
          name = $_.Name
          type = if ($_.PSIsContainer) { 'dir' } else { 'file' }
          length = if ($_.PSIsContainer) { $null } else { $_.Length }
          modified = $_.LastWriteTime.ToString('o')
          attributes = [string]$_.Attributes
        }
      })
      return @{ root=$rootName; path=$relative; items=$items; count=$items.Count }
    }
    'READ_TEXT' {
      $rootName = Get-ArgString $CmdArgs 'root' ''
      $relative = Get-ArgString $CmdArgs 'path' ''
      $maxBytes = Get-ArgInt $CmdArgs 'maxBytes' 65536
      $maxBytes = [Math]::Max(1024,[Math]::Min($maxBytes,262144))
      $path = Resolve-ReadPath $rootName $relative
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'file_not_found' }
      $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
      if ($item.Length -gt $maxBytes) { throw 'file_too_large' }
      $bytes = [IO.File]::ReadAllBytes($path)
      if ($bytes -contains 0) { throw 'binary_file_not_allowed' }
      $text = [Text.Encoding]::UTF8.GetString($bytes)
      return @{ root=$rootName; path=$relative; bytes=$bytes.Length; text=$text }
    }
    'SCREEN_INFO' {
      return Get-ScreenInfo
    }
    'BRIDGE_DIAG' {
      return Get-BridgeDiag
    }
    'RESOURCE_SNAPSHOT' {
      return Get-ResourceSnapshot
    }
    'APP_STATUS' {
      return Get-AppStatus
    }
    'UPDATE_CHECK' {
      return Get-UpdateCheck
    }
    default {
      throw 'operation_not_allowed_in_safe_mode'
    }
  }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Write-Log 'GitHub CLI ausente.'
  exit
}

$null = & gh auth status -h github.com 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Log 'GitHub CLI sem autenticacao.'
  exit
}

$state = Get-State
[long]$lastId = 0
try { $lastId = [long]$state.lastCommentId } catch {}
if ($lastId -le 0) {
  $lastId = Get-MaxCommentId
  Save-State $lastId
}

Write-Log ("Agente seguro iniciado PID=$PID last=$lastId")
Post-Comment ("RB2_STATUS" + [Environment]::NewLine + (Encode-Json @{
  status = 'online'
  version = $Version
  pid = $PID
  machine = $env:COMPUTERNAME
  mode = 'safe-limited-control'
  timestamp = (Get-Date).ToString('o')
})) | Out-Null
Write-Health

$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-5)
$lastHealth = (Get-Date).AddMinutes(-1)
$lastHeartbeat = (Get-Date).AddMinutes(-5)
$currentPollSeconds = $PollSecondsNormal
$lastGameCheck = (Get-Date).AddMinutes(-5)
$script:PollErrorCount = 0
$script:LastPollOk = Get-Date
Update-Heartbeat | Out-Null

while ($true) {
  try {
    $comments = @(Poll-Comments $pollSince)
    $script:PollErrorCount = 0
    $script:LastPollOk = Get-Date
    if ($comments.Count -gt 0) {
      foreach ($c in @($comments | Sort-Object id)) {
        [long]$cid = 0
        try { $cid = [long]$c.id } catch { continue }
        if ($cid -le $lastId) { continue }

        $lastId = $cid
        Save-State $lastId

        if ([string]$c.user.login -ne $Trusted) { continue }
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

        $cmdArgs = [pscustomobject]@{}
        if ($lines.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($lines[1])) {
          try {
            $cmdArgs = Decode-Json $lines[1].Trim()
          } catch {
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

      $latest = $null
      foreach ($c in @($comments)) {
        try {
          $dt = [DateTimeOffset]::Parse([string]$c.created_at).UtcDateTime
          if ($null -eq $latest -or $dt -gt $latest) { $latest = $dt }
        } catch {}
      }
      if ($null -ne $latest) { $pollSince = $latest.AddSeconds(-2) }
    }
  } catch {
    $script:PollErrorCount = [Math]::Min(($script:PollErrorCount + 1),10)
    Write-Log ('Loop error: ' + $_.Exception.Message)
  }

  if (((Get-Date) - $lastHealth).TotalSeconds -ge 10) {
    Write-Health
    $lastHealth = Get-Date
  }

  if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $HeartbeatSeconds) {
    Update-Heartbeat | Out-Null
    $lastHeartbeat = Get-Date
  }

  if (((Get-Date) - $lastGameCheck).TotalSeconds -ge 30) {
    try {
      $inGame = ($null -ne (Get-Process -Name 'League of Legends' -ErrorAction SilentlyContinue | Select-Object -First 1))
      $currentPollSeconds = if ($inGame) { $PollSecondsGame } else { $PollSecondsNormal }
    } catch { $currentPollSeconds = $PollSecondsNormal }
    $lastGameCheck = Get-Date
  }

  $backoffSeconds = 0
  if ($script:PollErrorCount -gt 0) {
    $backoffSeconds = [Math]::Min(60,[int][Math]::Pow(2,[Math]::Min($script:PollErrorCount,5)))
  }
  $sleepSeconds = [Math]::Max($currentPollSeconds,$backoffSeconds)
  Start-Sleep -Seconds $sleepSeconds
}
