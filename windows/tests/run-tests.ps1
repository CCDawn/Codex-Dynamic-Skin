[CmdletBinding()]
param([switch]$EngineOnly)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'scripts\common-windows.ps1')
. (Join-Path $Root 'scripts\theme-windows.ps1')

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-dream-skin-tests-$PID-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
  $runtimeSourceName = 'runtime source ' + (-join @([char]0x6D4B, [char]0x8BD5))
  $runtimeSourceRoot = Join-Path $temporaryRoot $runtimeSourceName
  $runtimeStateRoot = Join-Path $temporaryRoot 'runtime-state'
  New-Item -ItemType Directory -Path $runtimeSourceRoot | Out-Null
  foreach ($directoryName in @('assets', 'scripts')) {
    Copy-Item -LiteralPath (Join-Path $Root $directoryName) -Destination $runtimeSourceRoot `
      -Recurse -Force -ErrorAction Stop
  }

  $engine = Install-DreamSkinRuntimeEngine -SkillRoot $runtimeSourceRoot -StateRoot $runtimeStateRoot
  $sourcePrefix = $runtimeSourceRoot.TrimEnd('\') + '\'
  $runtimeSourceFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $runtimeSourceRoot 'assets'), (Join-Path $runtimeSourceRoot 'scripts') `
      -Recurse -File -Force
  )
  $runtimeEngineFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $engine.Root 'assets'), (Join-Path $engine.Root 'scripts') `
      -Recurse -File -Force
  )
  if ($runtimeSourceFiles.Count -ne $runtimeEngineFiles.Count -or
    -not (Test-DreamSkinPathWithin -Path $engine.Start -Root $runtimeStateRoot) -or
    -not (Test-DreamSkinPathWithin -Path $engine.Restore -Root $runtimeStateRoot) -or
    -not (Test-DreamSkinPathWithin -Path $engine.Tray -Root $runtimeStateRoot)) {
    throw 'Installed runtime paths are incomplete or still point outside the managed state root.'
  }
  foreach ($sourceFile in $runtimeSourceFiles) {
    $relative = $sourceFile.FullName.Substring($sourcePrefix.Length)
    $installedFile = Join-Path $engine.Root $relative
    if (-not (Test-Path -LiteralPath $installedFile -PathType Leaf) -or
      (Get-FileHash -Algorithm SHA256 -LiteralPath $sourceFile.FullName).Hash -cne
      (Get-FileHash -Algorithm SHA256 -LiteralPath $installedFile).Hash) {
      throw "Installed runtime hash does not match its source: $relative"
    }
  }

  [System.IO.File]::WriteAllText((Join-Path $engine.Root 'stale-runtime.txt'), 'stale')
  [System.IO.File]::WriteAllText((Join-Path $runtimeSourceRoot 'scripts\runtime-update.test'), 'updated')
  $realRuntimeCleanup = (Get-Command Remove-DreamSkinRuntimeTree -CommandType Function).ScriptBlock
  $previousWarningPreference = $WarningPreference
  $runtimeCleanupFailure = @{ Triggered = $false }
  try {
    $WarningPreference = 'Stop'
    function Remove-DreamSkinRuntimeTree {
      param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StateRoot
      )
      if ([System.IO.Path]::GetFileName($Path) -like '.engine-backup-*') {
        $runtimeCleanupFailure.Triggered = $true
        throw 'forced runtime backup cleanup failure'
      }
      & $realRuntimeCleanup -Path $Path -StateRoot $StateRoot
    }

    $runtimeUpdateReportedFailure = $false
    try {
      $engine = Install-DreamSkinRuntimeEngine -SkillRoot $runtimeSourceRoot -StateRoot $runtimeStateRoot
    } catch {
      $runtimeUpdateReportedFailure = $true
    }
    if (-not $runtimeCleanupFailure.Triggered -or $runtimeUpdateReportedFailure -or
      (Test-Path -LiteralPath (Join-Path $engine.Root 'stale-runtime.txt')) -or
      (Read-DreamSkinUtf8File -Path (Join-Path $engine.Root 'scripts\runtime-update.test')) -cne 'updated') {
      throw 'Runtime reinstall did not commit cleanly when old-engine cleanup failed.'
    }
  } finally {
    $WarningPreference = $previousWarningPreference
    Set-Item -Path Function:\Remove-DreamSkinRuntimeTree -Value $realRuntimeCleanup
  }
  foreach ($runtimeBackup in Get-ChildItem -LiteralPath $runtimeStateRoot -Directory -Force |
    Where-Object { $_.Name -like '.engine-backup-*' }) {
    Remove-DreamSkinRuntimeTree -Path $runtimeBackup.FullName -StateRoot $runtimeStateRoot
  }

  $invalidRuntimeRoot = Join-Path $temporaryRoot 'invalid-runtime-source'
  New-Item -ItemType Directory -Path $invalidRuntimeRoot | Out-Null
  foreach ($directoryName in @('assets', 'scripts')) {
    Copy-Item -LiteralPath (Join-Path $runtimeSourceRoot $directoryName) -Destination $invalidRuntimeRoot `
      -Recurse -Force -ErrorAction Stop
  }
  Remove-Item -LiteralPath (Join-Path $invalidRuntimeRoot 'scripts\start-dream-skin.ps1') -Force
  $invalidRuntimeRejected = $false
  try {
    $null = Install-DreamSkinRuntimeEngine -SkillRoot $invalidRuntimeRoot -StateRoot $runtimeStateRoot
  } catch {
    $invalidRuntimeRejected = $true
  }
  if (-not $invalidRuntimeRejected -or
    -not (Test-Path -LiteralPath $engine.Start -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $engine.Root 'scripts\runtime-update.test') -PathType Leaf) -or
    @(Get-ChildItem -LiteralPath $runtimeStateRoot -Force | Where-Object {
      $_.Name -like '.engine-staging-*' -or $_.Name -like '.engine-backup-*'
    }).Count -ne 0) {
    throw 'An invalid runtime source changed the installed engine or left transaction artifacts.'
  }

  $nestedStateRoot = Join-Path $runtimeSourceRoot 'scripts\nested-state'
  $nestedStateRejected = $false
  try {
    $null = Install-DreamSkinRuntimeEngine -SkillRoot $runtimeSourceRoot -StateRoot $nestedStateRoot
  } catch {
    $nestedStateRejected = $true
  }
  if (-not $nestedStateRejected -or (Test-Path -LiteralPath $nestedStateRoot)) {
    throw 'Runtime install allowed its state root to recurse into the copied source tree.'
  }

  $installSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\install-dream-skin.ps1')
  $trayGuardIndex = $installSource.IndexOf('if (Test-DreamSkinTrayActive)', [System.StringComparison]::Ordinal)
  $engineInstallIndex = $installSource.IndexOf('$engine = Install-DreamSkinRuntimeEngine', [System.StringComparison]::Ordinal)
  if ($trayGuardIndex -lt 0 -or $engineInstallIndex -le $trayGuardIndex) {
    throw 'Installer does not reject an active source-bound tray before replacing the runtime engine.'
  }
  foreach ($requiredShortcutBinding in @(
    '$startScript = $engine.Start',
    '$restoreScript = $engine.Restore',
    '$trayScript = $engine.Tray',
    '$shortcut.WorkingDirectory = $engine.Root',
    '$restore.WorkingDirectory = $engine.Root',
    '$tray.WorkingDirectory = $engine.Root',
    'Codex 动态壁纸.lnk',
    'Codex 动态壁纸 - 托盘控制.lnk',
    'Codex 动态壁纸 - 恢复官方外观.lnk'
  )) {
    if (-not $installSource.Contains($requiredShortcutBinding)) {
      throw "Installer shortcut still depends on its source checkout: $requiredShortcutBinding"
    }
  }

  Remove-Item -LiteralPath $runtimeSourceRoot -Recurse -Force
  foreach ($installedScript in Get-ChildItem -LiteralPath $engine.Scripts -Filter '*.ps1' -File) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $installedScript.FullName, [ref]$tokens, [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count -gt 0) {
      throw "Installed runtime script failed to parse after its source checkout was removed: $($installedScript.Name)"
    }
  }
  if (-not (Test-Path -LiteralPath $engine.Start -PathType Leaf) -or
    -not (Test-Path -LiteralPath $engine.Restore -PathType Leaf) -or
    -not (Test-Path -LiteralPath $engine.Tray -PathType Leaf)) {
    throw 'Installed launch, restore, or tray entry point disappeared with the source checkout.'
  }
  Remove-Item -LiteralPath $invalidRuntimeRoot, $runtimeStateRoot -Recurse -Force

  if ($EngineOnly) {
    Write-Host 'PASS: managed runtime staging, replacement, invalid-source guard, and source-independent shortcuts.'
    return
  }

  $atomicReplacePath = Join-Path $temporaryRoot 'atomic-replace.txt'
  [System.IO.File]::WriteAllText($atomicReplacePath, 'before')
  Write-DreamSkinUtf8FileAtomically -Path $atomicReplacePath -Content 'after'
  if ((Read-DreamSkinUtf8File -Path $atomicReplacePath) -cne 'after') {
    throw 'Atomic writer did not replace an existing file under Windows PowerShell.'
  }
  $atomicArtifacts = @(Get-ChildItem -LiteralPath $temporaryRoot -Force |
    Where-Object { $_.FullName -ne $atomicReplacePath })
  if ($atomicArtifacts.Count -ne 0) {
    throw 'Atomic writer left internal replacement artifacts behind.'
  }
  Remove-Item -LiteralPath $atomicReplacePath -Force

  $realAtomicCleanup = (Get-Command Remove-DreamSkinAtomicArtifact -CommandType Function).ScriptBlock
  $previousWarningPreference = $WarningPreference
  $cleanupFailure = @{ Triggered = $false }
  try {
    $WarningPreference = 'Stop'
    function Remove-DreamSkinAtomicArtifact {
      param([Parameter(Mandatory = $true)][string]$Path)
      if ($Path -like '*.replace-backup') {
        $cleanupFailure.Triggered = $true
        throw 'forced atomic replacement-backup cleanup failure'
      }
      if ([System.IO.File]::Exists($Path)) {
        [System.IO.File]::Delete($Path)
      }
    }

    $cleanupFailurePath = Join-Path $temporaryRoot 'atomic-cleanup-failure.txt'
    [System.IO.File]::WriteAllText($cleanupFailurePath, 'before')
    $cleanupFailureReported = $false
    try {
      Write-DreamSkinUtf8FileAtomically -Path $cleanupFailurePath -Content 'after'
    } catch {
      $cleanupFailureReported = $true
    }
    if (-not $cleanupFailure.Triggered -or $cleanupFailureReported -or
      (Read-DreamSkinUtf8File -Path $cleanupFailurePath) -cne 'after') {
      throw 'A committed atomic write was reported as failed when cleanup failed.'
    }

    $cleanupConfigPath = Join-Path $temporaryRoot 'cleanup-failure-config.toml'
    $cleanupBackupPath = Join-Path $temporaryRoot 'cleanup-failure-config.before.toml'
    $cleanupOriginal = "model = `"gpt-5`"`r`n`r`n[desktop]`r`nappearanceTheme = `"system`"`r`n"
    [System.IO.File]::WriteAllText(
      $cleanupConfigPath,
      $cleanupOriginal,
      [System.Text.UTF8Encoding]::new($false, $true)
    )
    $cleanupOriginalBytes = [System.IO.File]::ReadAllBytes($cleanupConfigPath)
    Install-DreamSkinBaseTheme -ConfigPath $cleanupConfigPath -BackupPath $cleanupBackupPath
    if (-not (Test-Path -LiteralPath $cleanupBackupPath) -or
      -not (Test-DreamSkinBytesEqual -Left $cleanupOriginalBytes `
        -Right ([System.IO.File]::ReadAllBytes($cleanupBackupPath)))) {
      throw 'Atomic cleanup failure removed or changed the durable pre-install config backup.'
    }
  } finally {
    $WarningPreference = $previousWarningPreference
    Set-Item -Path Function:\Remove-DreamSkinAtomicArtifact -Value $realAtomicCleanup
  }

  $configPath = Join-Path $temporaryRoot 'config.toml'
  $backupPath = Join-Path $temporaryRoot 'config.before-dream-skin.toml'
  $projectName = -join @([char]0x4EE3, [char]0x7801, [char]0x9879, [char]0x76EE, [char]0x7532)
  $laterValue = -join @([char]0x4FDD, [char]0x7559)
  $sample = "model = `"gpt-5`"`r`n`r`n[other]`r`nappearanceTheme = `"keep-other`"`r`n`r`n[projects.'C:\$projectName']`r`ntrust_level = `"trusted`"`r`n`r`n[desktop]`r`nappearanceTheme = `"system`"`r`nappearanceLightCodeThemeId = `"theme-`$special`"`r`n"
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
  [System.IO.File]::WriteAllText($configPath, $sample, $utf8NoBom)
  $originalBytes = [System.IO.File]::ReadAllBytes($configPath)

  Install-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  $installed = Read-DreamSkinUtf8File -Path $configPath
  if (-not $installed.Contains($projectName) -or $installed -notmatch 'appearanceTheme = "system"' -or
    $installed -notmatch 'appearanceLightCodeThemeId = "codex"') {
    throw 'Install changed a non-ASCII project name or failed to preserve the native appearance.'
  }
  if (-not (Test-Path -LiteralPath (Get-DreamSkinAppearanceMarkerPath -BackupPath $backupPath))) {
    throw 'Install did not record the appearance-preservation marker.'
  }
  $backupBytes = [System.IO.File]::ReadAllBytes($backupPath)
  if ([Convert]::ToBase64String($backupBytes) -cne [Convert]::ToBase64String($originalBytes)) {
    throw 'Install did not preserve an exact pre-change config backup.'
  }

  $written = [System.IO.File]::ReadAllBytes($configPath)
  if ($written.Length -ge 3 -and $written[0] -eq 0xEF -and $written[1] -eq 0xBB -and $written[2] -eq 0xBF) {
    throw 'Config writer added an unexpected UTF-8 BOM.'
  }

  $installed += "afterInstall = `"$laterValue`"`r`n"
  $installed = $installed -replace 'appearanceTheme = "system"', 'appearanceTheme = "dark"'
  Write-DreamSkinUtf8FileAtomically -Path $configPath -Content $installed
  Restore-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  $restored = Read-DreamSkinUtf8File -Path $configPath
  if (-not $restored.Contains($projectName) -or -not $restored.Contains($laterValue)) {
    throw 'Restore changed a project name or unrelated post-install setting.'
  }
  if ($restored -notmatch 'appearanceTheme = "dark"' -or -not $restored.Contains('appearanceLightCodeThemeId = "theme-$special"')) {
    throw 'Restore overwrote the user appearance or failed to restore the light code theme.'
  }
  if ($restored -notmatch '(?ms)^\[other\].*?appearanceTheme = "keep-other"') {
    throw 'Restore changed an appearance key outside the desktop section.'
  }

  $legacyConfigPath = Join-Path $temporaryRoot 'legacy-light.toml'
  $legacyBackupPath = Join-Path $temporaryRoot 'legacy-light.before.toml'
  $legacyCurrent = "[desktop]`r`n$($script:DreamSkinLegacyAppearanceTheme)`r`n$($script:DreamSkinManagedLightCodeTheme)`r`n$($script:DreamSkinManagedLightChromeTheme)`r`n"
  $legacyOriginal = "[desktop]`r`nappearanceTheme = `"system`"`r`nappearanceLightCodeThemeId = `"theme-original`"`r`nappearanceLightChromeTheme = { surface = `"original`" }`r`n"
  [System.IO.File]::WriteAllText($legacyConfigPath, $legacyCurrent, $utf8NoBom)
  [System.IO.File]::WriteAllText($legacyBackupPath, $legacyOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $legacyConfigPath -BackupPath $legacyBackupPath
  $legacyMigrated = Read-DreamSkinUtf8File -Path $legacyConfigPath
  if ($legacyMigrated -notmatch 'appearanceTheme = "system"' -or
    $legacyMigrated -notmatch 'appearanceLightCodeThemeId = "codex"') {
    throw 'Exact legacy managed light trio was not migrated to the saved native appearance.'
  }
  $legacyMigrated = $legacyMigrated -replace 'appearanceTheme = "system"', 'appearanceTheme = "dark"'
  Write-DreamSkinUtf8FileAtomically -Path $legacyConfigPath -Content $legacyMigrated
  Restore-DreamSkinBaseTheme -ConfigPath $legacyConfigPath -BackupPath $legacyBackupPath
  if ((Read-DreamSkinUtf8File -Path $legacyConfigPath) -notmatch 'appearanceTheme = "dark"') {
    throw 'A current install restore overwrote the user appearance after legacy migration.'
  }

  $lfConfigPath = Join-Path $temporaryRoot 'config-lf.toml'
  $lfBackupPath = Join-Path $temporaryRoot 'config-lf.before.toml'
  $lfOriginal = "model = `"gpt-5`"`n[projects.'C:\$projectName']`ntrust_level = `"trusted`"`n"
  [System.IO.File]::WriteAllText($lfConfigPath, $lfOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $lfConfigPath -BackupPath $lfBackupPath
  $lfInstalled = Read-DreamSkinUtf8File -Path $lfConfigPath
  if ($lfInstalled.Contains("`r") -or $lfInstalled -notmatch '(?m)^\[desktop\]$') {
    throw 'Install did not preserve LF line endings or create the desktop section.'
  }
  Restore-DreamSkinBaseTheme -ConfigPath $lfConfigPath -BackupPath $lfBackupPath
  $lfRestored = Read-DreamSkinUtf8File -Path $lfConfigPath
  if ($lfRestored.Contains("`r") -or $lfRestored -match '(?m)^\[desktop\]$' -or -not $lfRestored.Contains($projectName)) {
    throw 'Restore did not preserve LF content or remove the generated empty desktop section.'
  }

  $quotedConfigPath = Join-Path $temporaryRoot 'config-quoted.toml'
  $quotedBackupPath = Join-Path $temporaryRoot 'config-quoted.before.toml'
  $quotedOriginal = "[`"desktop`"] # retained comment`r`n`"appearanceTheme`" = `"system`"`r`n'appearanceLightCodeThemeId' = `"theme-`$special`"`r`n"
  [System.IO.File]::WriteAllText($quotedConfigPath, $quotedOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $quotedConfigPath -BackupPath $quotedBackupPath
  $quotedInstalled = Read-DreamSkinUtf8File -Path $quotedConfigPath
  if ([regex]::Matches($quotedInstalled, '(?m)^\s*\[(?:"desktop"|desktop)\]').Count -ne 1) {
    throw 'A commented or quoted desktop table was duplicated during install.'
  }
  Restore-DreamSkinBaseTheme -ConfigPath $quotedConfigPath -BackupPath $quotedBackupPath
  if ((Read-DreamSkinUtf8File -Path $quotedConfigPath) -cne $quotedOriginal) {
    throw 'Quoted desktop keys or a table-header comment were not restored exactly.'
  }

  $nestedConfigPath = Join-Path $temporaryRoot 'config-nested-themes.toml'
  $nestedBackupPath = Join-Path $temporaryRoot 'config-nested-themes.before.toml'
  $nestedTables = "[desktop.appearanceDarkChromeTheme]`r`naccent = `"#112233`"`r`n`r`n[desktop.appearanceDarkChromeTheme.fonts]`r`ncode = `"Cascadia Code`"`r`n`r`n[desktop.appearanceDarkChromeTheme.semanticColors]`r`ndiffAdded = `"#234567`"`r`n`r`n[desktop.appearanceLightChromeTheme]`r`naccent = `"#abcdef`"`r`n`r`n[desktop.appearanceLightChromeTheme.fonts]`r`nui = `"Microsoft YaHei UI`"`r`n`r`n[desktop.appearanceLightChromeTheme.semanticColors]`r`ndiffRemoved = `"#fedcba`"`r`n`r`n[`"desktop`".layout]`r`ndensity = `"compact`"`r`n"
  $nestedOriginal = "[desktop]`r`nappearanceTheme = `"system`"`r`nappearanceLightCodeThemeId = `"github-light`"`r`n`r`n$nestedTables"
  [System.IO.File]::WriteAllText($nestedConfigPath, $nestedOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $nestedConfigPath -BackupPath $nestedBackupPath
  $nestedInstalled = Read-DreamSkinUtf8File -Path $nestedConfigPath
  $nestedDesktop = Get-DreamSkinDesktopSection -Content $nestedInstalled
  if (-not $nestedDesktop.Body.Contains('appearanceTheme = "system"') -or
    -not $nestedDesktop.Body.Contains('appearanceLightCodeThemeId = "codex"')) {
    throw 'Install did not update scalar appearance settings beside nested desktop theme tables.'
  }
  if ([regex]::IsMatch($nestedDesktop.Body, '(?m)^[\t ]*appearanceLightChromeTheme[\t ]*=')) {
    throw 'Install wrote an inline light chrome theme beside the equivalent nested table.'
  }
  if (-not $nestedInstalled.Contains($nestedTables)) {
    throw 'Install changed native Codex chrome theme or unrelated nested desktop tables.'
  }
  Restore-DreamSkinBaseTheme -ConfigPath $nestedConfigPath -BackupPath $nestedBackupPath
  if ((Read-DreamSkinUtf8File -Path $nestedConfigPath) -cne $nestedOriginal) {
    throw 'Nested desktop theme tables were not preserved through install and restore.'
  }

  $singleLineArrayPath = Join-Path $temporaryRoot 'config-single-line-array.toml'
  $singleLineArrayBackup = Join-Path $temporaryRoot 'config-single-line-array.before.toml'
  $singleLineArray = "labels = [`"name[1]`", `"#tag]`"]`r`n"
  [System.IO.File]::WriteAllText($singleLineArrayPath, $singleLineArray, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $singleLineArrayPath -BackupPath $singleLineArrayBackup
  if (-not (Read-DreamSkinUtf8File -Path $singleLineArrayPath).Contains($singleLineArray.TrimEnd())) {
    throw 'A safe single-line array containing bracket text was changed or rejected.'
  }

  foreach ($unsupported in @(
    'desktop.appearanceTheme = "system"',
    'desktop = { appearanceTheme = "system" }',
    '[[desktop]]',
    '[[desktop.layout]]',
    '[desktop.appearanceTheme]',
    '[desktop.appearanceLightCodeThemeId]',
    "[desktop]`r`nappearanceLightChromeTheme = { accent = `"#ffffff`" }`r`n`r`n[desktop.appearanceLightChromeTheme]`r`naccent = `"#000000`"",
    '["desk\u0074op".layout]',
    '["desk\u0074op"]',
    "note = `"`"`"fake`r`n[desktop]`r`nappearanceTheme = `"dark`"`r`n`"`"`"",
    "[desktop]`r`nappearanceTheme = [`r`n  `"light`"`r`n]",
    "[desktop]`r`nlayout = [`r`n  [1, 2],`r`n  [3, 4],`r`n]`r`nappearanceTheme = `"dark`"",
    "[desktop]`r`nlayout = [`"]`",`r`n  [`"[`", `"]`"],`r`n]`r`nappearanceTheme = `"dark`""
  )) {
    $unsupportedPath = Join-Path $temporaryRoot ("unsupported-$([guid]::NewGuid().ToString('N')).toml")
    $unsupportedBackup = "$unsupportedPath.before"
    [System.IO.File]::WriteAllText($unsupportedPath, $unsupported, $utf8NoBom)
    $unsupportedRejected = $false
    try { Install-DreamSkinBaseTheme -ConfigPath $unsupportedPath -BackupPath $unsupportedBackup } catch { $unsupportedRejected = $true }
    if (-not $unsupportedRejected -or (Test-Path -LiteralPath $unsupportedBackup)) {
      throw "Unsupported TOML desktop representation was not rejected safely: $unsupported"
    }
  }

  $recoveryPath = Join-Path $temporaryRoot 'config.before-recovery.toml'
  Write-DreamSkinUtf8FileAtomically -Path $configPath -Content 'intentionally changed'
  Restore-DreamSkinConfigBackup -ConfigPath $configPath -BackupPath $backupPath -RecoveryBackupPath $recoveryPath
  $recoveredBytes = [System.IO.File]::ReadAllBytes($configPath)
  if ([Convert]::ToBase64String($recoveredBytes) -cne [Convert]::ToBase64String($originalBytes)) {
    throw 'Exact config recovery did not restore the original bytes.'
  }
  if ((Read-DreamSkinUtf8File -Path $recoveryPath) -cne 'intentionally changed') {
    throw 'Exact config recovery did not preserve the replaced current config.'
  }
  $archivePath = Join-Path $temporaryRoot 'config.restored.toml'
  Archive-DreamSkinConfigBackup -BackupPath $backupPath -ArchivePath $archivePath
  if ((Test-Path -LiteralPath $backupPath) -or -not (Test-Path -LiteralPath $archivePath)) {
    throw 'Completed config backup was not archived for a safe future reinstall.'
  }
  $secondBaseline = "[desktop]`r`nappearanceTheme = `"dark`"`r`n"
  [System.IO.File]::WriteAllText($configPath, $secondBaseline, $utf8NoBom)
  $secondBaselineBytes = [System.IO.File]::ReadAllBytes($configPath)
  Install-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  if (-not (Test-DreamSkinBytesEqual -Left $secondBaselineBytes -Right ([System.IO.File]::ReadAllBytes($backupPath)))) {
    throw 'Reinstall did not capture a fresh config baseline after completed restore.'
  }

  $invalidPath = Join-Path $temporaryRoot 'invalid.toml'
  $invalidBackupPath = Join-Path $temporaryRoot 'invalid.before.toml'
  [System.IO.File]::WriteAllBytes($invalidPath, [byte[]](0x66, 0x6f, 0x80))
  $rejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $invalidPath -BackupPath $invalidBackupPath } catch { $rejected = $true }
  if (-not $rejected -or (Test-Path -LiteralPath $invalidBackupPath)) {
    throw 'Invalid UTF-8 input was not rejected before backup creation.'
  }
  $utf16Path = Join-Path $temporaryRoot 'utf16.toml'
  $utf16BackupPath = Join-Path $temporaryRoot 'utf16.before.toml'
  [System.IO.File]::WriteAllText($utf16Path, 'model = "gpt-5"', [System.Text.Encoding]::Unicode)
  $utf16Rejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $utf16Path -BackupPath $utf16BackupPath } catch { $utf16Rejected = $true }
  if (-not $utf16Rejected -or (Test-Path -LiteralPath $utf16BackupPath)) {
    throw 'A UTF-16 config was silently transcoded instead of being rejected.'
  }
  $utf16NoBomPath = Join-Path $temporaryRoot 'utf16-no-bom.toml'
  $utf16NoBomBackupPath = Join-Path $temporaryRoot 'utf16-no-bom.before.toml'
  [System.IO.File]::WriteAllBytes($utf16NoBomPath, [System.Text.Encoding]::Unicode.GetBytes('model = "gpt-5"'))
  $utf16NoBomRejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $utf16NoBomPath -BackupPath $utf16NoBomBackupPath } catch { $utf16NoBomRejected = $true }
  if (-not $utf16NoBomRejected -or (Test-Path -LiteralPath $utf16NoBomBackupPath)) {
    throw 'A BOM-less UTF-16 config was silently treated as UTF-8 instead of being rejected.'
  }
  $racePath = Join-Path $temporaryRoot 'race.toml'
  [System.IO.File]::WriteAllText($racePath, 'before', $utf8NoBom)
  $raceExpected = [System.IO.File]::ReadAllBytes($racePath)
  [System.IO.File]::WriteAllText($racePath, 'after', $utf8NoBom)
  $raceRejected = $false
  try { Assert-DreamSkinFileUnchanged -Path $racePath -ExpectedBytes $raceExpected } catch { $raceRejected = $true }
  if (-not $raceRejected) { throw 'Concurrent config modification was not detected.' }
  $conditionalWriteRejected = $false
  try {
    Write-DreamSkinUtf8FileAtomically -Path $racePath -Content 'replacement' -ExpectedBytes $raceExpected
  } catch {
    $conditionalWriteRejected = $true
  }
  if (-not $conditionalWriteRejected -or (Read-DreamSkinUtf8File -Path $racePath) -cne 'after') {
    throw 'Conditional atomic write replaced newer config content.'
  }

  if (-not (Test-DreamSkinWebSocketUrl -Value 'ws://127.0.0.1:9335/devtools/page/test' -Port 9335)) {
    throw 'PowerShell loopback WebSocket validation rejected a safe target.'
  }
  foreach ($unsafe in @(
    'ws://example.com:9335/devtools/page/test',
    'ws://127.0.0.1:9336/devtools/page/test',
    'wss://127.0.0.1:9335/devtools/page/test',
    'ws://user@127.0.0.1:9335/devtools/page/test',
    'ws://127.0.0.1:9335/unexpected/test',
    'ws://127.0.0.1:9335/devtools/page/test?query=1'
  )) {
    if (Test-DreamSkinWebSocketUrl -Value $unsafe -Port 9335) { throw "Accepted unsafe CDP target: $unsafe" }
  }
  $safePageTarget = [pscustomobject]@{
    id = 'page-123'
    type = 'page'
    url = 'app://codex/'
    webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/page/page-123'
  }
  if (-not (Test-DreamSkinCdpPageTarget -Target $safePageTarget -Port 9335)) {
    throw 'A valid same-ID CDP page target was rejected.'
  }
  foreach ($unsafePageTarget in @(
    [pscustomobject]@{ id = 'page-123'; type = 'page'; url = 'app://codex/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/browser/page-123' },
    [pscustomobject]@{ id = 'other-page'; type = 'page'; url = 'app://codex/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/page/page-123' },
    [pscustomobject]@{ id = 123; type = 'page'; url = 'app://codex/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/page/123' },
    [pscustomobject]@{ id = 'page-123'; type = 'other'; url = 'app://codex/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/page/page-123' }
  )) {
    if (Test-DreamSkinCdpPageTarget -Target $unsafePageTarget -Port 9335) {
      throw 'Accepted an inconsistent CDP page target.'
    }
  }
  $watchCommand = '"C:\Program Files\nodejs\node.exe" "C:\Dream Skin\injector.mjs" --watch --port 9335 --browser-id browser-123'
  if (-not (Test-DreamSkinCommandLineToken -CommandLine $watchCommand -Token 'C:\Dream Skin\injector.mjs') -or
    (Test-DreamSkinCommandLineToken -CommandLine $watchCommand -Token 'Dream Skin\injector.mjs')) {
    throw 'Injector command-line token validation is not boundary-safe.'
  }
  if (-not (Test-DreamSkinBrowserId -Value 'browser-123') -or
    (Test-DreamSkinBrowserId -Value 'browser 123')) {
    throw 'CDP browser ID validation is not boundary-safe.'
  }
  $quotedProfile = ConvertTo-DreamSkinProcessArgument -Value '--user-data-dir=C:\Dream Skin\Profile\'
  if ($quotedProfile -cne '"--user-data-dir=C:\Dream Skin\Profile\\"') {
    throw 'Process argument quoting did not protect spaces and a trailing backslash.'
  }
  $argumentLine = ConvertTo-DreamSkinArgumentLine -Arguments @(
    '--remote-debugging-address=127.0.0.1',
    '--user-data-dir=C:\Dream Skin\Profile\',
    ''
  )
  if ($argumentLine -cne '--remote-debugging-address=127.0.0.1 "--user-data-dir=C:\Dream Skin\Profile\\" ""') {
    throw 'Packaged-app argument line quoting failed.'
  }
  Initialize-DreamSkinPackageLauncher
  if (-not ('CodexDreamSkin.PackageLauncher' -as [type])) {
    throw 'Packaged-app activation helper did not compile.'
  }
  $invalidActivationRejected = $false
  try { $null = Start-DreamSkinCodex -Codex ([pscustomobject]@{ AppUserModelId = 'invalid app' }) } catch {
    $invalidActivationRejected = $true
  }
  if (-not $invalidActivationRejected) { throw 'An invalid AppUserModelId reached package activation.' }

  $statePath = Join-Path $temporaryRoot 'state.json'
  $state = [pscustomobject]@{
    schemaVersion = 3
    platform = 'windows'
    port = 9335
    injectorPid = 1234
    injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
    injectorPath = 'C:\Dream Skin\injector.mjs'
    nodePath = 'C:\Program Files\nodejs\node.exe'
    codexExe = 'C:\Program Files\WindowsApps\OpenAI.Codex\app\ChatGPT.exe'
    codexPackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex'
    codexPackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'
    codexPackageFamilyName = 'OpenAI.Codex_test'
    browserId = 'browser-123'
  }
  Write-DreamSkinState -Path $statePath -State $state
  $loadedState = Read-DreamSkinState -Path $statePath
  if ($loadedState.schemaVersion -ne 3 -or $loadedState.port -ne 9335 -or
    $loadedState.browserId -cne 'browser-123') { throw 'State round-trip failed.' }
  $missingIdentityState = [pscustomobject]@{ schemaVersion = 3; platform = 'windows'; port = 9335 }
  Write-DreamSkinState -Path $statePath -State $missingIdentityState
  $missingIdentityRejected = $false
  try { $null = Read-DreamSkinState -Path $statePath } catch { $missingIdentityRejected = $true }
  if (-not $missingIdentityRejected) { throw 'Schema 3 accepted a state missing process and package identity.' }
  $legacyState = [pscustomobject]@{ schemaVersion = 2; platform = 'windows'; port = 9335; injectorPid = 1234 }
  Write-DreamSkinState -Path $statePath -State $legacyState
  if ((Read-DreamSkinState -Path $statePath).schemaVersion -ne 2) {
    throw 'A supported schema 2 state was rejected.'
  }

  $fakePackageRoot = Join-Path $temporaryRoot 'OpenAI.Codex_1.2.3.4_x64__test'
  $fakeExecutable = Join-Path $fakePackageRoot 'app\ChatGPT.exe'
  New-Item -ItemType Directory -Path (Split-Path -Parent $fakeExecutable) -Force | Out-Null
  [System.IO.File]::WriteAllBytes($fakeExecutable, [byte[]]@())
  $fakePackage = [pscustomobject]@{
    Name = 'OpenAI.Codex'
    InstallLocation = $fakePackageRoot
    PackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'
    PackageFamilyName = 'OpenAI.Codex_test'
    SignatureKind = 'Store'
    IsDevelopmentMode = $false
    Version = [version]'1.2.3.4'
  }
  $fakeManifest = [pscustomobject]@{
    Package = [pscustomobject]@{
      Applications = [pscustomobject]@{
        Application = @(
          [pscustomobject]@{ Id = 'Other'; Executable = 'other\Other.exe' },
          [pscustomobject]@{ Id = 'App'; Executable = 'app/ChatGPT.exe' }
        )
      }
    }
  }
  $fakeInstall = ConvertTo-DreamSkinCodexInstall -Package $fakePackage -Manifest $fakeManifest
  if ($null -eq $fakeInstall -or $fakeInstall.PackageFullName -cne $fakePackage.PackageFullName -or
    $fakeInstall.AppUserModelId -cne 'OpenAI.Codex_test!App' -or
    -not (Test-DreamSkinPathEqual -Left $fakeInstall.Executable -Right $fakeExecutable)) {
    throw 'Registered Appx package identity conversion failed.'
  }
  $fakeManifest.Package.Applications.Application[1].Id = 'Invalid App'
  if ($null -ne (ConvertTo-DreamSkinCodexInstall -Package $fakePackage -Manifest $fakeManifest)) {
    throw 'An invalid packaged-app application ID was accepted.'
  }
  $fakeManifest.Package.Applications.Application[1].Id = 'App'
  $fakeManifest.Package.Applications.Application += [pscustomobject]@{ Id = 'Duplicate'; Executable = 'app\ChatGPT.exe' }
  if ($null -ne (ConvertTo-DreamSkinCodexInstall -Package $fakePackage -Manifest $fakeManifest)) {
    throw 'An ambiguous packaged-app manifest was accepted.'
  }
  $fakeManifest.Package.Applications.Application = @($fakeManifest.Package.Applications.Application[0..1])
  $fakePackage.SignatureKind = 'Developer'
  if ($null -ne (ConvertTo-DreamSkinCodexInstall -Package $fakePackage -Manifest $fakeManifest)) {
    throw 'A non-Store Appx package was accepted as official Codex.'
  }
  $fakePackage.SignatureKind = 'Store'
  $pathOnlyState = [pscustomobject]@{
    codexExe = $fakeExecutable
    codexPackageRoot = $fakePackageRoot
    codexVersion = '1.2.3.4'
  }
  if ($null -eq (Get-DreamSkinCodexStatePathCandidate -State $pathOnlyState)) {
    throw 'A structurally valid legacy Codex path was not recognized for read-only activity checks.'
  }
  if ($null -eq (Resolve-DreamSkinCodexInstallFromState -State $pathOnlyState `
    -RegisteredInstalls @($fakeInstall))) {
    throw 'A legacy state path was not revalidated against a registered Store package.'
  }
  $verifiedPackageState = [pscustomobject]@{
    codexExe = $fakeExecutable
    codexPackageRoot = $fakePackageRoot
    codexVersion = '1.2.3.4'
    codexPackageFullName = $fakePackage.PackageFullName
    codexPackageFamilyName = $fakePackage.PackageFamilyName
  }
  $resolvedInstall = Resolve-DreamSkinCodexInstallFromState -State $verifiedPackageState `
    -RegisteredInstalls @($fakeInstall)
  if ($null -eq $resolvedInstall -or -not $resolvedInstall.RegisteredPackageVerified -or
    $resolvedInstall.AppUserModelId -cne $fakeInstall.AppUserModelId) {
    throw 'State package identity did not resolve against the registered Appx package.'
  }
  $verifiedPackageState.codexPackageFamilyName = 'OpenAI.Codex_wrong'
  if ($null -ne (Resolve-DreamSkinCodexInstallFromState -State $verifiedPackageState `
    -RegisteredInstalls @($fakeInstall))) {
    throw 'A mismatched Appx package family was accepted from state.'
  }
  Write-DreamSkinUtf8FileAtomically -Path $statePath -Content '[]'
  $badStateRejected = $false
  try { $null = Read-DreamSkinState -Path $statePath } catch { $badStateRejected = $true }
  if (-not $badStateRejected) { throw 'A non-object state file was accepted.' }
  $staleStatePath = Archive-DreamSkinStateFile -Path $statePath
  if ((Test-Path -LiteralPath $statePath) -or -not (Test-Path -LiteralPath $staleStatePath)) {
    throw 'Stale state was not preserved under an archive name.'
  }

  $themeStateRoot = Join-Path $temporaryRoot 'theme-state'
  $themePaths = Initialize-DreamSkinThemeStore -SkillRoot $Root -StateRoot $themeStateRoot
  $initialTheme = Read-DreamSkinTheme -ThemeDirectory $themePaths.Active
  if ($initialTheme.Theme.id -cne 'preset-romantic-rose' -or
    $initialTheme.Theme.name -cne '桥本有菜' -or
    $initialTheme.Theme.appearance -cne 'auto' -or
    $initialTheme.Theme.art.safeArea -cne 'left' -or
    $initialTheme.Theme.art.taskMode -cne 'ambient' -or
    [System.IO.Path]::GetExtension($initialTheme.ImagePath) -cne '.jpg') {
    throw 'Default Windows theme did not seed the Arina Hashimoto wallpaper contract.'
  }
  $preseededThemes = @(Get-DreamSkinSavedThemes -StateRoot $themeStateRoot)
  if ($preseededThemes.Count -ne 1 -or
    $preseededThemes[0].Id -cne 'preset-romantic-rose' -or
    $preseededThemes[0].Name -cne '桥本有菜') {
    throw 'Arina Hashimoto was not preseeded in the Windows saved-theme menu.'
  }
  $updatedTheme = Set-DreamSkinActiveTheme -ImagePath (Join-Path $Root 'assets\dream-reference.jpg') `
    -Theme $null -Name '测试主题' -StateRoot $themeStateRoot
  if ($updatedTheme.Theme.name -cne '测试主题' -or
    $updatedTheme.Theme.id -cne 'custom' -or
    $updatedTheme.Theme.art.safeArea -cne 'auto' -or
    $updatedTheme.Theme.art.taskMode -cne 'auto' -or
    [double]$updatedTheme.Theme.media.opacity -ne 1 -or
    -not (Test-DreamSkinThemePathWithin -Path $updatedTheme.ImagePath -Root $themePaths.Active)) {
    throw 'Imported image did not reset to the generic adaptive contract inside the managed directory.'
  }
  $activeMediaBeforeSchemaReject = @(
    Get-ChildItem -LiteralPath $themePaths.Active -File | Select-Object -ExpandProperty Name | Sort-Object
  )
  $unsupportedInputThemeRejected = $false
  try {
    $null = Set-DreamSkinActiveTheme -ImagePath (Join-Path $Root 'assets\dream-reference.jpg') `
      -Theme ([pscustomobject]@{ schemaVersion = 2; id = 'unsupported'; image = 'ignored.jpg' }) `
      -StateRoot $themeStateRoot
  } catch {
    $unsupportedInputThemeRejected = $true
  }
  $activeMediaAfterSchemaReject = @(
    Get-ChildItem -LiteralPath $themePaths.Active -File | Select-Object -ExpandProperty Name | Sort-Object
  )
  if (-not $unsupportedInputThemeRejected -or
    (@($activeMediaBeforeSchemaReject) -join '|') -cne (@($activeMediaAfterSchemaReject) -join '|')) {
    throw 'A non-v1 caller theme changed active media before being rejected.'
  }
  $opacityTheme = Set-DreamSkinActiveThemeMediaOpacity -Opacity 0.42 -StateRoot $themeStateRoot
  if ([math]::Abs((Get-DreamSkinThemeMediaOpacity -Theme $opacityTheme.Theme) - 0.42) -gt 0.000001) {
    throw 'Active theme opacity was not persisted.'
  }
  if ((Get-DreamSkinThemeMediaRevealPercent -Theme ([pscustomobject]@{
      media = [pscustomobject]@{ opacity = 1 }
    })) -ne 100 -or
    (Get-DreamSkinThemeMediaRevealPercent -Theme ([pscustomobject]@{
      media = [pscustomobject]@{ opacity = 0 }
    })) -ne 0 -or
    [math]::Abs((ConvertTo-DreamSkinMediaOpacityFromRevealPercent -Percent 100) - 1) -gt 0.000001 -or
    [math]::Abs((ConvertTo-DreamSkinMediaOpacityFromRevealPercent -Percent 55) - 0.55) -gt 0.000001) {
    throw 'Tray wallpaper reveal percentage does not match the foreground veil contract.'
  }
  $invalidOpacityRejected = $false
  try { $null = Set-DreamSkinActiveThemeMediaOpacity -Opacity 1.1 -StateRoot $themeStateRoot } catch {
    $invalidOpacityRejected = $true
  }
  if (-not $invalidOpacityRejected) { throw 'Theme opacity accepted a value above 1.' }
  $null = Initialize-DreamSkinThemeStore -SkillRoot $Root -StateRoot $themeStateRoot
  $idempotentTheme = Read-DreamSkinTheme -ThemeDirectory $themePaths.Active
  if ($idempotentTheme.Theme.id -cne 'custom' -or
    @(Get-DreamSkinSavedThemes -StateRoot $themeStateRoot).Count -ne 1) {
    throw 'Theme-store initialization overwrote the active custom theme or duplicated its bundled preset.'
  }
  $savedTheme = Save-DreamSkinCurrentTheme -Name '已保存主题' -StateRoot $themeStateRoot
  if ($savedTheme.Theme.name -cne '已保存主题' -or
    [math]::Abs((Get-DreamSkinThemeMediaOpacity -Theme $savedTheme.Theme) - 0.42) -gt 0.000001 -or
    @(Get-DreamSkinSavedThemes -StateRoot $themeStateRoot).Count -ne 2) {
    throw 'Saved theme creation or discovery failed.'
  }
  $null = Use-DreamSkinSavedTheme -ThemeDirectory $savedTheme.Directory -StateRoot $themeStateRoot

  $videoFixture = Join-Path $temporaryRoot 'loop.mp4'
  $videoBytes = New-Object byte[] 1024
  $videoBytes[0] = 0; $videoBytes[1] = 0; $videoBytes[2] = 0; $videoBytes[3] = 24
  [System.Text.Encoding]::ASCII.GetBytes('ftypisom') | ForEach-Object -Begin { $i = 4 } -Process {
    $videoBytes[$i++] = $_
  }
  [System.IO.File]::WriteAllBytes($videoFixture, $videoBytes)
  $videoTheme = Set-DreamSkinActiveTheme -ImagePath $videoFixture -Theme $null `
    -Name '动态测试主题' -StateRoot $themeStateRoot
  if ($videoTheme.Theme.media.type -cne 'video' -or
    [double]$videoTheme.Theme.media.opacity -ne 1 -or
    [System.IO.Path]::GetExtension($videoTheme.ImagePath) -cne '.mp4' -or
    -not (Test-DreamSkinThemePathWithin -Path $videoTheme.ImagePath -Root $themePaths.Active)) {
    throw 'Imported video did not become a managed dynamic theme.'
  }
  $savedVideoTheme = Save-DreamSkinCurrentTheme -Name '已保存动态主题' -StateRoot $themeStateRoot
  if ($savedVideoTheme.Theme.media.type -cne 'video' -or
    @(Get-DreamSkinSavedThemes -StateRoot $themeStateRoot).Count -ne 3) {
    throw 'Dynamic theme save or discovery failed.'
  }
  $restoredVideoTheme = Use-DreamSkinSavedTheme -ThemeDirectory $savedVideoTheme.Directory `
    -StateRoot $themeStateRoot
  if ($restoredVideoTheme.Theme.media.type -cne 'video') {
    throw 'Saved dynamic theme did not preserve its media contract.'
  }

  $managerCommandPath = Join-Path $Root 'scripts\manager-command.ps1'
  function Invoke-DreamSkinManagerCommandForTest {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $managerCommandPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Manager command failed: $($output -join [Environment]::NewLine)"
    }
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop)
  }
  $newManagerStateRoot = Join-Path $temporaryRoot 'new-manager-state'
  $managerSeededThemes = Invoke-DreamSkinManagerCommandForTest -Arguments @(
    '-Action', 'ListThemes', '-StateRoot', $newManagerStateRoot
  )
  if (@($managerSeededThemes.themes).Count -ne 1 -or
    $managerSeededThemes.themes[0].id -cne 'preset-romantic-rose') {
    throw 'Manager command did not initialize a new theme store before listing saved themes.'
  }
  $managerSavedThemes = Invoke-DreamSkinManagerCommandForTest -Arguments @(
    '-Action', 'ListThemes', '-StateRoot', $themeStateRoot
  )
  if ($managerSavedThemes.action -cne 'ListThemes' -or
    @($managerSavedThemes.themes).Count -ne 3 -or
    @($managerSavedThemes.themes | Where-Object { $_.mediaType -ceq 'video' }).Count -lt 1) {
    throw 'Manager command did not list saved static and dynamic themes.'
  }
  $managerSavedTheme = Invoke-DreamSkinManagerCommandForTest -Arguments @(
    '-Action', 'SaveTheme', '-Name', '管理器保存的动态主题', '-StateRoot', $themeStateRoot
  )
  if ($managerSavedTheme.action -cne 'SaveTheme' -or
    $managerSavedTheme.name -cne '管理器保存的动态主题' -or
    $managerSavedTheme.mediaType -cne 'video' -or -not $managerSavedTheme.themeId) {
    throw 'Manager command did not save the active dynamic theme.'
  }
  $managerAppliedTheme = Invoke-DreamSkinManagerCommandForTest -Arguments @(
    '-Action', 'UseTheme', '-ThemeId', "$($managerSavedTheme.themeId)", '-StateRoot', $themeStateRoot
  )
  if ($managerAppliedTheme.action -cne 'UseTheme' -or
    $managerAppliedTheme.themeId -cne $managerSavedTheme.themeId -or
    $managerAppliedTheme.mediaType -cne 'video' -or
    (Read-DreamSkinTheme -ThemeDirectory $themePaths.Active).Theme.id -cne $managerSavedTheme.themeId) {
    throw 'Manager command did not apply the selected saved dynamic theme.'
  }

  $steamLibrary = Join-Path $temporaryRoot 'Steam Library'
  $wallpaperEngineContent = Join-Path $steamLibrary 'steamapps\workshop\content\431960'
  $wallpaperEngineItem = Join-Path $wallpaperEngineContent '1234567890'
  New-Item -ItemType Directory -Path $wallpaperEngineItem -Force | Out-Null
  $wallpaperEngineVideo = Join-Path $wallpaperEngineItem 'wallpaper.mp4'
  Copy-Item -LiteralPath $videoFixture -Destination $wallpaperEngineVideo
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $wallpaperEngineItem 'project.json') -Content @'
{"type":"video","file":"wallpaper.mp4","title":"本地动态壁纸"}
'@
  $referencedTheme = Set-DreamSkinActiveWallpaperEngineTheme -ProjectDirectory $wallpaperEngineItem `
    -Name 'Wallpaper Engine 本地引用' -StateRoot $themeStateRoot
  if ($referencedTheme.MediaPath -cne [System.IO.Path]::GetFullPath($wallpaperEngineVideo) -or
    $referencedTheme.Theme.media.source -cne 'wallpaper-engine-local' -or
    $referencedTheme.Theme.media.workshopId -cne '1234567890' -or
    $referencedTheme.Theme.media.relativePath -cne 'wallpaper.mp4' -or
    (Test-Path -LiteralPath (Join-Path $themePaths.Active 'wallpaper.mp4'))) {
    throw 'Wallpaper Engine video was not retained as a direct local reference.'
  }
  New-Item -ItemType Directory -Path $themePaths.MediaCache -Force | Out-Null
  $performanceProxy = Join-Path $themePaths.MediaCache '1234567890-test-1080p.mp4'
  Copy-Item -LiteralPath $videoFixture -Destination $performanceProxy
  $referencedTheme.Theme.media | Add-Member -NotePropertyName proxy `
    -NotePropertyValue 'media-cache/1234567890-test-1080p.mp4' -Force
  Write-DreamSkinTheme -ThemeDirectory $themePaths.Active -Theme $referencedTheme.Theme
  $referencedTheme = Read-DreamSkinTheme -ThemeDirectory $themePaths.Active
  if ($referencedTheme.ImagePath -cne [System.IO.Path]::GetFullPath($wallpaperEngineVideo) -or
    $referencedTheme.MediaPath -cne [System.IO.Path]::GetFullPath($performanceProxy)) {
    throw 'Wallpaper Engine performance proxy did not preserve its original existence reference.'
  }
  $savedReferencedTheme = Save-DreamSkinCurrentTheme -Name '保存的本地引用' -StateRoot $themeStateRoot
  if ($savedReferencedTheme.Theme.media.source -cne 'wallpaper-engine-local' -or
    (Test-Path -LiteralPath (Join-Path $savedReferencedTheme.Directory 'wallpaper.mp4'))) {
    throw 'Saving a Wallpaper Engine reference copied its media instead of preserving the mapping.'
  }
  $restoredReferencedTheme = Use-DreamSkinSavedTheme -ThemeDirectory $savedReferencedTheme.Directory `
    -StateRoot $themeStateRoot
  if ($restoredReferencedTheme.ImagePath -cne [System.IO.Path]::GetFullPath($wallpaperEngineVideo) -or
    $restoredReferencedTheme.MediaPath -cne [System.IO.Path]::GetFullPath($performanceProxy) -or
    $restoredReferencedTheme.Theme.media.source -cne 'wallpaper-engine-local') {
    throw 'Saved Wallpaper Engine reference did not restore its source and performance proxy.'
  }
  $unsafeWallpaperEngineItem = Join-Path $wallpaperEngineContent '9876543210'
  New-Item -ItemType Directory -Path $unsafeWallpaperEngineItem -Force | Out-Null
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $unsafeWallpaperEngineItem 'project.json') -Content @'
{"type":"video","file":"..\\wallpaper.mp4"}
'@
  $unsafeWallpaperEngineRejected = $false
  try {
    $null = Set-DreamSkinActiveWallpaperEngineTheme -ProjectDirectory $unsafeWallpaperEngineItem `
      -StateRoot $themeStateRoot
  } catch {
    $unsafeWallpaperEngineRejected = $true
  }
  if (-not $unsafeWallpaperEngineRejected) {
    throw 'Wallpaper Engine mapping accepted a project media path that escaped its Workshop item directory.'
  }
  $sceneWallpaperEngineItem = Join-Path $wallpaperEngineContent '2468013579'
  $sceneVideoDirectory = Join-Path $sceneWallpaperEngineItem 'assets'
  New-Item -ItemType Directory -Path $sceneVideoDirectory -Force | Out-Null
  $sceneVideo = Join-Path $sceneVideoDirectory 'loop.webm'
  [System.IO.File]::WriteAllBytes($sceneVideo, [byte[]](0x1a, 0x45, 0xdf, 0xa3, 0x42, 0x86, 0x81, 0x01))
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $sceneWallpaperEngineItem 'project.json') -Content @'
{"type":"scene","title":"场景中的独立视频"}
'@
  $managerWallpaperEngineItems = Invoke-DreamSkinManagerCommandForTest -Arguments @(
    '-Action', 'ListWallpaperEngine', '-SteamLibraryPath', $steamLibrary, '-StateRoot', $themeStateRoot
  )
  if ($managerWallpaperEngineItems.action -cne 'ListWallpaperEngine' -or
    @($managerWallpaperEngineItems.items).Count -ne 1 -or
    @($managerWallpaperEngineItems.items | Where-Object { $_.workshopId -ceq '1234567890' }).Count -ne 1 -or
    @($managerWallpaperEngineItems.items | Where-Object {
      $_.workshopId -ceq '2468013579'
    }).Count -ne 0) {
    throw 'Wallpaper Engine discovery listed an embedded Scene/Web video instead of one directly playable video project.'
  }
  $steamInstall = Join-Path $temporaryRoot 'Steam Install'
  New-Item -ItemType Directory -Path (Join-Path $steamInstall 'steamapps') -Force | Out-Null
  $escapedSteamLibrary = $steamLibrary.Replace('\', '\\')
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $steamInstall 'steamapps\libraryfolders.vdf') -Content @"
"libraryfolders"
{
  "1"
  {
    "path" "$escapedSteamLibrary"
  }
}
"@
  $managerLibraryFolderItems = Invoke-DreamSkinManagerCommandForTest -Arguments @(
    '-Action', 'ListWallpaperEngine', '-SteamLibraryPath', $steamInstall, '-StateRoot', $themeStateRoot
  )
  if (@($managerLibraryFolderItems.items).Count -ne 1 -or
    @($managerLibraryFolderItems.items | Where-Object { $_.workshopId -ceq '1234567890' }).Count -ne 1) {
    throw 'Wallpaper Engine discovery did not resolve a secondary Steam library from libraryfolders.vdf.'
  }
  $managerWallpaperEngineTheme = Invoke-DreamSkinManagerCommandForTest -Arguments @(
    '-Action', 'UseWallpaperEngine', '-Path', $sceneVideo, '-StateRoot', $themeStateRoot
  )
  if ($managerWallpaperEngineTheme.action -cne 'UseWallpaperEngine' -or
    $managerWallpaperEngineTheme.mediaPath -cne [System.IO.Path]::GetFullPath($sceneVideo) -or
    (Read-DreamSkinTheme -ThemeDirectory $themePaths.Active).Theme.media.source -cne 'wallpaper-engine-local') {
    throw 'Manager command did not apply a Wallpaper Engine item as a direct local reference.'
  }

  $unsupportedSchemaTheme = Join-Path $temporaryRoot 'unsupported-schema-theme'
  New-Item -ItemType Directory -Path $unsupportedSchemaTheme | Out-Null
  Copy-Item -LiteralPath $videoFixture -Destination (Join-Path $unsupportedSchemaTheme 'loop.mp4')
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $unsupportedSchemaTheme 'theme.json') `
    -Content "{`"schemaVersion`":2,`"image`":`"loop.mp4`",`"media`":{`"type`":`"video`"}}`r`n"
  $unsupportedSchemaRejected = $false
  try { $null = Read-DreamSkinTheme -ThemeDirectory $unsupportedSchemaTheme } catch {
    $unsupportedSchemaRejected = $true
  }
  if (-not $unsupportedSchemaRejected) { throw 'Theme schema versions other than 1 must be rejected.' }
  $nonIntegralSchemaTheme = Join-Path $temporaryRoot 'non-integral-schema-theme'
  New-Item -ItemType Directory -Path $nonIntegralSchemaTheme | Out-Null
  Copy-Item -LiteralPath $videoFixture -Destination (Join-Path $nonIntegralSchemaTheme 'loop.mp4')
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $nonIntegralSchemaTheme 'theme.json') `
    -Content "{`"schemaVersion`":1.1,`"image`":`"loop.mp4`",`"media`":{`"type`":`"video`"}}`r`n"
  $nonIntegralSchemaRejected = $false
  try { $null = Read-DreamSkinTheme -ThemeDirectory $nonIntegralSchemaTheme } catch {
    $nonIntegralSchemaRejected = $true
  }
  if (-not $nonIntegralSchemaRejected) { throw 'A non-integer theme schemaVersion was accepted as version 1.' }
  $fakeVideo = Join-Path $temporaryRoot 'fake.mp4'
  [System.IO.File]::WriteAllText($fakeVideo, 'not an mp4')
  $fakeVideoRejected = $false
  try {
    $null = Set-DreamSkinActiveTheme -ImagePath $fakeVideo -Theme $null -StateRoot $themeStateRoot
  } catch { $fakeVideoRejected = $true }
  if (-not $fakeVideoRejected) { throw 'A file with a forged MP4 extension was imported as a dynamic theme.' }

  $outsideTheme = Join-Path $temporaryRoot 'outside-theme'
  New-Item -ItemType Directory -Path $outsideTheme | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'assets\dream-reference.jpg') `
    -Destination (Join-Path $outsideTheme 'dream-reference.jpg')
  Copy-Item -LiteralPath (Join-Path $Root 'assets\theme.json') `
    -Destination (Join-Path $outsideTheme 'theme.json')
  $junctionTheme = Join-Path $themePaths.Saved 'junction-escape'
  $null = New-Item -ItemType Junction -Path $junctionTheme -Target $outsideTheme
  $junctionRejected = $false
  try {
    $null = Use-DreamSkinSavedTheme -ThemeDirectory $junctionTheme -StateRoot $themeStateRoot
  } catch { $junctionRejected = $true }
  if (-not $junctionRejected) { throw 'Saved-theme junction escaped the managed theme directory.' }
  [System.IO.Directory]::Delete($junctionTheme)

  Set-DreamSkinPaused -Paused $true -StateRoot $themeStateRoot | Out-Null
  if (-not (Test-DreamSkinPaused -StateRoot $themeStateRoot)) { throw 'Pause marker was not created.' }
  Set-DreamSkinPaused -Paused $false -StateRoot $themeStateRoot | Out-Null
  if (Test-DreamSkinPaused -StateRoot $themeStateRoot) { throw 'Pause marker was not removed.' }

  $oversizedTheme = Join-Path $temporaryRoot 'oversized-theme'
  New-Item -ItemType Directory -Path $oversizedTheme | Out-Null
  $oversizedImage = Join-Path $oversizedTheme 'oversized.jpg'
  $oversizedStream = [System.IO.File]::Open($oversizedImage, [System.IO.FileMode]::CreateNew)
  try { $oversizedStream.SetLength((16 * 1024 * 1024) + 1) } finally { $oversizedStream.Dispose() }
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $oversizedTheme 'theme.json') `
    -Content "{`"image`":`"oversized.jpg`"}`r`n"
  $oversizedReadRejected = $false
  try { $null = Read-DreamSkinTheme -ThemeDirectory $oversizedTheme } catch { $oversizedReadRejected = $true }
  $oversizedSetRejected = $false
  try {
    $null = Set-DreamSkinActiveTheme -ImagePath $oversizedImage -Theme $null -StateRoot $themeStateRoot
  } catch { $oversizedSetRejected = $true }
  if (-not $oversizedReadRejected -or -not $oversizedSetRejected) {
    throw 'The 16 MB image limit was not enforced before theme copy or payload construction.'
  }

  $oversizedDimensionImage = Join-Path $temporaryRoot 'oversized-dimension.png'
  $pngHeader = New-Object byte[] 24
  [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a) | ForEach-Object -Begin { $i = 0 } -Process { $pngHeader[$i++] = $_ }
  $pngHeader[8] = 0; $pngHeader[9] = 0; $pngHeader[10] = 0; $pngHeader[11] = 13
  [byte[]](0x49, 0x48, 0x44, 0x52) | ForEach-Object -Begin { $i = 12 } -Process { $pngHeader[$i++] = $_ }
  $pngHeader[16] = 0; $pngHeader[17] = 0; $pngHeader[18] = 0x27; $pngHeader[19] = 0x10
  $pngHeader[20] = 0; $pngHeader[21] = 0; $pngHeader[22] = 0x17; $pngHeader[23] = 0x70
  [System.IO.File]::WriteAllBytes($oversizedDimensionImage, $pngHeader)
  $oversizedDimensionRejected = $false
  try { $null = Set-DreamSkinActiveTheme -ImagePath $oversizedDimensionImage -Theme $null -StateRoot $themeStateRoot } catch { $oversizedDimensionRejected = $true }
  if (-not $oversizedDimensionRejected) { throw 'A 16384px/50MP-invalid import was copied into the active theme.' }

  $reparseStateRoot = Join-Path $temporaryRoot 'reparse-state'
  New-Item -ItemType Directory -Path $reparseStateRoot | Out-Null
  $outsideActive = Join-Path $temporaryRoot 'outside-active'
  New-Item -ItemType Directory -Path $outsideActive | Out-Null
  $reparseActive = Join-Path $reparseStateRoot 'active-theme'
  $null = New-Item -ItemType Junction -Path $reparseActive -Target $outsideActive
  $reparseInitRejected = $false
  try { $null = Initialize-DreamSkinThemeStore -SkillRoot $Root -StateRoot $reparseStateRoot } catch { $reparseInitRejected = $true }
  if (-not $reparseInitRejected) { throw 'Theme-store initialization followed an active-theme junction.' }
  [System.IO.Directory]::Delete($reparseActive)

  $css = Read-DreamSkinUtf8File -Path (Join-Path $Root 'assets\dream-skin.css')
  foreach ($requiredCss in @(
    'background-image: var(--dream-art)',
    '--dream-wallpaper-reveal',
    '--dream-wallpaper-cover',
    '--dream-media-overlay',
    'main.main-surface > header.app-header-tint',
    '[class~="group/application-menu-top-bar"]',
    '.app-shell-main-content-top-fade',
    '.thread-scroll-container .bg-gradient-to-t.from-token-main-surface-primary',
    '--dream-immersive-composer',
    'background-position: var(--dream-art-position)',
    '.dream-home-utility',
    '.dream-home-utility-present .dream-home .composer-surface-chrome',
    '.dream-route-task:is(.dream-task-ambient, .dream-task-banner)'
  )) {
    if (-not $css.Contains($requiredCss)) { throw "Windows immersive CSS is missing: $requiredCss" }
  }
  if ($css.Contains(':has(')) { throw 'Windows immersive CSS must not use global reverse selectors.' }

  $managerBuildPath = Join-Path $Root 'app\build-manager.ps1'
  $managerProjectPath = Join-Path $Root 'app\CodexDreamSkin.Manager\CodexDreamSkin.Manager.csproj'
  foreach ($managerPath in @($managerCommandPath, $managerBuildPath, $managerProjectPath)) {
    if (-not (Test-Path -LiteralPath $managerPath -PathType Leaf)) {
      throw "Graphical manager file is missing: $managerPath"
    }
  }
  foreach ($managerScriptPath in @($managerCommandPath, $managerBuildPath)) {
    $managerTokens = $null
    $managerParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $managerScriptPath, [ref]$managerTokens, [ref]$managerParseErrors
    ) | Out-Null
    if ($managerParseErrors.Count -gt 0) {
      throw "Graphical manager PowerShell entry point failed to parse: $managerScriptPath"
    }
  }
  $managerCommandSource = Read-DreamSkinUtf8File -Path $managerCommandPath
  foreach ($managerAction in @(
    'SetWallpaper', 'SetReveal', 'Pause', 'Resume', 'Status', 'ListThemes', 'SaveTheme', 'UseTheme',
    'ListWallpaperEngine', 'UseWallpaperEngine'
  )) {
    if (-not $managerCommandSource.Contains("'$managerAction'")) {
      throw "Graphical manager command is missing: $managerAction"
    }
  }
  $managerProjectSource = Read-DreamSkinUtf8File -Path $managerProjectPath
  foreach ($managerPublishContract in @(
    '<PublishSingleFile>true</PublishSingleFile>',
    '<SelfContained>true</SelfContained>',
    'DreamSkin.Runtime.node.exe',
    'DreamSkin.Engine.scripts.manager-command.ps1'
  )) {
    if (-not $managerProjectSource.Contains($managerPublishContract)) {
      throw "Graphical manager packaging contract is missing: $managerPublishContract"
    }
  }
  $managerFormSource = Read-DreamSkinUtf8File -Path (
    Join-Path $Root 'app\CodexDreamSkin.Manager\MainForm.cs'
  )
  foreach ($managerUiContract in @(
    'Codex 动态壁纸',
    '添加壁纸',
    'Multiselect = true',
    '当前壁纸：{status.CurrentWallpaperLabel}',
    '暂无壁纸 · 点击左侧「添加壁纸」导入',
    '0% · 完全不透明',
    '100% · 完全透明（原始壁纸）',
    '开机启动管理器',
    '退出管理器',
    '支持 PNG、JPEG、WebP、MP4、WebM'
  )) {
    if (-not $managerFormSource.Contains($managerUiContract)) {
      throw "Graphical manager UI contract is missing: $managerUiContract"
    }
  }
  $savedThemesDialogPath = Join-Path $Root 'app\CodexDreamSkin.Manager\SavedThemesDialog.cs'
  if (-not (Test-Path -LiteralPath $savedThemesDialogPath -PathType Leaf)) {
    throw 'Graphical manager saved-theme dialog is missing.'
  }
  $savedThemesDialogSource = Read-DreamSkinUtf8File -Path $savedThemesDialogPath
  foreach ($savedThemesUiContract in @(
    '已保存主题',
    '保存当前主题',
    '应用主题',
    'ListSavedThemesAsync',
    'SaveCurrentThemeAsync',
    'ApplySavedThemeAsync',
    'AccessibleName'
  )) {
    if (-not $savedThemesDialogSource.Contains($savedThemesUiContract)) {
      throw "Graphical manager saved-theme UI contract is missing: $savedThemesUiContract"
    }
  }
  foreach ($mainFormThemeContract in @('_themesButton', 'ShowSavedThemes')) {
    if (-not $managerFormSource.Contains($mainFormThemeContract)) {
      throw "Graphical manager does not expose saved themes from its main window: $mainFormThemeContract"
    }
  }
  foreach ($mainFormWallpaperEngineContract in @('_wallpaperEngineButton', 'ShowWallpaperEngine')) {
    if (-not $managerFormSource.Contains($mainFormWallpaperEngineContract)) {
      throw "Graphical manager does not expose locally downloaded Wallpaper Engine videos: $mainFormWallpaperEngineContract"
    }
  }
  $wallpaperEngineDialogPath = Join-Path $Root 'app\CodexDreamSkin.Manager\WallpaperEngineDialog.cs'
  if (-not (Test-Path -LiteralPath $wallpaperEngineDialogPath -PathType Leaf)) {
    throw 'Graphical manager Wallpaper Engine dialog is missing.'
  }
  $wallpaperEngineDialogSource = Read-DreamSkinUtf8File -Path $wallpaperEngineDialogPath
  foreach ($wallpaperEngineUiContract in @(
    'Wallpaper Engine', 'ListWallpaperEngineAsync', '导入到主页', 'SelectionMode.MultiExtended', 'ImportedItems', 'AccessibleName'
  )) {
    if (-not $wallpaperEngineDialogSource.Contains($wallpaperEngineUiContract)) {
      throw "Graphical manager Wallpaper Engine UI contract is missing: $wallpaperEngineUiContract"
    }
  }
  $managerModelSource = Read-DreamSkinUtf8File -Path (
    Join-Path $Root 'app\CodexDreamSkin.Manager\Models.cs'
  )
  foreach ($managerStatusContract in @(
    'Codex 已打开 · 壁纸未启动',
    'Codex 未打开 · 壁纸未启动',
    'CurrentWallpaperLabel'
  )) {
    if (-not $managerModelSource.Contains($managerStatusContract)) {
      throw "Graphical manager status contract is missing: $managerStatusContract"
    }
  }
  $managerServiceSource = Read-DreamSkinUtf8File -Path (
    Join-Path $Root 'app\CodexDreamSkin.Manager\DreamSkinService.cs'
  )
  foreach ($managerThemeContract in @(
    'ListSavedThemesAsync',
    'SaveCurrentThemeAsync',
    'ApplySavedThemeAsync',
    'ListWallpaperEngineAsync',
    'ApplyWallpaperEngineAsync',
    'ListThemes', 'ListWallpaperEngine', 'UseWallpaperEngine',
    'SaveTheme',
    'UseTheme'
  )) {
    if (-not $managerServiceSource.Contains($managerThemeContract)) {
      throw "Graphical manager saved-theme service contract is missing: $managerThemeContract"
    }
  }
  foreach ($restartContract in @(
    'ConfirmCodexRestart',
    'arguments.Add("-RestartExisting")',
    'arguments.Add("-ForceRestart")'
  )) {
    if (-not $managerServiceSource.Contains($restartContract)) {
      throw "Graphical manager restart confirmation contract is missing: $restartContract"
    }
  }
  if ($managerServiceSource.Contains('"-PromptRestart"')) {
    throw 'Graphical manager still delegates restart confirmation to a hidden PowerShell process.'
  }
  $powerShellRunnerSource = Read-DreamSkinUtf8File -Path (
    Join-Path $Root 'app\CodexDreamSkin.Manager\PowerShellRunner.cs'
  )
  if (-not $powerShellRunnerSource.Contains('process.Kill(entireProcessTree: true)')) {
    throw 'Graphical manager cancellation can still orphan a PowerShell process tree.'
  }
  $managerReferenceCatalogPath = Join-Path $Root 'app\CodexDreamSkin.Manager\WallpaperEngineReferenceCatalog.cs'
  if (-not (Test-Path -LiteralPath $managerReferenceCatalogPath -PathType Leaf)) {
    throw 'Graphical manager Wallpaper Engine reference catalog is missing.'
  }
  $managerReferenceCatalogSource = Read-DreamSkinUtf8File -Path $managerReferenceCatalogPath
  foreach ($referenceCatalogContract in @(
    'ResolveAndPrune', 'AddImports', 'steamapps', 'workshop', '431960'
  )) {
    if (-not $managerReferenceCatalogSource.Contains($referenceCatalogContract)) {
      throw "Wallpaper Engine reference catalog is missing: $referenceCatalogContract"
    }
  }
  foreach ($managerReferenceContract in @(
    'WallpaperEngineImports', 'WallpaperEngineReference', 'WallpaperSource', 'SourceLabel'
  )) {
    if (-not $managerModelSource.Contains($managerReferenceContract)) {
      throw "Graphical manager Wallpaper Engine persistence model is missing: $managerReferenceContract"
    }
  }
  foreach ($mainFormReferenceContract in @(
    'ShowWallpaperEngineAsync', 'AddImports', 'ResolveAndPrune', 'WallpaperSource.WallpaperEngine'
  )) {
    if (-not $managerFormSource.Contains($mainFormReferenceContract)) {
      throw "Graphical manager does not persist or refresh Wallpaper Engine references: $mainFormReferenceContract"
    }
  }

  $traySource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\tray-dream-skin.ps1')
  foreach ($requiredTrayAction in @('System.Windows.Forms.NotifyIcon', 'System.Windows.Forms.TrackBar', '壁纸透出', '暂停皮肤', '更换背景图或视频', '*.mp4;*.webm', '已保存主题', '完全恢复 Codex')) {
    if (-not $traySource.Contains($requiredTrayAction)) { throw "Tray action is missing: $requiredTrayAction" }
  }
  if (-not $traySource.Contains('[AllowEmptyCollection()][System.Windows.Forms.ToolStripItemCollection]$Items')) {
    throw 'Tray menu helper does not accept a newly opened empty menu collection.'
  }
  if (-not $traySource.Contains('$nextPaused') -or -not $traySource.Contains('[System.Windows.Forms.Application]::Exit()')) {
    throw 'Tray pause/restore closures do not terminate cleanly.'
  }
  if (-not $traySource.Contains('Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata') -or
    -not $traySource.Contains('Get-DreamSkinSavedThemes -StateRoot $StateRoot -SkipImageMetadata')) {
    throw 'Tray menu metadata enumeration still performs full image parsing on every open.'
  }
  $restoreSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\restore-dream-skin.ps1')
  if (-not $restoreSource.Contains('Stop-DreamSkinTrayProcess')) {
    throw 'Complete restore does not stop a separately launched tray process.'
  }
  if ($restoreSource.Contains('Start-Process -FilePath $relaunchCodex.Executable') -or
    -not $restoreSource.Contains('Start-DreamSkinCodex -Codex $relaunchCodex')) {
    throw 'Restore still executes the WindowsApps path instead of activating the registered package.'
  }
  $startSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\start-dream-skin.ps1')
  if ($startSource.Contains('Start-Process -FilePath $codex.Executable') -or
    -not $startSource.Contains('Start-DreamSkinCodex -Codex $codex')) {
    throw 'Start still executes the WindowsApps path instead of activating the registered package.'
  }
  $stateReadIndex = $startSource.IndexOf('$previousState = Read-DreamSkinState', [System.StringComparison]::Ordinal)
  $restartPromptIndex = $startSource.IndexOf('$restartAuthorized = Confirm-DreamSkinRestart', [System.StringComparison]::Ordinal)
  $recordedStopIndex = $startSource.IndexOf('$recordedInjectorStopped = Stop-DreamSkinRecordedInjector', [System.StringComparison]::Ordinal)
  $cancelIndex = $startSource.IndexOf("Write-Host 'Codex 动态壁纸启动已取消", [System.StringComparison]::Ordinal)
  $pauseClearIndex = $startSource.IndexOf('Set-DreamSkinPaused -Paused $false', [System.StringComparison]::Ordinal)
  if ($stateReadIndex -lt 0 -or $pauseClearIndex -le $stateReadIndex -or
    ($restartPromptIndex -ge 0 -and $pauseClearIndex -le $restartPromptIndex) -or
    ($recordedStopIndex -ge 0 -and $pauseClearIndex -le $recordedStopIndex) -or
    ($cancelIndex -ge 0 -and $cancelIndex -ge $pauseClearIndex)) {
    throw 'Start clears the pause marker before state validation or restart consent, or before its cancellation branch.'
  }
  if (-not $startSource.Contains('$pauseWasSet = Test-DreamSkinPaused') -or
    -not $startSource.Contains('$pauseCleared = $true') -or
    -not $startSource.Contains('Set-DreamSkinPaused -Paused $true -StateRoot $StateRoot')) {
    throw 'Start does not preserve an existing pause marker when startup rolls back.'
  }

  $rendererSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'assets\renderer-inject.js')
  foreach ($requiredRendererBehavior in @('dream-home-utility', 'artMetadata', 'detectShellAppearance')) {
    if (-not $rendererSource.Contains($requiredRendererBehavior)) {
      throw "Renderer adaptive behavior is missing: $requiredRendererBehavior"
    }
  }
  $injectorSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\injector.mjs')
  if (-not $injectorSource.Contains('Page.setBypassCSP') -or
    -not $injectorSource.Contains('setStreamCspBypass(session, false)')) {
    throw 'Scene streaming does not scope and revoke its Codex CSP bypass.'
  }
  foreach ($requiredInjectorBehavior in @(
    'MAX_ART_BYTES', 'createHash', 'readImageMetadata', '50MP safety limit', 'STRONG_THEME_AUDIT_MS',
    'Page.addScriptToEvaluateOnNewDocument', 'Page.removeScriptToEvaluateOnNewDocument', 'earlyPayloadFor'
  )) {
    if (-not $injectorSource.Contains($requiredInjectorBehavior)) {
      throw "Injector theme safety is missing: $requiredInjectorBehavior"
    }
  }
  $themeSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\theme-windows.ps1')
  foreach ($requiredThemeSafety in @(
    '[System.IO.FileAttributes]::ReparsePoint',
    'Ensure-DreamSkinManagedDirectory',
    'Get-DreamSkinValidatedImageMetadata',
    '16384px / 50MP safety limit',
    'Assert-DreamSkinVideoFile',
    'Video container signature does not match',
    'Assert-DreamSkinMediaFile -Path $temporary',
    'Assert-DreamSkinMediaFile -Path $imageArchive'
  )) {
    if (-not $themeSource.Contains($requiredThemeSafety)) {
      throw "PowerShell theme-store safety is missing: $requiredThemeSafety"
    }
  }
  $commonSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\common-windows.ps1')
  if (-not $commonSource.Contains('State was preserved.')) {
    throw 'Mismatched live injector identity does not fail closed with preserved state.'
  }

  $node = Get-DreamSkinNodeRuntime
  $stderrProbe = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    '-e', "process.stderr.write('dream-skin-stderr-probe\n'); process.exit(7)")
  if ($stderrProbe.ExitCode -ne 7 -or ($stderrProbe.Output -join "`n") -notmatch 'dream-skin-stderr-probe') {
    throw "Native stderr was not captured with its real exit code under Stop preference: exit=$($stderrProbe.ExitCode); output=$($stderrProbe.Output -join '<NL>')"
  }
  $discardedProbe = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    '-e', "process.stderr.write('ignored-warning\n'); process.stdout.write('kept-output')") -DiscardStderr
  if ($discardedProbe.ExitCode -ne 0 -or ($discardedProbe.Output -join '') -cne 'kept-output') {
    throw 'Native stderr discard changed stdout or the real exit code.'
  }

  $selfTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $Root 'scripts\injector.mjs'), '--self-test')
  if ($selfTest.ExitCode -ne 0) { throw 'Injector CDP self-test failed.' }
  $payloadTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $Root 'scripts\injector.mjs'), '--check-payload')
  if ($payloadTest.ExitCode -ne 0) { throw 'Injector self-test failed.' }
  $managedPayloadTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $Root 'scripts\injector.mjs'), '--check-payload', '--theme-dir', $themePaths.Active)
  if ($managedPayloadTest.ExitCode -ne 0) { throw 'Managed theme payload validation failed.' }
  $oversizedPayloadTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $Root 'scripts\injector.mjs'), '--check-payload', '--theme-dir', $oversizedTheme)
  if ($oversizedPayloadTest.ExitCode -eq 0) { throw 'Node injector accepted an image over the 16 MB limit.' }
  $rendererTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $PSScriptRoot 'renderer-inject.test.mjs'))
  if ($rendererTest.ExitCode -ne 0) { throw 'Renderer auxiliary-window regression test failed.' }
  $dynamicMediaTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $PSScriptRoot 'dynamic-media.test.mjs'))
  if ($dynamicMediaTest.ExitCode -ne 0) { throw 'Dynamic media transfer regression test failed.' }
  $bootstrapTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $PSScriptRoot 'injector-bootstrap.test.mjs'))
  if ($bootstrapTest.ExitCode -ne 0) { throw 'Injector early-bootstrap regression test failed.' }
  $oneShotTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $PSScriptRoot 'injector-one-shot.test.mjs'))
  if ($oneShotTest.ExitCode -ne 0) { throw 'Injector one-shot Browser ID regression test failed.' }
  $imageMetadataTest = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
    (Join-Path $PSScriptRoot 'image-metadata.test.mjs'))
  if ($imageMetadataTest.ExitCode -ne 0) { throw 'Image metadata regression test failed.' }

  Write-Host 'PASS: config transactions, restore scoping, state safety, argument quoting, and loopback CDP validation.'
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
