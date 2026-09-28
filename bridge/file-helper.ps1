# REALLBLACK FILE HELPER
# LOCAL-ONLY: bounded file operations inside approved roots.
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('ROOTS','INFO','LIST','MKDIR','COPY','MOVE','RENAME','WRITE_TEXT','DELETE_TO_RECYCLE_BIN')]
  [string]$Mode,
  [string]$Root = 'desktop',
  [string]$Path = '',
  [string]$DestinationRoot = '',
  [string]$DestinationPath = '',
  [string]$NewName = '',
  [string]$Text = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'

$BaseDir = Join-Path $env:LOCALAPPDATA 'ReallBlackBridge'
$Roots = @{
  desktop = [Environment]::GetFolderPath('Desktop')
  documents = [Environment]::GetFolderPath('MyDocuments')
  downloads = Join-Path $env:USERPROFILE 'Downloads'
  bridge = $BaseDir
}

function Resolve-SafePath([string]$RootName,[string]$RelativePath) {
  if ([string]::IsNullOrWhiteSpace($RootName)) { throw 'root_required' }
  $key = $RootName.ToLowerInvariant()
  if (-not $Roots.ContainsKey($key)) { throw 'root_not_allowed' }

  $rootPath = [IO.Path]::GetFullPath([string]$Roots[$key]).TrimEnd('\')
  if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $rootPath }
  if ([IO.Path]::IsPathRooted($RelativePath)) { throw 'absolute_path_not_allowed' }

  $full = [IO.Path]::GetFullPath((Join-Path $rootPath $RelativePath))
  if ($full -ne $rootPath -and -not $full.StartsWith($rootPath + '\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'path_escape_blocked'
  }
  return $full
}

function Result($Data) {
  [ordered]@{
    helper='REALLBLACK_FILE_HELPER'
    version=$Version
    mode='local-only'
    data=$Data
  } | ConvertTo-Json -Depth 6 -Compress
}

if ($Mode -eq 'ROOTS') {
  Result @{ roots=@($Roots.Keys | Sort-Object) }
  exit 0
}

$source = Resolve-SafePath $Root $Path

switch ($Mode) {
  'INFO' {
    if (-not (Test-Path -LiteralPath $source)) { throw 'path_not_found' }
    $i=Get-Item -LiteralPath $source -Force
    Result @{
      root=$Root; path=$Path; name=$i.Name;
      type=if($i.PSIsContainer){'dir'}else{'file'};
      length=if($i.PSIsContainer){$null}else{$i.Length};
      created=$i.CreationTime.ToString('o');
      modified=$i.LastWriteTime.ToString('o')
    }
  }
  'LIST' {
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'directory_not_found' }
    $items=@(Get-ChildItem -LiteralPath $source -Force | Sort-Object -Property @{Expression='PSIsContainer';Descending=$true},Name | Select-Object -First 300 | ForEach-Object {
      [ordered]@{name=$_.Name;type=if($_.PSIsContainer){'dir'}else{'file'};length=if($_.PSIsContainer){$null}else{$_.Length};modified=$_.LastWriteTime.ToString('o')}
    })
    Result @{root=$Root;path=$Path;count=$items.Count;items=$items}
  }
  'MKDIR' {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path_required' }
    New-Item -ItemType Directory -Force -Path $source | Out-Null
    Result @{root=$Root;path=$Path;created=$true}
  }
  'COPY' {
    if (-not (Test-Path -LiteralPath $source)) { throw 'source_not_found' }
    if ([string]::IsNullOrWhiteSpace($DestinationRoot)) { throw 'destination_root_required' }
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) { throw 'destination_path_required' }
    $dest=Resolve-SafePath $DestinationRoot $DestinationPath
    $parent=Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $source -Destination $dest -Recurse -Force
    Result @{sourceRoot=$Root;sourcePath=$Path;destinationRoot=$DestinationRoot;destinationPath=$DestinationPath;copied=$true}
  }
  'MOVE' {
    if (-not (Test-Path -LiteralPath $source)) { throw 'source_not_found' }
    if ([string]::IsNullOrWhiteSpace($DestinationRoot)) { throw 'destination_root_required' }
    if ([string]::IsNullOrWhiteSpace($DestinationPath)) { throw 'destination_path_required' }
    $dest=Resolve-SafePath $DestinationRoot $DestinationPath
    $parent=Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Move-Item -LiteralPath $source -Destination $dest -Force
    Result @{sourceRoot=$Root;sourcePath=$Path;destinationRoot=$DestinationRoot;destinationPath=$DestinationPath;moved=$true}
  }
  'RENAME' {
    if (-not (Test-Path -LiteralPath $source)) { throw 'source_not_found' }
    if ([string]::IsNullOrWhiteSpace($NewName)) { throw 'new_name_required' }
    if ($NewName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'invalid_new_name' }
    if ($NewName -match '[\\/]') { throw 'new_name_must_not_contain_path' }
    Rename-Item -LiteralPath $source -NewName $NewName -Force
    Result @{root=$Root;path=$Path;newName=$NewName;renamed=$true}
  }
  'WRITE_TEXT' {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path_required' }
    $bytes=[Text.Encoding]::UTF8.GetByteCount([string]$Text)
    if ($bytes -gt 262144) { throw 'text_too_large' }
    $parent=Split-Path -Parent $source
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($source,[string]$Text,(New-Object Text.UTF8Encoding($false)))
    Result @{root=$Root;path=$Path;bytes=$bytes;written=$true}
  }
  'DELETE_TO_RECYCLE_BIN' {
    if (-not (Test-Path -LiteralPath $source)) { throw 'path_not_found' }
    $rootPath=(Resolve-SafePath $Root '').TrimEnd('\')
    if ($source -eq $rootPath) { throw 'cannot_delete_root' }
    Add-Type -AssemblyName Microsoft.VisualBasic
    if (Test-Path -LiteralPath $source -PathType Container) {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
        $source,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
      )
    } else {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
        $source,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
      )
    }
    Result @{root=$Root;path=$Path;recycled=$true}
  }
}
