# REALLBLACK BRIDGE SAFE V4
$ErrorActionPreference = 'Continue'

$Version = '4.0.1'
$Repo = 'realblackboss/twitch-gpt-gemini-2026'
$Issue = 1
$Trusted = 'realblackboss'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$StateFile = Join-Path $BaseDir 'state-v4.json'
$HealthFile = Join-Path $BaseDir 'health-v4.json'
$LogFile = Join-Path $BaseDir 'bridge-v4.log'

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

function Invoke-AllowedOperation([string]$Op) {
  switch ($Op.ToUpperInvariant()) {
    'PING' {
      return @{ pong = $true; mode = 'safe-readonly' }
    }
    'BRIDGE_INFO' {
      return @{
        version = $Version
        pid = $PID
        mode = 'safe-readonly'
        capabilities = @('PING','BRIDGE_INFO','SYSINFO')
      }
    }
    'SYSINFO' {
      return Get-SystemInfo
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

        try {
          $result = Invoke-AllowedOperation $op
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

  Start-Sleep -Seconds 2
}
