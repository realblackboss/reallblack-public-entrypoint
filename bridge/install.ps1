param()

$ErrorActionPreference = 'Stop'
$Dir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$Agent = Join-Path $Dir 'agent-v2.ps1'
$Backup = Join-Path $Dir 'agent-v2.lastgood.ps1'
$Health = Join-Path $Dir 'health-v2.json'
$Pending = Join-Path $Dir 'update-pending.json'
$Desktop = [Environment]::GetFolderPath('Desktop')
$Startup = [Environment]::GetFolderPath('Startup')
$OldStartup = Join-Path $Startup 'REALLBLACK-PC-BRIDGE.cmd'
$ApiBase = 'https://api.github.com'
$PublicRepo = 'realblackboss/reallblack-public-entrypoint'
$ManifestPath = 'bridge/manifest-v2.json'
$PublicAgentPath = 'bridge/agent-v2.ps1'

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

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Desktop 'funcionando') | Out-Null

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  winget install --id GitHub.cli -e --accept-package-agreements --accept-source-agreements --silent
  $env:Path += ';C:\Program Files\GitHub CLI'
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw 'GitHub CLI nao encontrado.'
}

cmd.exe /d /c "gh auth status -h github.com >nul 2>&1"
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Autenticacao GitHub necessaria. O navegador sera aberto uma unica vez.'
  cmd.exe /d /c "gh auth login -h github.com -p https -w"
  if ($LASTEXITCODE -ne 0) { throw 'Falha na autenticacao do GitHub.' }
}

$token = (& gh auth token -h github.com 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace([string]$token)) {
  throw 'Token GitHub indisponivel.'
}

$RawHeaders = @{
  Authorization = ('Bearer ' + ([string]$token).Trim())
  Accept = 'application/vnd.github.raw+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent' = 'REALLBLACK-Bridge-Installer'
}

$manifestUri = $ApiBase + '/repos/' + $PublicRepo + '/contents/' + $ManifestPath + '?ref=main'
$manifestResponse = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $manifestUri -Headers $RawHeaders -TimeoutSec 20
$manifestRaw = $manifestResponse.Content
if ($manifestRaw -is [byte[]]) {
  $manifestText = [Text.Encoding]::UTF8.GetString($manifestRaw)
} else {
  $manifestText = [string]$manifestRaw
}
$manifest = $manifestText | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$manifest.sha256)) {
  throw 'Manifesto da ponte invalido.'
}

$tmpAgent = Join-Path $Dir 'agent-v2.download.ps1'
Remove-Item $tmpAgent -Force -ErrorAction SilentlyContinue
$agentUri = $ApiBase + '/repos/' + $PublicRepo + '/contents/' + $PublicAgentPath + '?ref=main'
Invoke-WebRequest -UseBasicParsing -Method Get -Uri $agentUri -Headers $RawHeaders -OutFile $tmpAgent -TimeoutSec 25

$downloadHash = (Get-FileHash $tmpAgent -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedHash = ([string]$manifest.sha256).ToLowerInvariant()
if ($downloadHash -ne $expectedHash) {
  Remove-Item $tmpAgent -Force -ErrorAction SilentlyContinue
  throw 'Falha de integridade: hash da ponte nao confere.'
}
if (-not (Test-ScriptSyntax $tmpAgent)) {
  Remove-Item $tmpAgent -Force -ErrorAction SilentlyContinue
  throw 'Falha de seguranca: agente baixado possui erro de sintaxe.'
}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object {
    $_.CommandLine -like '*ReallBlackBridge*desktop-folder-agent.ps1*' -or
    $_.CommandLine -like '*ReallBlackBridge*agent-v2.ps1*' -or
    $_.CommandLine -like '*ReallBlackBridge*watchdog-v2.ps1*'
  } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force } catch {}
  }
Start-Sleep -Milliseconds 400

if (Test-Path $Agent -PathType Leaf) {
  if (Test-ScriptSyntax $Agent) {
    [IO.File]::Replace($tmpAgent, $Agent, $Backup, $true)
  } else {
    Move-Item $tmpAgent $Agent -Force
  }
} else {
  Move-Item $tmpAgent $Agent -Force
}

Remove-Item $OldStartup -Force -ErrorAction SilentlyContinue
Remove-Item $Pending -Force -ErrorAction SilentlyContinue
Remove-Item $Health -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $Dir 'state-v2.json') -Force -ErrorAction SilentlyContinue

$Launch = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Agent + '"'
Set-Content -Path (Join-Path $Startup 'REALLBLACK-PC-BRIDGE-V2.cmd') -Value ('@echo off' + [Environment]::NewLine + $Launch) -Encoding ASCII
Set-Content -Path (Join-Path $Desktop 'LIGAR PONTE - REALLBLACK.cmd') -Value ('@echo off' + [Environment]::NewLine + $Launch) -Encoding ASCII

try {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Agent + '"')
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName 'REALLBLACK-PC-BRIDGE-V2' -Action $action -Trigger $trigger -Settings $settings -Description 'REALLBLACK Bridge resilient agent with rollback' -Force | Out-Null
} catch {}

$proc = Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Agent) -WindowStyle Hidden -PassThru

$healthy = $false
$deadline = (Get-Date).AddSeconds(20)
do {
  Start-Sleep -Milliseconds 500
  if (Test-Path $Health -PathType Leaf) {
    try {
      $h = Get-Content $Health -Raw | ConvertFrom-Json
      if ([int]$h.pid -eq [int]$proc.Id) {
        $healthy = $true
        break
      }
    } catch {}
  }
  try {
    if ($proc.HasExited) { break }
  } catch {}
} while ((Get-Date) -lt $deadline)

if (-not $healthy) {
  try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}

  if (Test-ScriptSyntax $Backup) {
    Copy-Item -LiteralPath $Backup -Destination $Agent -Force
    Remove-Item $Health -Force -ErrorAction SilentlyContinue
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Agent) -WindowStyle Hidden
    throw 'A nova ponte nao passou no teste de saude. Rollback automatico aplicado.'
  }

  throw 'A ponte nao passou no teste de saude e nao existe backup valido.'
}

Write-Host ''
Write-Host 'PONTE REALLBLACK RECUPERADA E VALIDADA.' -ForegroundColor Green
Write-Host ('Versao: ' + [string]$manifest.version)
Write-Host ('PID: ' + [string]$proc.Id)
Write-Host 'Protecoes: SHA-256 + sintaxe + health-check + backup + rollback.'
Write-Host ('Atalho: ' + (Join-Path $Desktop 'LIGAR PONTE - REALLBLACK.cmd'))
