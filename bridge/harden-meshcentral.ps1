# REALLBLACK MeshCentral hardening
# Disables new account registration, validates persistence and Tailscale Serve.
# No reboot. No Defender changes.

$ErrorActionPreference='Stop'
$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackMeshCentral'
$DataDir = Join-Path $BaseDir 'meshcentral-data'
$ConfigPath = Join-Path $DataDir 'config.json'
$TaskName = 'REALLBLACK-MESHCENTRAL'
$Port = 4430

function Test-Tcp([string]$HostName,[int]$PortNumber) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect($HostName,$PortNumber,$null,$null)
    $ok = $iar.AsyncWaitHandle.WaitOne(1000) -and $c.Connected
    $c.Close()
    return $ok
  } catch { return $false }
}

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
  throw "Config do MeshCentral nao encontrado: $ConfigPath"
}

# Windows PowerShell 5.1 pode falhar no ConvertFrom-Json quando o MeshCentral usa
# uma chave de dominio vazia (""). Edite somente a propriedade NewAccounts no texto bruto.
$raw = Get-Content $ConfigPath -Raw
if ([string]::IsNullOrWhiteSpace($raw)) { throw 'config.json vazio.' }

$pattern = '("NewAccounts"\s*:\s*)(true|false)'
if ($raw -notmatch $pattern) { throw 'Propriedade NewAccounts nao encontrada no config.json.' }

$updated = [regex]::Replace($raw, $pattern, '$1false', 1)
if ($updated -eq $raw -and $raw -notmatch '"NewAccounts"\s*:\s*false') {
  throw 'Nao foi possivel alterar NewAccounts.'
}

$backup = $ConfigPath + '.pre-harden-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak'
Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
[IO.File]::WriteAllText($ConfigPath, $updated, (New-Object Text.UTF8Encoding -ArgumentList $false))

try {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
  Start-Sleep -Seconds 1
  Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
} catch {
  throw ('Falha ao reiniciar tarefa do MeshCentral: ' + $_.Exception.Message)
}

$deadline=(Get-Date).AddSeconds(30)
do {
  Start-Sleep -Seconds 1
  $ready = Test-Tcp '127.0.0.1' $Port
} while (-not $ready -and (Get-Date) -lt $deadline)

if (-not $ready) { throw 'MeshCentral nao respondeu em 127.0.0.1:4430 apos hardening.' }

$serve = (& tailscale serve status 2>$null) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0 -or $serve -notmatch '127\.0\.0\.1:4430') {
  throw 'Tailscale Serve nao aponta para 127.0.0.1:4430.'
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
$ts = $null
try { $ts = (& tailscale status --json 2>$null) | ConvertFrom-Json } catch {}
$fqdn = if ($ts -and $ts.Self) { ([string]$ts.Self.DNSName).TrimEnd('.') } else { '' }

Write-Host ''
Write-Host 'REALLBLACK MESHCENTRAL HARDENED.' -ForegroundColor Green
Write-Host 'Novos cadastros: BLOQUEADOS'
Write-Host ('Tarefa persistente: ' + $task.State)
Write-Host ('Backend local: 127.0.0.1:' + $Port + ' OK')
if ($fqdn) { Write-Host ('URL privada: https://' + $fqdn) }
Write-Host 'Defender: nao alterado'
Write-Host 'Reboot: nao realizado'
