# REALLBLACK BRIDGE SAFE V4
$ErrorActionPreference = 'Continue'

$Version = '4.2.3'
$Repo = 'realblackboss/twitch-gpt-gemini-2026'
$Issue = 1
$Trusted = 'realblackboss'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$StateFile = Join-Path $BaseDir 'state-v4.json'
$HealthFile = Join-Path $BaseDir 'health-v4.json'
$LogFile = Join-Path $BaseDir 'bridge-v4.log'
$HeartbeatIdFile = Join-Path $BaseDir 'heartbeat-comment-id.txt'
$HeartbeatSeconds = 60

$ReadRoots = @{
  desktop = [Environment]::GetFolderPath('Desktop')
  documents = [Environment]::GetFolderPath('MyDocuments')
  downloads = Join-Path $env:USERPROFILE 'Downloads'
  bridge = $BaseDir
}

$Capabilities = @(
  'PING','BRIDGE_INFO','CAPABILITIES','SYSINFO',
  'PROC_LIST','WINDOWS_LIST','SERVICE_LIST',
  'FILE_INFO','LIST','READ_TEXT','SCREEN_INFO'
)

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null

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
      mode = 'safe-readonly'
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
      mode = 'safe-readonly'
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
      return @{ pong = $true; mode = 'safe-readonly' }
    }
    'BRIDGE_INFO' {
      return @{
        version = $Version
        pid = $PID
        mode = 'safe-readonly'
        roots = @($ReadRoots.Keys | Sort-Object)
        capabilities = @($Capabilities)
        heartbeatSeconds = $HeartbeatSeconds
        transport = 'github-comments'
      }
    }
    'CAPABILITIES' {
      return @{ mode='safe-readonly'; roots=@($ReadRoots.Keys | Sort-Object); capabilities=@($Capabilities) }
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
  mode = 'safe-readonly'
  timestamp = (Get-Date).ToString('o')
})) | Out-Null
Write-Health

$pollSince = (Get-Date).ToUniversalTime().AddSeconds(-5)
$lastHealth = (Get-Date).AddMinutes(-1)
$lastHeartbeat = (Get-Date).AddMinutes(-5)
Update-Heartbeat | Out-Null

while ($true) {
  try {
    $comments = @(Poll-Comments $pollSince)
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

  Start-Sleep -Seconds 2
}
