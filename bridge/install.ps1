param()

$ErrorActionPreference = 'Stop'
$Dir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$Agent = Join-Path $Dir 'desktop-folder-agent.ps1'
$Desktop = [Environment]::GetFolderPath('Desktop')

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
$ghStatus = $LASTEXITCODE

if ($ghStatus -ne 0) {
  Write-Host 'Autenticacao GitHub necessaria. O navegador sera aberto uma unica vez.'
  cmd.exe /d /c "gh auth login -h github.com -p https -w"
  $ghLogin = $LASTEXITCODE
  if ($ghLogin -ne 0) { throw 'Falha na autenticacao do GitHub.' }
}

$AgentCode = @'
$ErrorActionPreference = 'Continue'
$Repo = 'realblackboss/twitch-gpt-gemini-2026'
$Issue = 1
$Trusted = 'realblackboss'
$Desktop = [Environment]::GetFolderPath('Desktop')
$State = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge\last_comment.txt'

function Post-Bridge([string]$Body) {
  try {
    @{ body = $Body } | ConvertTo-Json -Compress | gh api --method POST "repos/$Repo/issues/$Issue/comments" --input - *> $null
  } catch {}
}

$Last = 0
if (Test-Path $State) {
  try { $Last = [long](Get-Content $State -Raw) } catch { $Last = 0 }
}

Post-Bridge ('BRIDGE_STATUS_V1' + [Environment]::NewLine + 'ONLINE|' + $env:COMPUTERNAME + '|' + (Get-Date -Format o))

while ($true) {
  try {
    $Raw = & gh api "repos/$Repo/issues/$Issue/comments?per_page=100"
    if ($LASTEXITCODE -eq 0) {
      $Comments = $Raw | ConvertFrom-Json
      foreach ($C in @($Comments | Sort-Object id)) {
        $Id = [long]$C.id
        if ($Id -le $Last) { continue }
        $Last = $Id
        Set-Content -Path $State -Value $Last -Encoding ASCII

        if ($C.user.login -ne $Trusted) { continue }
        $Body = [string]$C.body

        if ($Body.StartsWith('BRIDGE_PING_V1')) {
          Post-Bridge ('BRIDGE_PONG_V1' + [Environment]::NewLine + $env:COMPUTERNAME + '|' + (Get-Date -Format o))
          continue
        }

        if (-not $Body.StartsWith('BRIDGE_MKDIR_V1')) { continue }
        $Lines = $Body -split [Environment]::NewLine
        if ($Lines.Count -lt 2) { continue }

        try {
          $Name = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Lines[1].Trim()))
        } catch { continue }

        $Name = [IO.Path]::GetFileName($Name)
        if ([string]::IsNullOrWhiteSpace($Name)) { continue }

        $Path = Join-Path $Desktop $Name
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        Post-Bridge ('BRIDGE_RESULT_V1' + [Environment]::NewLine + 'MKDIR_OK|' + $Name + '|' + (Get-Date -Format o))
      }
    }
  } catch {}
  Start-Sleep -Seconds 10
}
'@

Set-Content -Path $Agent -Value $AgentCode -Encoding UTF8

$Startup = [Environment]::GetFolderPath('Startup')
$Launch = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $Agent + '"'

Set-Content -Path (Join-Path $Startup 'REALLBLACK-PC-BRIDGE.cmd') -Value ('@echo off' + [Environment]::NewLine + $Launch) -Encoding ASCII
Set-Content -Path (Join-Path $Desktop 'LIGAR PONTE - REALLBLACK.cmd') -Value ('@echo off' + [Environment]::NewLine + $Launch) -Encoding ASCII

Start-Process powershell.exe -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$Agent) -WindowStyle Hidden

Write-Host ''
Write-Host 'PONTE REALLBLACK INSTALADA.' -ForegroundColor Green
Write-Host ('Pasta criada: ' + (Join-Path $Desktop 'funcionando'))
Write-Host ('Atalho criado: ' + (Join-Path $Desktop 'LIGAR PONTE - REALLBLACK.cmd'))
