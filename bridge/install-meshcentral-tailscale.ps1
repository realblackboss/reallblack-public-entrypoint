# REALLBLACK - MeshCentral + Tailscale installer
# Transparent local install. No Defender changes. No reboot.
# Run from an elevated PowerShell window.

$ErrorActionPreference = 'Stop'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackMeshCentral'
$DataDir = Join-Path $BaseDir 'meshcentral-data'
$LogDir = Join-Path $BaseDir 'logs'
$InstallLog = Join-Path $LogDir 'install.log'
$Port = 4430

function Write-Step([string]$Message) {
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
  Add-Content -Path $InstallLog -Value $line -Encoding UTF8
  Write-Host $Message
}

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Abra o PowerShell como Administrador e execute novamente.'
  }
}

function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
  $user = [Environment]::GetEnvironmentVariable('Path','User')
  $env:Path = (($machine,$user) -join ';')
}

function Ensure-WingetPackage([string]$Id,[string]$CommandName) {
  if (Get-Command $CommandName -ErrorAction SilentlyContinue) { return }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget nao encontrado no Windows.'
  }
  Write-Step ("Instalando " + $Id + "...")
  & winget install --id $Id -e --accept-package-agreements --accept-source-agreements --silent
  if ($LASTEXITCODE -ne 0) { throw ("Falha ao instalar " + $Id) }
  Refresh-Path
}

Assert-Admin
New-Item -ItemType Directory -Force -Path $BaseDir,$DataDir,$LogDir | Out-Null

Write-Step 'Lote 1/5 - Tailscale'
Ensure-WingetPackage 'Tailscale.Tailscale' 'tailscale'

$tsJson = $null
try { $tsJson = (& tailscale status --json 2>$null) | ConvertFrom-Json } catch {}
if (-not $tsJson -or -not $tsJson.Self -or [string]::IsNullOrWhiteSpace([string]$tsJson.Self.DNSName)) {
  Write-Host ''
  Write-Host 'Tailscale precisa de login. O navegador pode abrir para autorizacao.'
  & tailscale up
  Start-Sleep -Seconds 2
  $tsJson = (& tailscale status --json 2>$null) | ConvertFrom-Json
}
if (-not $tsJson -or -not $tsJson.Self -or [string]::IsNullOrWhiteSpace([string]$tsJson.Self.DNSName)) {
  throw 'Tailscale ainda nao esta autenticado.'
}
$fqdn = ([string]$tsJson.Self.DNSName).TrimEnd('.')
Write-Step ("Tailscale OK: " + $fqdn)

Write-Step 'Lote 2/5 - Node.js LTS'
Ensure-WingetPackage 'OpenJS.NodeJS.LTS' 'node'
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
  Refresh-Path
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
  throw 'npm nao encontrado apos instalar Node.js.'
}

Write-Step 'Lote 3/5 - MeshCentral'
Push-Location $BaseDir
try {
  if (-not (Test-Path (Join-Path $BaseDir 'package.json') -PathType Leaf)) {
    & npm init -y | Out-Null
  }
  & npm install meshcentral --no-audit --no-fund
  if ($LASTEXITCODE -ne 0) { throw 'Falha no npm install meshcentral.' }
} finally {
  Pop-Location
}

$config = [ordered]@{
  '$schema' = 'https://raw.githubusercontent.com/Ylianst/MeshCentral/master/meshcentral-config-schema.json'
  settings = [ordered]@{
    cert = $fqdn
    WANonly = $true
    port = $Port
    portBind = '127.0.0.1'
    aliasPort = 443
    redirPort = 0
    AgentPong = 300
    tlsOffload = '127.0.0.1,::1'
    trustedProxy = '127.0.0.1,::1'
    SelfUpdate = $false
    AllowFraming = $false
    WebRTC = $false
  }
  domains = [ordered]@{
    '' = [ordered]@{
      title = 'REALLBLACK'
      title2 = 'Secure Bridge'
      minify = $true
      NewAccounts = $true
      localSessionRecording = $false
      userNameIsEmail = $false
      certUrl = ('https://' + $fqdn + '/')
      passwordRequirements = [ordered]@{
        min = 12
        max = 128
        upper = 1
        lower = 1
        numeric = 1
        nonalpha = 1
      }
    }
  }
}
$configPath = Join-Path $DataDir 'config.json'
$config | ConvertTo-Json -Depth 8 | Set-Content -Path $configPath -Encoding UTF8

Write-Step 'Lote 4/5 - Inicializacao persistente e backend local'
$meshEntry = Join-Path $BaseDir 'node_modules\meshcentral'
if (-not (Test-Path $meshEntry)) { throw 'MeshCentral nao foi instalado corretamente.' }

# Remove a tentativa de servico nativo caso uma execucao anterior tenha deixado estado parcial.
# MeshCentral continua persistente via Tarefa Agendada transparente, executada como SYSTEM no boot.
try {
  Push-Location $BaseDir
  $nodePath = (Get-Command node -ErrorAction Stop).Source
  $cleanup = ('"' + $nodePath + '" node_modules\meshcentral --uninstall >nul 2>&1')
  cmd.exe /d /c $cleanup | Out-Null
} catch {} finally {
  try { Pop-Location } catch {}
}

$runner = Join-Path $BaseDir 'run-meshcentral.cmd'
$meshLog = Join-Path $LogDir 'meshcentral.log'
$runnerLines = @(
  '@echo off',
  ('cd /d "' + $BaseDir + '"'),
  ('"' + $nodePath + '" node_modules\meshcentral >> "' + $meshLog + '" 2>&1')
)
Set-Content -Path $runner -Value $runnerLines -Encoding ASCII

$taskName = 'REALLBLACK-MESHCENTRAL'
try { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null } catch {}
try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}

$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/d /c "' + $runner + '"')
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'REALLBLACK MeshCentral local backend' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

$backendReady = $false
$deadline = (Get-Date).AddSeconds(45)
do {
  Start-Sleep -Seconds 1
  try {
    $tcp = New-Object Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect('127.0.0.1',$Port,$null,$null)
    if ($iar.AsyncWaitHandle.WaitOne(800) -and $tcp.Connected) { $backendReady = $true }
    $tcp.Close()
  } catch {}
} while (-not $backendReady -and (Get-Date) -lt $deadline)

if (-not $backendReady) {
  $tail = ''
  try {
    if (Test-Path $meshLog -PathType Leaf) { $tail = (@(Get-Content $meshLog -Tail 25) -join ' | ') }
  } catch {}
  throw ('MeshCentral nao abriu a porta local ' + $Port + '. LOG=' + $tail)
}

Write-Step ('Backend MeshCentral OK em 127.0.0.1:' + $Port)

Write-Step 'Lote 5/5 - Tailscale Serve privado'
& tailscale serve reset 2>$null | Out-Null
& tailscale serve --bg --https=443 ('http://127.0.0.1:' + $Port)
if ($LASTEXITCODE -ne 0) {
  throw 'Falha ao configurar Tailscale Serve. Pode ser necessario autorizar HTTPS no navegador.'
}

Start-Sleep -Seconds 3
$serveStatus = (& tailscale serve status 2>$null) -join [Environment]::NewLine

Write-Host ''
Write-Host 'MESHCENTRAL + TAILSCALE PREPARADOS.' -ForegroundColor Green
Write-Host ('URL privada: https://' + $fqdn)
Write-Host 'Acesso: somente dispositivos/autorizacoes da sua tailnet.'
Write-Host 'Primeiro acesso: crie a conta administradora imediatamente.'
Write-Host 'Depois disso, desative novos cadastros no painel.'
Write-Host 'Defender: nao alterado.'
Write-Host 'Reboot: nao realizado.'
Write-Host ''
Write-Host $serveStatus

# CI validation marker v2
