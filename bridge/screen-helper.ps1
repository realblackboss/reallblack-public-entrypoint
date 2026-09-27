# REALLBLACK SCREEN HELPER
# LOCAL-ONLY: no network transport.
param(
  [ValidateSet('INFO','CAPTURE')]
  [string]$Mode = 'INFO',
  [int]$ScreenIndex = 0,
  [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'REALLBLACK_CAPTURES'
}

$screens = @([System.Windows.Forms.Screen]::AllScreens)
if ($screens.Count -lt 1) { throw 'no_screens_detected' }
if ($ScreenIndex -lt 0 -or $ScreenIndex -ge $screens.Count) { throw 'screen_index_out_of_range' }

if ($Mode -eq 'INFO') {
  $items = @()
  for ($i = 0; $i -lt $screens.Count; $i++) {
    $s = $screens[$i]
    $items += [ordered]@{
      index = $i
      device = $s.DeviceName
      primary = $s.Primary
      x = $s.Bounds.X
      y = $s.Bounds.Y
      width = $s.Bounds.Width
      height = $s.Bounds.Height
    }
  }

  [ordered]@{
    helper = 'REALLBLACK_SCREEN_HELPER'
    version = $Version
    mode = 'local-only'
    network = $false
    screens = $items
    count = $items.Count
  } | ConvertTo-Json -Depth 4
  exit 0
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$screen = $screens[$ScreenIndex]
$b = $screen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$graphics = [System.Drawing.Graphics]::FromImage($bmp)

try {
  $graphics.CopyFromScreen($b.X, $b.Y, 0, 0, $b.Size)
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $file = Join-Path $OutputDir ("screen-{0}-{1}.png" -f $ScreenIndex,$stamp)
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)

  $item = Get-Item -LiteralPath $file -ErrorAction Stop
  [ordered]@{
    helper = 'REALLBLACK_SCREEN_HELPER'
    version = $Version
    mode = 'local-only'
    network = $false
    screenIndex = $ScreenIndex
    width = $b.Width
    height = $b.Height
    path = $item.FullName
    bytes = $item.Length
    created = $item.CreationTime.ToString('o')
  } | ConvertTo-Json -Compress
} finally {
  $graphics.Dispose()
  $bmp.Dispose()
}
