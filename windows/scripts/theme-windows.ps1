if (-not (Get-Command Read-DreamSkinUtf8File -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'config-utf8.ps1')
}

$script:DreamSkinMaxImageBytes = 16 * 1024 * 1024
$script:DreamSkinMaxVideoBytes = 128 * 1024 * 1024

function Assert-DreamSkinNoReparseComponents {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetPathRoot($fullPath)
  $current = $fullPath
  while ($true) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Managed Dream Skin path contains a junction or symbolic link: $current"
      }
    }
    $currentNormalized = $current.TrimEnd('\')
    $rootNormalized = $root.TrimEnd('\')
    if ($currentNormalized.Equals($rootNormalized, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = [System.IO.Path]::GetDirectoryName($current)
    if (-not $parent -or $parent.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $current = $parent
  }
}

function Ensure-DreamSkinManagedDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
  if (-not ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      $fullPath.StartsWith($fullRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))) {
    throw "Managed Dream Skin path escaped its state root: $fullPath"
  }
  Assert-DreamSkinNoReparseComponents -Path $fullPath
  if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
    throw "Managed Dream Skin path is a file, not a directory: $fullPath"
  }
  New-Item -ItemType Directory -Force -Path $fullPath | Out-Null
  Assert-DreamSkinNoReparseComponents -Path $fullPath
  if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
    throw "Managed Dream Skin directory could not be created: $fullPath"
  }
}

function Get-DreamSkinValidatedImageMetadata {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Get-Command Get-DreamSkinNodeRuntime -ErrorAction SilentlyContinue)) {
    throw 'Node.js runtime validation is unavailable for image metadata checks.'
  }
  $node = Get-DreamSkinNodeRuntime
  $metadataScript = Join-Path $PSScriptRoot 'image-metadata.mjs'
  $output = @(& $node.Path $metadataScript '--check' ([System.IO.Path]::GetFullPath($Path)) 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Image metadata is invalid or exceeds the 16384px / 50MP safety limit: $Path"
  }
  try { $metadata = ($output -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch {
    throw "Image metadata helper returned invalid output: $Path"
  }
  if ($null -eq $metadata -or $null -eq $metadata.width -or $null -eq $metadata.height) {
    throw "Image metadata is invalid or exceeds the 16384px / 50MP safety limit: $Path"
  }
}

function Assert-DreamSkinImageFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$SkipImageMetadata
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "Image does not exist: $fullPath"
  }
  $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
  if ($extension -notin @('.png', '.jpg', '.jpeg', '.webp')) {
    throw "Unsupported image format: $extension"
  }
  $length = (Get-Item -LiteralPath $fullPath -Force).Length
  if ($length -lt 1) { throw 'Theme image cannot be empty.' }
  if ($length -gt $script:DreamSkinMaxImageBytes) {
    throw 'Theme image exceeds the 16 MB limit.'
  }
  if (-not $SkipImageMetadata) {
    Get-DreamSkinValidatedImageMetadata -Path $fullPath
  }
}

function Assert-DreamSkinVideoFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "Video does not exist: $fullPath"
  }
  $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
  if ($extension -notin @('.mp4', '.webm')) {
    throw "Unsupported video format: $extension"
  }
  $length = (Get-Item -LiteralPath $fullPath -Force).Length
  if ($length -lt 1) { throw 'Theme video cannot be empty.' }
  if ($length -gt $script:DreamSkinMaxVideoBytes) {
    throw 'Theme video exceeds the 128 MB limit.'
  }
  $header = New-Object byte[] 12
  $stream = [System.IO.File]::Open(
    $fullPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
  )
  try { $read = $stream.Read($header, 0, $header.Length) } finally { $stream.Dispose() }
  $valid = if ($extension -ceq '.mp4') {
    $read -ge 12 -and [System.Text.Encoding]::ASCII.GetString($header, 4, 4) -ceq 'ftyp'
  } else {
    $read -ge 4 -and $header[0] -eq 0x1a -and $header[1] -eq 0x45 -and
      $header[2] -eq 0xdf -and $header[3] -eq 0xa3
  }
  if (-not $valid) { throw "Video container signature does not match $extension" }
}

function Get-DreamSkinMediaType {
  param([Parameter(Mandatory = $true)][string]$Path)
  $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
  if ($extension -in @('.png', '.jpg', '.jpeg', '.webp')) { return 'image' }
  if ($extension -in @('.mp4', '.webm')) { return 'video' }
  throw "Unsupported theme media format: $extension"
}

function ConvertTo-DreamSkinMediaOpacity {
  param(
    [AllowNull()][object]$Value,
    [double]$Default = 1
  )
  if ($null -eq $Value -or "$Value" -eq '') { return $Default }
  try { $opacity = [double]$Value } catch { throw 'Theme media opacity must be a number between 0 and 1.' }
  if ([double]::IsNaN($opacity) -or [double]::IsInfinity($opacity) -or
    $opacity -lt 0 -or $opacity -gt 1) {
    throw 'Theme media opacity must be a number between 0 and 1.'
  }
  return $opacity
}

function Get-DreamSkinThemeMediaOpacity {
  param([AllowNull()][object]$Theme)
  if ($null -eq $Theme -or $null -eq $Theme.media) { return [double]1 }
  $property = $Theme.media.PSObject.Properties['opacity']
  if ($null -eq $property) { return [double]1 }
  return ConvertTo-DreamSkinMediaOpacity -Value $property.Value
}

function Get-DreamSkinThemeMediaRevealPercent {
  param([AllowNull()][object]$Theme)
  $opacity = Get-DreamSkinThemeMediaOpacity -Theme $Theme
  return [int][math]::Round($opacity * 100)
}

function ConvertTo-DreamSkinMediaOpacityFromRevealPercent {
  param([Parameter(Mandatory = $true)][object]$Percent)
  try { $reveal = [double]$Percent } catch {
    throw 'Theme wallpaper reveal must be a number between 0 and 100.'
  }
  if ([double]::IsNaN($reveal) -or [double]::IsInfinity($reveal) -or
    $reveal -lt 0 -or $reveal -gt 100) {
    throw 'Theme wallpaper reveal must be a number between 0 and 100.'
  }
  return [double]($reveal / 100)
}

function Assert-DreamSkinMediaFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$SkipImageMetadata
  )
  $mediaType = Get-DreamSkinMediaType -Path $Path
  if ($mediaType -ceq 'video') {
    Assert-DreamSkinVideoFile -Path $Path
  } else {
    Assert-DreamSkinImageFile -Path $Path -SkipImageMetadata:$SkipImageMetadata
  }
  return $mediaType
}

function Get-DreamSkinThemePaths {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  $fullRoot = [System.IO.Path]::GetFullPath($StateRoot)
  return [pscustomobject]@{
    Root = $fullRoot
    Active = Join-Path $fullRoot 'active-theme'
    Saved = Join-Path $fullRoot 'themes'
    Images = Join-Path $fullRoot 'images'
    MediaCache = Join-Path $fullRoot 'media-cache'
    PauseFile = Join-Path $fullRoot 'paused'
    State = Join-Path $fullRoot 'state.json'
  }
}

function Test-DreamSkinThemePathWithin {
  param([string]$Path, [string]$Root)
  if (-not $Path -or -not $Root) { return $false }
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $inside = $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      $fullPath.StartsWith($fullRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { return $false }

    $current = $fullPath.TrimEnd('\')
    while ($true) {
      if (-not (Test-Path -LiteralPath $current)) { return $false }
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
      }
      if ($current.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
      $parent = [System.IO.Path]::GetDirectoryName($current)
      if (-not $parent -or $parent.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
      }
      $current = $parent.TrimEnd('\')
    }
  } catch {
    return $false
  }
}

function Test-DreamSkinThemeSchemaV1 {
  param([AllowNull()][object]$Theme)
  if ($null -eq $Theme) { return $false }
  $schemaProperty = $Theme.PSObject.Properties['schemaVersion']
  if ($null -eq $schemaProperty -or $schemaProperty.Value -isnot [System.ValueType] -or
      $schemaProperty.Value -is [bool]) {
    return $false
  }
  try {
    return [double]$schemaProperty.Value -eq 1
  } catch {
    return $false
  }
}

function Get-DreamSkinThemeStateRoot {
  param([Parameter(Mandatory = $true)][string]$ThemeDirectory)
  $directory = [System.IO.Path]::GetFullPath($ThemeDirectory).TrimEnd('\')
  if ([System.IO.Path]::GetFileName($directory) -ceq 'active-theme') {
    return [System.IO.Path]::GetDirectoryName($directory)
  }
  $parent = [System.IO.Path]::GetDirectoryName($directory)
  if ($parent -and [System.IO.Path]::GetFileName($parent) -ceq 'themes') {
    return [System.IO.Path]::GetDirectoryName($parent)
  }
  return $null
}

function Resolve-DreamSkinPerformanceProxy {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDirectory,
    [Parameter(Mandatory = $true)][object]$Theme
  )
  if ($null -eq $Theme.media) { return $null }
  $property = $Theme.media.PSObject.Properties['proxy']
  if ($null -eq $property -or -not "$($property.Value)") { return $null }
  $relative = "$($property.Value)"
  if ([System.IO.Path]::IsPathRooted($relative)) {
    throw 'Theme performance proxy must be a relative state path.'
  }
  $normalized = $relative.Replace('/', '\')
  if (-not $normalized.StartsWith('media-cache\', [System.StringComparison]::OrdinalIgnoreCase) -or
      $normalized.Contains('..')) {
    throw 'Theme performance proxy must remain inside media-cache.'
  }
  $stateRoot = Get-DreamSkinThemeStateRoot -ThemeDirectory $ThemeDirectory
  if (-not $stateRoot) { throw 'Theme performance proxy requires a managed theme directory.' }
  $cacheRoot = Join-Path $stateRoot 'media-cache'
  $proxyPath = [System.IO.Path]::GetFullPath((Join-Path $stateRoot $normalized))
  if (-not (Test-DreamSkinThemePathWithin -Path $proxyPath -Root $cacheRoot)) {
    throw 'Theme performance proxy is unavailable or escaped media-cache.'
  }
  if ((Assert-DreamSkinMediaFile -Path $proxyPath) -cne 'video') {
    throw 'Theme performance proxy must be an MP4 or WebM video.'
  }
  return $proxyPath
}

function Test-DreamSkinWallpaperEngineContentRoot {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $suffix = [System.IO.Path]::Combine('steamapps', 'workshop', 'content', '431960')
    return $fullPath.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Test-DreamSkinLoopbackStreamUrl {
  param([AllowNull()][string]$Url)
  if (-not $Url -or $Url.Length -gt 400) { return $false }
  try {
    $uri = [System.Uri]::new($Url, [System.UriKind]::Absolute)
    $loopback = $uri.Host -in @('127.0.0.1', 'localhost', '::1')
    return $uri.Scheme -ceq 'http' -and $loopback -and -not $uri.IsDefaultPort -and
      -not $uri.UserInfo -and -not $uri.Query -and -not $uri.Fragment -and
      $uri.AbsolutePath -cmatch '^/[A-Za-z0-9_-]{16,128}/stream\.mp4$'
  } catch {
    return $false
  }
}

function Get-DreamSkinWallpaperEngineReference {
  param([AllowNull()][object]$Theme)
  if ($null -eq $Theme -or $null -eq $Theme.media) { return $null }
  $sourceProperty = $Theme.media.PSObject.Properties['source']
  if ($null -eq $sourceProperty -or "$($sourceProperty.Value)" -cne 'wallpaper-engine-local') {
    return $null
  }
  $workshopIdProperty = $Theme.media.PSObject.Properties['workshopId']
  $workshopRootProperty = $Theme.media.PSObject.Properties['workshopRoot']
  $relativePathProperty = $Theme.media.PSObject.Properties['relativePath']
  if ($null -eq $workshopIdProperty -or $null -eq $workshopRootProperty -or
      $null -eq $relativePathProperty) {
    throw 'Wallpaper Engine media reference is incomplete.'
  }
  $workshopId = "$($workshopIdProperty.Value)"
  $workshopRoot = "$($workshopRootProperty.Value)"
  $relativePath = "$($relativePathProperty.Value)"
  if ($workshopId -notmatch '^\d{1,20}$' -or
      -not [System.IO.Path]::IsPathRooted($workshopRoot) -or
      -not (Test-DreamSkinWallpaperEngineContentRoot -Path $workshopRoot) -or
      -not $relativePath -or [System.IO.Path]::IsPathRooted($relativePath)) {
    throw 'Wallpaper Engine media reference is invalid.'
  }
  $fullWorkshopRoot = [System.IO.Path]::GetFullPath($workshopRoot)
  $workshopDirectory = [System.IO.Path]::GetFullPath((Join-Path $fullWorkshopRoot $workshopId))
  if (-not (Test-DreamSkinThemePathWithin -Path $workshopDirectory -Root $fullWorkshopRoot)) {
    throw 'Wallpaper Engine Workshop item is unavailable or escaped its content directory.'
  }
  $mediaPath = [System.IO.Path]::GetFullPath((Join-Path $workshopDirectory $relativePath))
  if (-not (Test-DreamSkinThemePathWithin -Path $mediaPath -Root $workshopDirectory)) {
    throw 'Wallpaper Engine media is unavailable or escaped its item directory.'
  }
  $mediaType = Assert-DreamSkinMediaFile -Path $mediaPath
  if ($mediaType -cne 'video') {
    throw 'Wallpaper Engine direct references only support MP4 or WebM video media.'
  }
  return [pscustomobject]@{
    WorkshopRoot = $fullWorkshopRoot
    WorkshopDirectory = $workshopDirectory
    WorkshopId = $workshopId
    RelativePath = $relativePath
    MediaPath = $mediaPath
    MediaType = $mediaType
  }
}

function Read-DreamSkinWallpaperEngineProject {
  param([Parameter(Mandatory = $true)][string]$ProjectDirectory)
  $directory = [System.IO.Path]::GetFullPath($ProjectDirectory)
  $workshopId = Split-Path -Leaf $directory
  $workshopRoot = Split-Path -Parent $directory
  if ($workshopId -notmatch '^\d{1,20}$' -or
      -not (Test-DreamSkinWallpaperEngineContentRoot -Path $workshopRoot) -or
      -not (Test-DreamSkinThemePathWithin -Path $directory -Root $workshopRoot)) {
    throw 'Wallpaper Engine project must be inside steamapps\\workshop\\content\\431960\\<WorkshopID>.'
  }
  $projectPath = Join-Path $directory 'project.json'
  if (-not (Test-DreamSkinThemePathWithin -Path $projectPath -Root $directory)) {
    throw 'Wallpaper Engine project metadata is missing or unsafe.'
  }
  try {
    $project = (Read-DreamSkinUtf8File -Path $projectPath) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Wallpaper Engine project metadata is invalid JSON: $projectPath"
  }
  $projectType = "$($project.type)".Trim().ToLowerInvariant()
  if ($null -eq $project -or $projectType -notin @('video', 'scene')) {
    throw 'Wallpaper Engine project must be a video or scene wallpaper.'
  }
  if ($projectType -ceq 'scene') {
    $mediaPath = [System.IO.Path]::GetFullPath((Join-Path $directory 'scene.pkg'))
    if (-not (Test-DreamSkinThemePathWithin -Path $mediaPath -Root $directory) -or
        -not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
      throw 'Wallpaper Engine scene.pkg is missing or escaped its project directory.'
    }
    Assert-DreamSkinNoReparseComponents -Path $mediaPath
    $mediaType = 'scene'
  } else {
    if (-not $project.file -or [System.IO.Path]::IsPathRooted("$($project.file)")) {
      throw 'Wallpaper Engine video project must declare a relative video file.'
    }
    $mediaPath = [System.IO.Path]::GetFullPath((Join-Path $directory "$($project.file)"))
    if (-not (Test-DreamSkinThemePathWithin -Path $mediaPath -Root $directory)) {
      throw 'Wallpaper Engine video file is missing or escaped its project directory.'
    }
    $mediaType = Assert-DreamSkinMediaFile -Path $mediaPath
    if ($mediaType -cne 'video') {
      throw 'Wallpaper Engine project file must be MP4 or WebM.'
    }
  }
  return [pscustomobject]@{
    WorkshopRoot = [System.IO.Path]::GetFullPath($workshopRoot)
    WorkshopDirectory = $directory
    WorkshopId = $workshopId
    RelativePath = $mediaPath.Substring($directory.TrimEnd('\').Length).TrimStart('\')
    MediaPath = $mediaPath
    MediaType = $mediaType
    Name = if ($project.title) { "$($project.title)" } else { $workshopId }
  }
}

function Get-DreamSkinWallpaperEngineReferenceFromMediaPath {
  param([Parameter(Mandatory = $true)][string]$MediaPath)
  $fullMediaPath = [System.IO.Path]::GetFullPath($MediaPath)
  $mediaType = Assert-DreamSkinMediaFile -Path $fullMediaPath
  if ($mediaType -cne 'video') {
    throw 'Wallpaper Engine direct references only support MP4 or WebM video media.'
  }
  $current = Split-Path -Parent $fullMediaPath
  while ($current) {
    $workshopId = Split-Path -Leaf $current
    $workshopRoot = Split-Path -Parent $current
    if ($workshopId -match '^\d{1,20}$' -and
        (Test-DreamSkinWallpaperEngineContentRoot -Path $workshopRoot) -and
        (Test-DreamSkinThemePathWithin -Path $current -Root $workshopRoot) -and
        (Test-DreamSkinThemePathWithin -Path $fullMediaPath -Root $current)) {
      return [pscustomobject]@{
        WorkshopRoot = [System.IO.Path]::GetFullPath($workshopRoot)
        WorkshopDirectory = [System.IO.Path]::GetFullPath($current)
        WorkshopId = $workshopId
        RelativePath = $fullMediaPath.Substring($current.TrimEnd('\').Length).TrimStart('\')
        MediaPath = $fullMediaPath
        MediaType = $mediaType
      }
    }
    $parent = Split-Path -Parent $current
    if (-not $parent -or $parent -eq $current) { break }
    $current = $parent
  }
  throw 'Wallpaper Engine media must be inside steamapps\workshop\content\431960\<WorkshopID>.'
}

function Test-DreamSkinWallpaperEngineDisplayName {
  param([AllowNull()][string]$Value)
  if (-not $Value) { return $false }
  $trimmed = $Value.Trim()
  return $trimmed.Length -gt 0 -and $trimmed.Length -le 120 -and
    $trimmed -notmatch '[\u0000-\u001f\ufffd]' -and $trimmed -notmatch '锟'
}

function Get-DreamSkinWallpaperEngineDisplayName {
  param(
    [Parameter(Mandatory = $true)][object]$Reference,
    [AllowNull()][object]$Project
  )
  $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Reference.MediaPath)
  $title = if ($Project -and $Project.title) { "$($Project.title)" } else { $null }
  if (-not (Test-DreamSkinWallpaperEngineDisplayName -Value $title)) { $title = $null }
  if (-not (Test-DreamSkinWallpaperEngineDisplayName -Value $fileName)) {
    $fileName = "Wallpaper Engine $($Reference.WorkshopId)"
  }
  if ($title -and $Project -and $Project.file -and
      "$($Project.file)" -ceq $Reference.RelativePath) {
    return $title.Trim()
  }
  if ($title) { return ($title.Trim() + ' · ' + $fileName.Trim()) }
  return $fileName.Trim()
}

function Get-DreamSkinSteamLibraryPaths {
  param([string]$SteamLibraryPath)
  $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $addPath = {
    param([AllowNull()][string]$Candidate)
    if (-not $Candidate -or -not [System.IO.Path]::IsPathRooted($Candidate)) { return }
    try {
      $fullPath = [System.IO.Path]::GetFullPath($Candidate)
      if (Test-Path -LiteralPath (Join-Path $fullPath 'steamapps') -PathType Container) {
        $null = $paths.Add($fullPath)
      }
    } catch {}
  }
  if ($SteamLibraryPath) {
    & $addPath $SteamLibraryPath
  } else {
    foreach ($candidate in @(
      'C:\Program Files (x86)\Steam',
      'C:\Program Files\Steam'
    )) {
      & $addPath $candidate
    }
    try {
      & $addPath ((Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath)
    } catch {}
  }
  foreach ($libraryPath in @($paths)) {
    $libraryFolders = Join-Path $libraryPath 'steamapps\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $libraryFolders -PathType Leaf)) { continue }
    try {
      $vdf = [System.IO.File]::ReadAllText($libraryFolders)
      foreach ($match in [regex]::Matches($vdf, '(?im)"path"\s+"((?:\\\\|[^"])*)"')) {
        $decoded = $match.Groups[1].Value -replace '\\\\', '\'
        & $addPath $decoded
      }
    } catch {}
  }
  return @($paths | Sort-Object)
}

function Get-DreamSkinWallpaperEngineProjects {
  param([string]$SteamLibraryPath)
  $projects = @()
  foreach ($libraryPath in Get-DreamSkinSteamLibraryPaths -SteamLibraryPath $SteamLibraryPath) {
    $workshopRoot = Join-Path $libraryPath 'steamapps\workshop\content\431960'
    if (-not (Test-DreamSkinWallpaperEngineContentRoot -Path $workshopRoot) -or
        -not (Test-Path -LiteralPath $workshopRoot -PathType Container)) {
      continue
    }
    foreach ($directory in Get-ChildItem -LiteralPath $workshopRoot -Directory -Force -ErrorAction SilentlyContinue) {
      if ($directory.Name -notmatch '^\d{1,20}$' -or
           ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        continue
      }
      try {
        # A Workshop item is one Wallpaper Engine wallpaper.  Do not enumerate
        # every embedded asset: Web/Scene projects commonly contain dozens of
        # loop videos, which would appear as duplicate entries and cannot retain
        # their original effects when directly referenced by Codex.
        $reference = Read-DreamSkinWallpaperEngineProject -ProjectDirectory $directory.FullName
        $name = "$($reference.Name)"
        if (-not (Test-DreamSkinWallpaperEngineDisplayName -Value $name)) {
          $name = [System.IO.Path]::GetFileNameWithoutExtension($reference.MediaPath)
        }
        if (-not (Test-DreamSkinWallpaperEngineDisplayName -Value $name)) {
          $name = "Wallpaper Engine $($reference.WorkshopId)"
        }
        $projects += [pscustomobject]@{
          WorkshopId = $reference.WorkshopId
          Name = $name.Trim()
          WorkshopRoot = $reference.WorkshopRoot
          ProjectDirectory = $reference.WorkshopDirectory
          RelativePath = $reference.RelativePath
          MediaPath = $reference.MediaPath
          MediaType = $reference.MediaType
          Length = ([System.IO.FileInfo]::new($reference.MediaPath)).Length
        }
      } catch {}
    }
  }
  return @($projects | Sort-Object Name, WorkshopId, MediaPath)
}

function Read-DreamSkinTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDirectory,
    [switch]$SkipImageMetadata
  )
  $directory = [System.IO.Path]::GetFullPath($ThemeDirectory)
  Assert-DreamSkinNoReparseComponents -Path $directory
  $themePath = Join-Path $directory 'theme.json'
  Assert-DreamSkinNoReparseComponents -Path $themePath
  if (-not (Test-Path -LiteralPath $themePath -PathType Leaf)) {
    throw "Theme metadata is missing: $themePath"
  }
  try {
    $theme = (Read-DreamSkinUtf8File -Path $themePath) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Theme metadata is invalid JSON: $themePath"
  }
  if ($null -eq $theme -or $theme -is [string] -or $theme -is [array] -or
      -not (Test-DreamSkinThemeSchemaV1 -Theme $theme) -or -not $theme.image) {
    throw "Theme metadata must be a schemaVersion 1 object with a relative media path: $themePath"
  }
  $media = "$($theme.image)"
  if ([System.IO.Path]::IsPathRooted($media)) { throw 'Theme media path must be relative.' }
  $reference = Get-DreamSkinWallpaperEngineReference -Theme $theme
  $imagePath = $null
  if ($null -ne $reference) {
    $declaredMediaPath = [System.IO.Path]::GetFullPath((Join-Path $reference.WorkshopDirectory $media))
    if ($declaredMediaPath -ine $reference.MediaPath) {
      throw 'Theme image must match its Wallpaper Engine relative media path.'
    }
    $imagePath = $reference.MediaPath
    $mediaPath = Resolve-DreamSkinPerformanceProxy -ThemeDirectory $directory -Theme $theme
    if (-not $mediaPath) { $mediaPath = $imagePath }
    $mediaType = $reference.MediaType
  } else {
    $mediaPath = [System.IO.Path]::GetFullPath((Join-Path $directory $media))
    if (-not (Test-DreamSkinThemePathWithin -Path $mediaPath -Root $directory) -or
      -not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
      throw 'Theme media must remain inside its theme directory and exist.'
    }
    $mediaType = Assert-DreamSkinMediaFile -Path $mediaPath -SkipImageMetadata:$SkipImageMetadata
    $imagePath = $mediaPath
  }
  $declaredMediaType = if ($theme.media -and $theme.media.type) {
    "$($theme.media.type)"
  } else {
    $mediaType
  }
  if ($declaredMediaType -ceq 'scene') {
    if ($mediaType -cne 'image' -or
        -not (Test-DreamSkinLoopbackStreamUrl -Url "$($theme.media.streamUrl)") -or
        "$($theme.media.codec)" -cne 'avc1.42c01f') {
      throw 'Scene themes require an image preview and a valid loopback H.264 stream.'
    }
    $mediaType = 'scene'
  } elseif ($declaredMediaType -cne $mediaType) {
    throw "Theme media type does not match its file extension: $mediaPath"
  }
  $null = Get-DreamSkinThemeMediaOpacity -Theme $theme
  return [pscustomobject]@{
    Directory = $directory
    ThemePath = $themePath
    ImagePath = $imagePath
    MediaPath = $mediaPath
    MediaType = $mediaType
    Theme = $theme
  }
}

function Write-DreamSkinTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDirectory,
    [Parameter(Mandatory = $true)][object]$Theme
  )
  if (-not (Test-DreamSkinThemeSchemaV1 -Theme $Theme)) {
    throw 'Theme schemaVersion must equal 1.'
  }
  Assert-DreamSkinNoReparseComponents -Path $ThemeDirectory
  New-Item -ItemType Directory -Force -Path $ThemeDirectory | Out-Null
  Assert-DreamSkinNoReparseComponents -Path $ThemeDirectory
  $json = $Theme | ConvertTo-Json -Depth 8
  $themePath = Join-Path $ThemeDirectory 'theme.json'
  Assert-DreamSkinNoReparseComponents -Path $themePath
  Write-DreamSkinUtf8FileAtomically -Path $themePath -Content ($json + "`r`n")
}

function Initialize-DreamSkinThemeStore {
  param(
    [Parameter(Mandatory = $true)][string]$SkillRoot,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  foreach ($directory in @($paths.Root, $paths.Active, $paths.Saved, $paths.Images)) {
    Ensure-DreamSkinManagedDirectory -Path $directory -Root $paths.Root
  }
  $assetRoot = Join-Path $SkillRoot 'assets'
  $assetImage = Join-Path $assetRoot 'dream-reference.jpg'
  Assert-DreamSkinImageFile -Path $assetImage
  $activeTheme = Join-Path $paths.Active 'theme.json'
  Assert-DreamSkinNoReparseComponents -Path $activeTheme
  if (-not (Test-Path -LiteralPath $activeTheme -PathType Leaf)) {
    Ensure-DreamSkinManagedDirectory -Path $paths.Active -Root $paths.Root
    Assert-DreamSkinNoReparseComponents -Path (Join-Path $paths.Active 'dream-reference.jpg')
    $activeImage = Join-Path $paths.Active 'dream-reference.jpg'
    Copy-Item -LiteralPath (Join-Path $assetRoot 'dream-reference.jpg') `
      -Destination $activeImage -Force
    Assert-DreamSkinNoReparseComponents -Path $activeImage
    Assert-DreamSkinImageFile -Path $activeImage
    $imageArchive = Join-Path $paths.Images 'dream-reference.jpg'
    Assert-DreamSkinNoReparseComponents -Path $imageArchive
    Copy-Item -LiteralPath (Join-Path $assetRoot 'dream-reference.jpg') `
      -Destination $imageArchive -Force
    Assert-DreamSkinNoReparseComponents -Path $imageArchive
    Assert-DreamSkinImageFile -Path $imageArchive
    Assert-DreamSkinNoReparseComponents -Path $activeTheme
    Copy-Item -LiteralPath (Join-Path $assetRoot 'theme.json') -Destination $activeTheme -Force
  }
  $presetDirectory = Join-Path $paths.Saved 'preset-romantic-rose'
  $presetTheme = Join-Path $presetDirectory 'theme.json'
  Assert-DreamSkinNoReparseComponents -Path $presetDirectory
  Assert-DreamSkinNoReparseComponents -Path $presetTheme
  if (-not (Test-Path -LiteralPath $presetTheme -PathType Leaf)) {
    Ensure-DreamSkinManagedDirectory -Path $presetDirectory -Root $paths.Root
    $presetImage = Join-Path $presetDirectory 'dream-reference.jpg'
    Assert-DreamSkinNoReparseComponents -Path $presetImage
    Copy-Item -LiteralPath (Join-Path $assetRoot 'dream-reference.jpg') `
      -Destination $presetImage -Force
    Assert-DreamSkinNoReparseComponents -Path $presetImage
    Assert-DreamSkinImageFile -Path $presetImage
    Assert-DreamSkinNoReparseComponents -Path $presetTheme
    Copy-Item -LiteralPath (Join-Path $assetRoot 'theme.json') -Destination $presetTheme -Force
  }
  $null = Read-DreamSkinTheme -ThemeDirectory $paths.Active
  return $paths
}

function New-DreamSkinThemeImageName {
  param([Parameter(Mandatory = $true)][string]$Extension)
  return 'art-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' +
    [guid]::NewGuid().ToString('N').Substring(0, 8) + $Extension.ToLowerInvariant()
}

function Get-DreamSkinVideoDimensions {
  param([Parameter(Mandatory = $true)][string]$Path)
  $shell = $null
  try {
    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.Namespace([System.IO.Path]::GetDirectoryName($Path))
    $item = if ($null -ne $folder) { $folder.ParseName([System.IO.Path]::GetFileName($Path)) } else { $null }
    if ($null -eq $item) { return $null }
    $width = [int64]$item.ExtendedProperty('System.Video.FrameWidth')
    $height = [int64]$item.ExtendedProperty('System.Video.FrameHeight')
    $frameRate = [int64]$item.ExtendedProperty('System.Video.FrameRate')
    if ($width -lt 1 -or $height -lt 1) { return $null }
    return [pscustomobject]@{
      Width = $width
      Height = $height
      FramesPerSecond = if ($frameRate -gt 0) { [double]$frameRate / 1000 } else { 30 }
    }
  } catch {
    return $null
  } finally {
    if ($null -ne $shell) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
  }
}

function Invoke-DreamSkinWinRtOperation {
  param([Parameter(Mandatory = $true)][object]$Operation, [Parameter(Mandatory = $true)][type]$ResultType)
  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -ceq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -ceq 'IAsyncOperation`1'
  } | Select-Object -First 1
  if ($null -eq $method) { throw 'Windows Runtime async operation bridge is unavailable.' }
  $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
  $task.GetAwaiter().GetResult()
}

function Invoke-DreamSkinWinRtProgressAction {
  param([Parameter(Mandatory = $true)][object]$Operation)
  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -ceq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -ceq 'IAsyncActionWithProgress`1'
  } | Select-Object -First 1
  if ($null -eq $method) { throw 'Windows Runtime progress bridge is unavailable.' }
  $task = $method.MakeGenericMethod([double]).Invoke($null, @($Operation))
  $task.GetAwaiter().GetResult()
}

function New-DreamSkinPerformanceProxy {
  param(
    [Parameter(Mandatory = $true)][object]$Reference,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $dimensions = Get-DreamSkinVideoDimensions -Path $Reference.MediaPath
  if ($null -eq $dimensions -or ($dimensions.Width -le 1920 -and $dimensions.Height -le 1080)) {
    return $null
  }
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.MediaCache -Root $paths.Root
  $source = [System.IO.FileInfo]::new($Reference.MediaPath)
  $cacheName = '{0}-{1}-{2}-1080p.mp4' -f $Reference.WorkshopId, $source.Length, $source.LastWriteTimeUtc.Ticks
  $proxyPath = Join-Path $paths.MediaCache $cacheName
  if (Test-Path -LiteralPath $proxyPath -PathType Leaf) {
    try {
      if ((Assert-DreamSkinMediaFile -Path $proxyPath) -ceq 'video') {
        return [pscustomobject]@{ Path = $proxyPath; RelativePath = 'media-cache/' + $cacheName }
      }
    } catch {}
    Remove-Item -LiteralPath $proxyPath -Force -ErrorAction SilentlyContinue
  }

  $partialPath = Join-Path $paths.MediaCache ('.' + $cacheName + '.' + [guid]::NewGuid().ToString('N') + '.partial.mp4')
  [System.IO.File]::WriteAllBytes($partialPath, [byte[]]@())
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
    $null = [Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
    $null = [Windows.Media.MediaProperties.VideoEncodingQuality, Windows.Media.MediaProperties, ContentType=WindowsRuntime]
    $null = [Windows.Media.Transcoding.MediaTranscoder, Windows.Media.Transcoding, ContentType=WindowsRuntime]
    $null = [Windows.Media.Transcoding.PrepareTranscodeResult, Windows.Media.Transcoding, ContentType=WindowsRuntime]
    $inputFile = Invoke-DreamSkinWinRtOperation `
      -Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Reference.MediaPath)) `
      -ResultType ([Windows.Storage.StorageFile])
    $outputFile = Invoke-DreamSkinWinRtOperation `
      -Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($partialPath)) `
      -ResultType ([Windows.Storage.StorageFile])
    $profile = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateMp4(
      [Windows.Media.MediaProperties.VideoEncodingQuality]::HD1080p)
    $transcoder = [Windows.Media.Transcoding.MediaTranscoder]::new()
    $prepared = Invoke-DreamSkinWinRtOperation `
      -Operation ($transcoder.PrepareFileTranscodeAsync($inputFile, $outputFile, $profile)) `
      -ResultType ([Windows.Media.Transcoding.PrepareTranscodeResult])
    if (-not $prepared.CanTranscode) { throw "Windows media transcoding failed: $($prepared.FailureReason)" }
    Invoke-DreamSkinWinRtProgressAction -Operation ($prepared.TranscodeAsync())
    if ((Assert-DreamSkinMediaFile -Path $partialPath) -cne 'video') {
      throw 'Generated performance proxy is not a supported video.'
    }
    Move-Item -LiteralPath $partialPath -Destination $proxyPath -Force
    return [pscustomobject]@{ Path = $proxyPath; RelativePath = 'media-cache/' + $cacheName }
  } finally {
    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
  }
}

function Set-DreamSkinActiveWallpaperEngineTheme {
  param(
    [string]$ProjectDirectory,
    [string]$MediaPath,
    [AllowNull()][object]$Theme,
    [string]$Name,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  if ($MediaPath) {
    $reference = Get-DreamSkinWallpaperEngineReferenceFromMediaPath -MediaPath $MediaPath
    $project = $null
    $projectPath = Join-Path $reference.WorkshopDirectory 'project.json'
    if (Test-DreamSkinThemePathWithin -Path $projectPath -Root $reference.WorkshopDirectory) {
      try { $project = (Read-DreamSkinUtf8File -Path $projectPath) | ConvertFrom-Json -ErrorAction Stop } catch {}
    }
    if (-not $Name) { $Name = Get-DreamSkinWallpaperEngineDisplayName -Reference $reference -Project $project }
  } elseif ($ProjectDirectory) {
    $reference = Read-DreamSkinWallpaperEngineProject -ProjectDirectory $ProjectDirectory
  } else {
    throw 'Set-DreamSkinActiveWallpaperEngineTheme requires -MediaPath or -ProjectDirectory.'
  }
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Active -Root $paths.Root
  $oldImage = $null
  try { $oldImage = (Read-DreamSkinTheme -ThemeDirectory $paths.Active).ImagePath } catch {}
  if ($null -eq $Theme) {
    $Theme = [pscustomobject]@{
      schemaVersion = 1
      id = 'wallpaper-engine-' + $reference.WorkshopId
      name = $reference.Name
      appearance = 'auto'
      art = [pscustomobject]@{ focusX = $null; focusY = $null; safeArea = 'auto'; taskMode = 'auto' }
      palette = [pscustomobject]@{}
      media = [pscustomobject]@{ type = 'video'; playbackRate = 1; opacity = 1 }
    }
  }
  if (-not (Test-DreamSkinThemeSchemaV1 -Theme $Theme)) {
    throw 'Theme schemaVersion must equal 1.'
  }
  $performanceProxy = $null
  try {
    $existingProxy = Resolve-DreamSkinPerformanceProxy -ThemeDirectory $paths.Active -Theme $Theme
    if ($existingProxy -and [System.IO.Path]::GetFileName($existingProxy).StartsWith(
      "$($reference.WorkshopId)-", [System.StringComparison]::OrdinalIgnoreCase)) {
      $performanceProxy = [pscustomobject]@{
        Path = $existingProxy
        RelativePath = "$($Theme.media.proxy)"
      }
    }
  } catch {}
  try {
    if ($null -eq $performanceProxy) {
      $performanceProxy = New-DreamSkinPerformanceProxy -Reference $reference -StateRoot $StateRoot
    }
  } catch {
    Write-Warning "Wallpaper performance proxy was unavailable; using the original video: $($_.Exception.Message)"
  }
  $Theme | Add-Member -NotePropertyName image -NotePropertyValue $reference.RelativePath -Force
  $media = [pscustomobject]@{
    type = 'video'
    playbackRate = if ($Theme.media -and $Theme.media.playbackRate) { [double]$Theme.media.playbackRate } else { 1 }
    opacity = Get-DreamSkinThemeMediaOpacity -Theme $Theme
    source = 'wallpaper-engine-local'
    workshopId = $reference.WorkshopId
    workshopRoot = $reference.WorkshopRoot
    relativePath = $reference.RelativePath
  }
  if ($null -ne $performanceProxy) {
    $media | Add-Member -NotePropertyName proxy -NotePropertyValue $performanceProxy.RelativePath
  }
  $Theme | Add-Member -NotePropertyName media -NotePropertyValue $media -Force
  if ($Name) { $Theme | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force }
  if (-not $Theme.id) { $Theme | Add-Member -NotePropertyName id -NotePropertyValue ('wallpaper-engine-' + $reference.WorkshopId) -Force }
  if (-not $Theme.appearance) { $Theme | Add-Member -NotePropertyName appearance -NotePropertyValue 'auto' -Force }
  if (-not $Theme.art) {
    $Theme | Add-Member -NotePropertyName art -NotePropertyValue `
      ([pscustomobject]@{ focusX = $null; focusY = $null; safeArea = 'auto'; taskMode = 'auto' }) -Force
  }
  if (-not $Theme.palette) {
    $Theme | Add-Member -NotePropertyName palette -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  Write-DreamSkinTheme -ThemeDirectory $paths.Active -Theme $Theme
  if ($oldImage -and (Test-DreamSkinThemePathWithin -Path $oldImage -Root $paths.Active)) {
    Remove-Item -LiteralPath $oldImage -Force -ErrorAction SilentlyContinue
  }
  return Read-DreamSkinTheme -ThemeDirectory $paths.Active
}

function Set-DreamSkinActiveSceneStreamTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ScenePath,
    [Parameter(Mandatory = $true)][string]$StreamUrl,
    [string]$Name,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  if (-not (Test-DreamSkinLoopbackStreamUrl -Url $StreamUrl)) {
    throw 'Scene stream URL must be a tokenized loopback HTTP endpoint.'
  }
  $fullScenePath = [System.IO.Path]::GetFullPath($ScenePath)
  if ([System.IO.Path]::GetFileName($fullScenePath) -ine 'scene.pkg') {
    throw 'Scene stream source must be scene.pkg.'
  }
  $reference = Read-DreamSkinWallpaperEngineProject -ProjectDirectory (Split-Path -Parent $fullScenePath)
  if ($reference.MediaType -cne 'scene' -or $reference.MediaPath -ine $fullScenePath) {
    throw 'Scene stream source does not match its Wallpaper Engine project.'
  }
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Active -Root $paths.Root
  $opacity = 1
  try {
    $current = Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata
    if ($current.MediaType -ceq 'scene') {
      $opacity = Get-DreamSkinThemeMediaOpacity -Theme $current.Theme
    }
  } catch {}
  $projectDirectory = $reference.WorkshopDirectory
  $preview = Get-ChildItem -LiteralPath $projectDirectory -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -ceq 'preview' -and $_.Extension.ToLowerInvariant() -in @('.jpg', '.jpeg', '.png', '.webp') } |
    Select-Object -First 1
  if ($null -eq $preview) {
    $previewPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\dream-reference.jpg'
  } else {
    $previewPath = $preview.FullName
  }
  Assert-DreamSkinImageFile -Path $previewPath
  $previewName = 'scene-preview' + [System.IO.Path]::GetExtension($previewPath).ToLowerInvariant()
  $activePreview = Join-Path $paths.Active $previewName
  Copy-Item -LiteralPath $previewPath -Destination $activePreview -Force
  Assert-DreamSkinImageFile -Path $activePreview
  if (-not $Name) { $Name = $reference.Name }
  $theme = [pscustomobject]@{
    schemaVersion = 1
    id = 'wallpaper-engine-scene-' + $reference.WorkshopId
    name = $Name
    image = $previewName
    appearance = 'auto'
    art = [pscustomobject]@{
      focusX = $null
      focusY = $null
      safeArea = 'auto'
      taskMode = 'auto'
    }
    palette = [pscustomobject]@{}
    media = [pscustomobject]@{
      type = 'scene'
      streamUrl = $StreamUrl
      codec = 'avc1.42c01f'
      playbackRate = 1
      opacity = $opacity
      scenePath = $fullScenePath
      workshopId = $reference.WorkshopId
    }
  }
  Write-DreamSkinTheme -ThemeDirectory $paths.Active -Theme $theme
  Get-ChildItem -LiteralPath $paths.Active -File -Force -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -ne 'theme.json' -and $_.FullName -ine $activePreview
    } |
    Remove-Item -Force -ErrorAction SilentlyContinue
  return Read-DreamSkinTheme -ThemeDirectory $paths.Active
}

function Set-DreamSkinActiveTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ImagePath,
    [AllowNull()][object]$Theme,
    [string]$Name,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Active -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Images -Root $paths.Root
  $source = [System.IO.Path]::GetFullPath($ImagePath)
  $mediaType = Assert-DreamSkinMediaFile -Path $source
  $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
  $oldImage = $null
  try { $oldImage = (Read-DreamSkinTheme -ThemeDirectory $paths.Active).ImagePath } catch {}
  if ($null -eq $Theme) {
    $Theme = [pscustomobject]@{
      schemaVersion = 1
      id = 'custom'
      name = '自定义主题'
      appearance = 'auto'
      art = [pscustomobject]@{ focusX = $null; focusY = $null; safeArea = 'auto'; taskMode = 'auto' }
      palette = [pscustomobject]@{}
      media = [pscustomobject]@{ type = $mediaType; playbackRate = 1; opacity = 1 }
    }
  }
  if (-not (Test-DreamSkinThemeSchemaV1 -Theme $Theme)) {
    throw 'Theme schemaVersion must equal 1.'
  }
  $imageName = New-DreamSkinThemeImageName -Extension $extension
  $target = Join-Path $paths.Active $imageName
  $temporary = Join-Path $paths.Active ('.dream-tmp-' + [guid]::NewGuid().ToString('N') + $extension)
  try {
    Assert-DreamSkinNoReparseComponents -Path $target
    Assert-DreamSkinNoReparseComponents -Path $temporary
    Copy-Item -LiteralPath $source -Destination $temporary -Force
    Assert-DreamSkinNoReparseComponents -Path $temporary
    $null = Assert-DreamSkinMediaFile -Path $temporary
    Move-Item -LiteralPath $temporary -Destination $target -Force
    Assert-DreamSkinNoReparseComponents -Path $target
    $null = Assert-DreamSkinMediaFile -Path $target
    $Theme | Add-Member -NotePropertyName image -NotePropertyValue $imageName -Force
    $Theme | Add-Member -NotePropertyName media -NotePropertyValue `
      ([pscustomobject]@{ type = $mediaType; playbackRate = if ($Theme.media.playbackRate) {
        [double]$Theme.media.playbackRate
      } else { 1 }; opacity = Get-DreamSkinThemeMediaOpacity -Theme $Theme }) -Force
    if ($Name) { $Theme | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force }
    if (-not $Theme.id) { $Theme | Add-Member -NotePropertyName id -NotePropertyValue 'custom' -Force }
    if (-not $Theme.appearance) { $Theme | Add-Member -NotePropertyName appearance -NotePropertyValue 'auto' -Force }
    if (-not $Theme.art) {
      $Theme | Add-Member -NotePropertyName art -NotePropertyValue `
        ([pscustomobject]@{ focusX = $null; focusY = $null; safeArea = 'auto'; taskMode = 'auto' }) -Force
    }
    if (-not $Theme.palette) {
      $Theme | Add-Member -NotePropertyName palette -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    Write-DreamSkinTheme -ThemeDirectory $paths.Active -Theme $Theme
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
  $sameImage = $oldImage -and ([System.IO.Path]::GetFullPath($oldImage) -ieq [System.IO.Path]::GetFullPath($target))
  if ($oldImage -and -not $sameImage -and
    (Test-DreamSkinThemePathWithin -Path $oldImage -Root $paths.Active)) {
    Remove-Item -LiteralPath $oldImage -Force -ErrorAction SilentlyContinue
  }
  $imageArchive = Join-Path $paths.Images $imageName
  Assert-DreamSkinNoReparseComponents -Path $imageArchive
  Copy-Item -LiteralPath $target -Destination $imageArchive -Force
  Assert-DreamSkinNoReparseComponents -Path $imageArchive
  $null = Assert-DreamSkinMediaFile -Path $imageArchive
  return Read-DreamSkinTheme -ThemeDirectory $paths.Active
}

function Set-DreamSkinActiveThemeMediaOpacity {
  param(
    [Parameter(Mandatory = $true)][object]$Opacity,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $normalized = ConvertTo-DreamSkinMediaOpacity -Value $Opacity
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  $active = Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata
  $theme = $active.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ($null -eq $theme.media) {
    $theme | Add-Member -NotePropertyName media -NotePropertyValue `
      ([pscustomobject]@{ type = $active.MediaType; playbackRate = 1; opacity = $normalized }) -Force
  } else {
    $theme.media | Add-Member -NotePropertyName opacity -NotePropertyValue $normalized -Force
  }
  Write-DreamSkinTheme -ThemeDirectory $paths.Active -Theme $theme
  return Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata
}

function Save-DreamSkinCurrentTheme {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $trimmed = $Name.Trim()
  if (-not $trimmed -or $trimmed.Length -gt 80 -or $trimmed -match '[\u0000-\u001f]') {
    throw 'Theme name must be between 1 and 80 visible characters.'
  }
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Saved -Root $paths.Root
  $active = Read-DreamSkinTheme -ThemeDirectory $paths.Active
  $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $destination = Join-Path $paths.Saved $id
  Ensure-DreamSkinManagedDirectory -Path $destination -Root $paths.Root
  $theme = $active.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  $theme.id = $id
  $theme.name = $trimmed
  if ($null -ne (Get-DreamSkinWallpaperEngineReference -Theme $theme)) {
    Write-DreamSkinTheme -ThemeDirectory $destination -Theme $theme
    return Read-DreamSkinTheme -ThemeDirectory $destination
  }
  $extension = [System.IO.Path]::GetExtension($active.ImagePath).ToLowerInvariant()
  $imageName = 'art' + $extension
  $destinationImage = Join-Path $destination $imageName
  Assert-DreamSkinNoReparseComponents -Path $destinationImage
  Copy-Item -LiteralPath $active.ImagePath -Destination $destinationImage -Force
  Assert-DreamSkinNoReparseComponents -Path $destinationImage
  $null = Assert-DreamSkinMediaFile -Path $destinationImage
  $theme.image = $imageName
  Write-DreamSkinTheme -ThemeDirectory $destination -Theme $theme
  return Read-DreamSkinTheme -ThemeDirectory $destination
}

function Get-DreamSkinSavedThemes {
  param(
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'),
    [switch]$SkipImageMetadata
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Saved -Root $paths.Root
  if (-not (Test-Path -LiteralPath $paths.Saved -PathType Container)) { return @() }
  $themes = @()
  foreach ($directory in Get-ChildItem -LiteralPath $paths.Saved -Directory -ErrorAction SilentlyContinue) {
    try {
      $loaded = Read-DreamSkinTheme -ThemeDirectory $directory.FullName -SkipImageMetadata:$SkipImageMetadata
      $themes += [pscustomobject]@{
        Id = "$($loaded.Theme.id)"
        Name = if ($loaded.Theme.name) { "$($loaded.Theme.name)" } else { $directory.Name }
        Path = $directory.FullName
        MediaType = $loaded.MediaType
      }
    } catch {}
  }
  return @($themes | Sort-Object Name)
}

function Use-DreamSkinSavedTheme {
  param(
    [Parameter(Mandatory = $true)][string]$ThemeDirectory,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  Ensure-DreamSkinManagedDirectory -Path $paths.Saved -Root $paths.Root
  $directory = [System.IO.Path]::GetFullPath($ThemeDirectory)
  if (-not (Test-DreamSkinThemePathWithin -Path $directory -Root $paths.Saved)) {
    throw 'Saved theme must remain inside the Dream Skin themes folder.'
  }
  $saved = Read-DreamSkinTheme -ThemeDirectory $directory
  $theme = $saved.Theme | ConvertTo-Json -Depth 8 | ConvertFrom-Json
  if ($null -ne (Get-DreamSkinWallpaperEngineReference -Theme $theme)) {
    return Set-DreamSkinActiveWallpaperEngineTheme -ProjectDirectory `
      (Split-Path -Parent $saved.ImagePath) -Theme $theme -StateRoot $StateRoot
  }
  return Set-DreamSkinActiveTheme -ImagePath $saved.ImagePath -Theme $theme -StateRoot $StateRoot
}

function Set-DreamSkinPaused {
  param(
    [Parameter(Mandatory = $true)][bool]$Paused,
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
  )
  $paths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  Ensure-DreamSkinManagedDirectory -Path $paths.Root -Root $paths.Root
  if ($Paused) {
    Assert-DreamSkinNoReparseComponents -Path $paths.PauseFile
    Write-DreamSkinUtf8FileAtomically -Path $paths.PauseFile -Content "paused`r`n"
  } else {
    if (Test-Path -LiteralPath $paths.PauseFile) { Assert-DreamSkinNoReparseComponents -Path $paths.PauseFile }
    Remove-Item -LiteralPath $paths.PauseFile -Force -ErrorAction SilentlyContinue
  }
  return $Paused
}

function Test-DreamSkinPaused {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  return (Test-Path -LiteralPath (Get-DreamSkinThemePaths -StateRoot $StateRoot).PauseFile -PathType Leaf)
}
