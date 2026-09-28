# REALLBLACK SCREEN HELPER INSTALLER
# Independently validated module installer.
$ErrorActionPreference = 'Stop'

$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge\ScreenHelper'
$ManifestUrl = 'https://raw.githubusercontent.com/realblackboss/reallblack-public-entrypoint/main/bridge/screen-helper-manifest.json'

New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null

$manifest = Invoke-RestMethod -UseBasicParsing -Uri ($ManifestUrl + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
if ([string]::IsNullOrWhiteSpace([string]$manifest.url)) { throw 'manifest_url_missing' }
if ([string]::IsNullOrWhiteSpace([string]$manifest.sha256)) { throw 'manifest_sha256_missing' }

$tmp = Join-Path $BaseDir 'screen-helper.new.ps1'
$dst = Join-Path $BaseDir 'screen-helper.ps1'
$bak = Join-Path $BaseDir 'screen-helper.last-good.ps1'

Invoke-WebRequest -UseBasicParsing -Uri ($manifest.url + '?t=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -OutFile $tmp

$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
$expected = ([string]$manifest.sha256).ToLowerInvariant()
if ($actual -ne $expected) {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  throw 'screen_helper_hash_mismatch'
}

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors) | Out-Null
if (@($errors).Count -gt 0) {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  throw 'screen_helper_syntax_invalid'
}

if (Test-Path -LiteralPath $dst) {
  Copy-Item -LiteralPath $dst -Destination $bak -Force
}
Move-Item -LiteralPath $tmp -Destination $dst -Force

Write-Host 'REALLBLACK SCREEN HELPER INSTALADO E VALIDADO.'
Write-Host ('Versao: ' + [string]$manifest.version)
Write-Host ('Arquivo: ' + $dst)
Write-Host 'Modo: LOCAL-ONLY. Sem rede, sem persistencia e sem alterar o Defender.'
