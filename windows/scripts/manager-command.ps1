[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('SetWallpaper', 'SetReveal', 'Pause', 'Resume', 'Status', 'ListThemes', 'SaveTheme', 'UseTheme', 'ListWallpaperEngine', 'UseWallpaperEngine', 'UseSceneStream')]
  [string]$Action,
  [string]$Path,
  [string]$Name,
  [string]$ThemeId,
  [string]$SteamLibraryPath,
  [string]$StreamUrl,
  [ValidateRange(0, 100)]
  [int]$Percent = 100,
  [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin')
)

$ErrorActionPreference = 'Stop'
$utf8Output = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8Output
$OutputEncoding = $utf8Output
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

$paths = Get-DreamSkinThemePaths -StateRoot $StateRoot

function ConvertTo-DreamSkinManagerThemeResult {
  param(
    [Parameter(Mandatory = $true)][string]$Action,
    [Parameter(Mandatory = $true)][object]$LoadedTheme
  )
  [pscustomobject]@{
    action = $Action
    themeId = "$($LoadedTheme.Theme.id)"
    name = "$($LoadedTheme.Theme.name)"
    mediaPath = $LoadedTheme.MediaPath
    mediaType = $LoadedTheme.MediaType
    source = if ($LoadedTheme.Theme.media -and $LoadedTheme.Theme.media.source) {
      "$($LoadedTheme.Theme.media.source)"
    } else { 'managed' }
    reveal = Get-DreamSkinThemeMediaOpacity -Theme $LoadedTheme.Theme
  }
}

function Initialize-DreamSkinManagerThemeStore {
  Initialize-DreamSkinThemeStore -SkillRoot (Split-Path -Parent $PSScriptRoot) `
    -StateRoot $StateRoot | Out-Null
}

switch ($Action) {
  'SetWallpaper' {
    if (-not $Path) { throw 'SetWallpaper requires -Path.' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $theme = $null
    if (Test-Path -LiteralPath $paths.Active -PathType Container) {
      try {
        $theme = (Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata).Theme
      } catch {
        $theme = $null
      }
    }
    $result = Set-DreamSkinActiveTheme -ImagePath $fullPath -Theme $theme `
      -Name ([System.IO.Path]::GetFileNameWithoutExtension($fullPath)) -StateRoot $StateRoot
    [pscustomobject]@{
      action = $Action
      mediaPath = $result.MediaPath
      mediaType = $result.MediaType
      name = $result.Theme.name
      reveal = Get-DreamSkinThemeMediaOpacity -Theme $result.Theme
    } | ConvertTo-Json -Depth 5
  }
  'SetReveal' {
    $result = Set-DreamSkinActiveThemeMediaOpacity -Opacity ([double]$Percent / 100) `
      -StateRoot $StateRoot
    [pscustomobject]@{
      action = $Action
      percent = $Percent
      reveal = Get-DreamSkinThemeMediaOpacity -Theme $result.Theme
    } | ConvertTo-Json -Depth 5
  }
  'ListThemes' {
    Initialize-DreamSkinManagerThemeStore
    $themes = @(
      Get-DreamSkinSavedThemes -StateRoot $StateRoot -SkipImageMetadata |
        ForEach-Object {
          [pscustomobject]@{
            id = $_.Id
            name = $_.Name
            mediaType = $_.MediaType
          }
        }
    )
    [pscustomobject]@{
      action = $Action
      themes = $themes
    } | ConvertTo-Json -Depth 5
  }
  'SaveTheme' {
    if (-not $Name) { throw 'SaveTheme requires -Name.' }
    Initialize-DreamSkinManagerThemeStore
    ConvertTo-DreamSkinManagerThemeResult -Action $Action `
      -LoadedTheme (Save-DreamSkinCurrentTheme -Name $Name -StateRoot $StateRoot) |
      ConvertTo-Json -Depth 5
  }
  'UseTheme' {
    if (-not $ThemeId) { throw 'UseTheme requires -ThemeId.' }
    Initialize-DreamSkinManagerThemeStore
    $matches = @(
      Get-DreamSkinSavedThemes -StateRoot $StateRoot -SkipImageMetadata |
        Where-Object { $_.Id -ceq $ThemeId }
    )
    if ($matches.Count -ne 1) { throw "Saved theme was not found: $ThemeId" }
    ConvertTo-DreamSkinManagerThemeResult -Action $Action `
      -LoadedTheme (Use-DreamSkinSavedTheme -ThemeDirectory $matches[0].Path -StateRoot $StateRoot) |
      ConvertTo-Json -Depth 5
  }
  'ListWallpaperEngine' {
    $items = @(
      Get-DreamSkinWallpaperEngineProjects -SteamLibraryPath $SteamLibraryPath |
        ForEach-Object {
          [pscustomobject]@{
            workshopId = $_.WorkshopId
            name = $_.Name
            workshopRoot = $_.WorkshopRoot
            projectDirectory = $_.ProjectDirectory
            relativePath = $_.RelativePath
            mediaPath = $_.MediaPath
            mediaType = $_.MediaType
            length = $_.Length
          }
        }
    )
    [pscustomobject]@{
      action = $Action
      items = $items
    } | ConvertTo-Json -Depth 5
  }
  'UseWallpaperEngine' {
    if (-not $Path) { throw 'UseWallpaperEngine requires -Path.' }
    Initialize-DreamSkinManagerThemeStore
    $applyArguments = if (Test-Path -LiteralPath $Path -PathType Leaf) {
      @{ MediaPath = $Path }
    } else {
      @{ ProjectDirectory = $Path }
    }
    ConvertTo-DreamSkinManagerThemeResult -Action $Action `
      -LoadedTheme (Set-DreamSkinActiveWallpaperEngineTheme @applyArguments -Theme $null `
        -Name $Name -StateRoot $StateRoot) |
      ConvertTo-Json -Depth 5
  }
  'UseSceneStream' {
    if (-not $Path -or -not $StreamUrl) {
      throw 'UseSceneStream requires -Path and -StreamUrl.'
    }
    Initialize-DreamSkinManagerThemeStore
    ConvertTo-DreamSkinManagerThemeResult -Action $Action `
      -LoadedTheme (Set-DreamSkinActiveSceneStreamTheme -ScenePath $Path `
        -StreamUrl $StreamUrl -Name $Name -StateRoot $StateRoot) |
      ConvertTo-Json -Depth 5
  }
  'Pause' {
    Set-DreamSkinPaused -Paused $true -StateRoot $StateRoot | Out-Null
    [pscustomobject]@{ action = $Action; paused = $true } | ConvertTo-Json
  }
  'Resume' {
    Set-DreamSkinPaused -Paused $false -StateRoot $StateRoot | Out-Null
    [pscustomobject]@{ action = $Action; paused = $false } | ConvertTo-Json
  }
  'Status' {
    $active = $null
    if (Test-Path -LiteralPath $paths.Active -PathType Container) {
      try {
        $active = Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata
      } catch {
        $active = $null
      }
    }
    [pscustomobject]@{
      action = $Action
      paused = Test-DreamSkinPaused -StateRoot $StateRoot
      activeTheme = if ($null -ne $active) { $active.Theme.name } else { $null }
      mediaPath = if ($null -ne $active) { $active.MediaPath } else { $null }
      mediaType = if ($null -ne $active) { $active.MediaType } else { $null }
      reveal = if ($null -ne $active) {
        Get-DreamSkinThemeMediaOpacity -Theme $active.Theme
      } else { [double]1 }
    } | ConvertTo-Json -Depth 5
  }
}
