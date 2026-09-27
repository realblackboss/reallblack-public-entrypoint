param()

$ErrorActionPreference = 'Stop'
$Dir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$Agent = Join-Path $Dir 'agent-v2.ps1'
$Desktop = [Environment]::GetFolderPath('Desktop')
$Startup = [Environment]::GetFolderPath('Startup')
$OldStartup = Join-Path $Startup 'REALLBLACK-PC-BRIDGE.cmd'
$ManifestUrl = 'https://raw.githubusercontent.com/realblackboss/reallblack-public-entrypoint/main/bridge/manifest-v2.json'

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

$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$manifest = Invoke-RestMethod -UseBasicParsing -Uri ($ManifestUrl + '?t=' + $stamp) -TimeoutSec 15
if ([string]::IsNullOrWhiteSpace([string]$manifest.url) -or [string]::IsNullOrWhiteSpace([string]$manifest.sha256)) {
  throw 'Manifesto da ponte invalido.'
}

$tmpAgent = Join-Path $Dir 'agent-v2.download.ps1'
Invoke-WebRequest -UseBasicParsing -Uri ([string]$manifest.url) -OutFile $tmpAgent -TimeoutSec 20
$downloadHash = (Get-FileHash $tmpAgent -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedHash = ([string]$manifest.sha256).ToLowerInvariant()
if ($downloadHash -ne $expectedHash) {
  Remove-Item $tmpAgent -Force -ErrorAction SilentlyContinue
  throw 'Falha de integridade: hash da ponte nao confere.'
}
Move-Item $tmpAgent $Agent -Force
Remove-Item $OldStartup -Force -ErrorAction SilentlyContinue

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object {
    $_.CommandLine -like '*ReallBlackBridge*desktop-folder-agent.ps1*' -or
    $_.CommandLine -like '*ReallBlackBridge*agent-v2.ps1*'
  } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force } catch {}
  }

Remove-Item (Join-Path $Dir 'state-v2.json') -Force -ErrorAction SilentlyContinue

$Launch = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Agent + '"'
Set-Content -Path (Join-Path $Startup 'REALLBLACK-PC-BRIDGE-V2.cmd') -Value ('@echo off' + [Environment]::NewLine + $Launch) -Encoding ASCII
Set-Content -Path (Join-Path $Desktop 'LIGAR PONTE - REALLBLACK.cmd') -Value ('@echo off' + [Environment]::NewLine + $Launch) -Encoding ASCII

try {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Agent + '"')
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName 'REALLBLACK-PC-BRIDGE-V2' -Action $action -Trigger $trigger -Settings $settings -Description 'REALLBLACK Bridge V2 fast resilient agent' -Force | Out-Null
} catch {}

Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Agent) -WindowStyle Hidden

Write-Host ''
Write-Host 'PONTE REALLBLACK V2 INSTALADA E INICIADA.' -ForegroundColor Green
Write-Host 'Velocidade: 1 s ativo / 4 s ocioso com ETag e backoff.'
Write-Host 'Autostart: Startup + tarefa agendada de recuperacao.'
Write-Host 'Atualizacao: manifesto versionado + SHA-256, checado automaticamente.'
Write-Host ('Agente: ' + $Agent)
Write-Host ('Versao: ' + [string]$manifest.version)
Write-Host ('Atalho: ' + (Join-Path $Desktop 'LIGAR PONTE - REALLBLACK.cmd'))
