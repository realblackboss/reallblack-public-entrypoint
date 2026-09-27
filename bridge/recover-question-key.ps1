$ErrorActionPreference = 'Stop'

$installer = 'https://raw.githubusercontent.com/realblackboss/reallblack-public-entrypoint/main/bridge/install.ps1'
Invoke-RestMethod -UseBasicParsing -Uri $installer | Invoke-Expression

$startup = [Environment]::GetFolderPath('Startup')
$scriptPath = Join-Path $startup 'CORRIGIR_INTERROGACAO.ahk'

$ahk = @'
#Requires AutoHotkey v2.0
#SingleInstance Force

SC073::SendText "/"
+SC073::SendText "?"
'@

Set-Content -LiteralPath $scriptPath -Value $ahk -Encoding UTF8

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Name -match '^AutoHotkey(64|UX)?\.exe$' -and
    $_.CommandLine -like '*CORRIGIR_INTERROGACAO.ahk*'
  } |
  ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
  }

$candidates = @(
  'C:\Program Files (x86)\AutoHotkey\v2\AutoHotkey64.exe',
  'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
)

$exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { throw 'AutoHotkey v2 nao encontrado.' }

Start-Process -FilePath $exe -ArgumentList @($scriptPath)
Start-Sleep -Milliseconds 700

$running = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.Name -eq 'AutoHotkey64.exe' -and
    $_.CommandLine -like '*CORRIGIR_INTERROGACAO.ahk*'
  }

if (-not $running) { throw 'O reparo da tecla nao iniciou.' }

Write-Host ''
Write-Host 'PONTE RECUPERADA E CORRECAO SC073 ATIVA.' -ForegroundColor Green
Write-Host 'Teste / e ? agora.'
