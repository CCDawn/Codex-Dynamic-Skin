[CmdletBinding()]
param(
  [string]$OutputDirectory,
  [string]$DesktopOutput,
  [switch]$SkipWindowsTests
)

$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path -Parent $PSScriptRoot
$OutputDirectory = if ($OutputDirectory) {
  [System.IO.Path]::GetFullPath($OutputDirectory)
} else {
  Join-Path $windowsRoot 'dist'
}
$project = Join-Path $PSScriptRoot 'CodexDreamSkin.Manager\CodexDreamSkin.Manager.csproj'

function Get-ManagerDotNet {
  $installed = Get-Command dotnet.exe -ErrorAction SilentlyContinue
  $candidates = @()
  if ($null -ne $installed) {
    $candidates += $installed.Source
  }

  foreach ($programFiles in @(
      [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::ProgramFiles),
      [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
    $candidates += Join-Path $programFiles 'dotnet\dotnet.exe'
  }

  foreach ($candidate in $candidates | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $sdks = & $candidate --list-sdks
    if (@($sdks | Where-Object { $_ -match '^8\.' }).Count -gt 0) {
      return $candidate
    }
  }

  $cacheRoot = Join-Path (
    [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
  ) '.cache\codex-runtimes'
  $candidate = Get-ChildItem -LiteralPath $cacheRoot -Directory -Filter 'dotnet-sdk-8.*' `
    -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'dotnet.exe' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
  if ($candidate) { return $candidate }
  throw 'A .NET 8 SDK is required to build Codex Dream Skin Manager.'
}

function Get-ManagerNode {
  $node = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($null -eq $node) { throw 'Node.js 22 or newer is required for the bundled runtime.' }
  $versionText = (& $node.Source --version).TrimStart('v')
  $version = [version]$versionText
  if ($version.Major -lt 22) { throw "Node.js 22 or newer is required; found $versionText." }
  return [pscustomobject]@{ Path = $node.Source; Version = $versionText }
}

$dotnet = Get-ManagerDotNet
$node = Get-ManagerNode
$cache = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\build-cache'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
$nodeLicense = Join-Path $cache "node-v$($node.Version)-LICENSE.txt"
if (-not (Test-Path -LiteralPath $nodeLicense -PathType Leaf)) {
  $licenseUrl = "https://raw.githubusercontent.com/nodejs/node/v$($node.Version)/LICENSE"
  Invoke-WebRequest -Uri $licenseUrl -OutFile $nodeLicense -UseBasicParsing -TimeoutSec 30
}
if ((Get-Item -LiteralPath $nodeLicense).Length -lt 1000) {
  throw 'The downloaded Node.js license file is incomplete.'
}

if (-not $SkipWindowsTests) {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $windowsRoot 'tests\run-tests.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'Windows regression tests failed.' }
}

$staging = Join-Path $env:TEMP ('codex-dream-skin-manager-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
  & $dotnet restore $project `
    "-p:NodeExe=$($node.Path)" `
    "-p:NodeLicense=$nodeLicense"
  if ($LASTEXITCODE -ne 0) { throw '.NET restore failed.' }

  & $dotnet publish $project `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --no-restore `
    --output $staging `
    "-p:NodeExe=$($node.Path)" `
    "-p:NodeLicense=$nodeLicense" `
    '-p:PublishSingleFile=true' `
    '-p:IncludeNativeLibrariesForSelfExtract=true' `
    '-p:EnableCompressionInSingleFile=true'
  if ($LASTEXITCODE -ne 0) { throw '.NET publish failed.' }

  $publishedExe = Join-Path $staging 'CodexDreamSkinManager.exe'
  if (-not (Test-Path -LiteralPath $publishedExe -PathType Leaf)) {
    throw 'Single-file publish did not produce CodexDreamSkinManager.exe.'
  }
  $selfTest = Start-Process -FilePath $publishedExe -ArgumentList '--self-test' -Wait -PassThru
  if ($selfTest.ExitCode -ne 0) {
    throw "Published manager self-test failed with exit code $($selfTest.ExitCode)."
  }

  New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
  $outputExe = Join-Path ([System.IO.Path]::GetFullPath($OutputDirectory)) 'CodexDreamSkinManager.exe'
  Copy-Item -LiteralPath $publishedExe -Destination $outputExe -Force
  $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $outputExe
  [System.IO.File]::WriteAllText(
    "$outputExe.sha256",
    "$($hash.Hash.ToLowerInvariant())  CodexDreamSkinManager.exe`r`n",
    [System.Text.UTF8Encoding]::new($false))

  if ($DesktopOutput) {
    $desktopPath = [System.IO.Path]::GetFullPath($DesktopOutput)
    $desktopDirectory = Split-Path -Parent $desktopPath
    New-Item -ItemType Directory -Path $desktopDirectory -Force | Out-Null
    Copy-Item -LiteralPath $outputExe -Destination $desktopPath -Force
  }

  [pscustomobject]@{
    output = $outputExe
    desktopOutput = if ($DesktopOutput) { [System.IO.Path]::GetFullPath($DesktopOutput) } else { $null }
    bytes = (Get-Item -LiteralPath $outputExe).Length
    sha256 = $hash.Hash.ToLowerInvariant()
    nodeVersion = $node.Version
    dotnet = $dotnet
  } | ConvertTo-Json -Depth 4
} finally {
  if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
}
