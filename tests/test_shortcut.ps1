param([string]$BootstrapUrl = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-shortcut-test-' + [Guid]::NewGuid().ToString('N'))
$install = Join-Path $tempRoot ('Install ' + [char]0x6D4B + [char]0x8BD5)
$desktop = Join-Path $tempRoot 'Redirected Desktop'
$repair = Join-Path $root 'repair-shortcut-windows.ps1'
New-Item -ItemType Directory -Path $install -Force | Out-Null
try {
  $failed = $false
  try { & $repair -InstallDir $install -DesktopDir $desktop } catch { $failed = $true }
  if (-not $failed -or (Test-Path -LiteralPath $desktop)) { throw 'Missing installation must not produce a shortcut.' }
  New-Item -ItemType File -Path (Join-Path $install 'start-windows.ps1') | Out-Null
  $failed = $false
  try { & $repair -InstallDir $install -DesktopDir $desktop } catch { $failed = $true }
  if (-not $failed -or (Test-Path -LiteralPath $desktop)) { throw 'Incomplete installation must not produce a shortcut.' }
  Write-Host 'PASS: missing and incomplete installations are reported before writing a shortcut'

  # Installation markers are fixtures. Only test creation/reading of a real
  # Windows .lnk; never launch it or alter the actual user desktop.
  New-Item -ItemType Directory -Path (Join-Path $install '.venv\Scripts'), (Join-Path $install '.runtime') -Force | Out-Null
  New-Item -ItemType File -Path (Join-Path $install '.venv\Scripts\python.exe'), (Join-Path $install '.runtime\runtime-version.txt') | Out-Null
  if ($BootstrapUrl) {
    $entry = Invoke-RestMethod -UseBasicParsing -Uri $BootstrapUrl
    & ([ScriptBlock]::Create($entry)) -InstallDir $install -DesktopDir $desktop
  } else {
    & $repair -InstallDir $install -DesktopDir $desktop
  }
  $links = @(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk')
  if ($links.Count -ne 1) { throw 'Expected exactly one desktop shortcut.' }
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($links[0].FullName)
  $expectedTarget = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $expectedArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $install 'start-windows.ps1') + '"'
  if ($link.TargetPath -ne $expectedTarget -or $link.Arguments -ne $expectedArgs -or $link.WorkingDirectory -ne $install) { throw 'Shortcut launch properties are incorrect.' }
  & $repair -InstallDir $install -DesktopDir $desktop
  if (@(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk').Count -ne 1) { throw 'Repair should update, not duplicate, the shortcut.' }
  Write-Host 'PASS: real Windows shortcut, redirected desktop, Unicode/space paths and repeated repair'

  # Inject failure only for the Chinese filename; the fallback must be a real
  # usable .lnk, and its actual path must reach the installer caller.
  $fallbackDesktop = Join-Path $tempRoot 'Fallback Desktop'
  $script:realShortcutShell = New-Object -ComObject WScript.Shell
  $script:fakeShortcutShell = [PSCustomObject]@{RealShell=$script:realShortcutShell}
  $script:fakeShortcutShell | Add-Member ScriptMethod CreateShortcut {
    param($path)
    if ([IO.Path]::GetFileName($path) -ne 'AI Video Restore.lnk') { throw 'EXPECTED_UNICODE_SHORTCUT_FAILURE' }
    return $this.RealShell.CreateShortcut($path)
  }
  function New-Object { param([string]$ComObject); return $fakeShortcutShell }
  try {
    $created = & $repair -InstallDir $install -DesktopDir $fallbackDesktop -PassThru
  } finally { Remove-Item Function:\New-Object }
  $expected = Join-Path $fallbackDesktop 'AI Video Restore.lnk'
  if ($created -ne $expected -or -not (Test-Path -LiteralPath $created)) { throw 'ASCII fallback path was not returned.' }
  $fallbackLink = $script:realShortcutShell.CreateShortcut($created)
  if ($fallbackLink.Arguments -ne $expectedArgs) { throw 'Fallback shortcut does not launch the same hidden worker.' }
  $again = & $repair -InstallDir $install -DesktopDir $fallbackDesktop -PassThru
  if ($again -ne $expected -or @(Get-ChildItem -LiteralPath $fallbackDesktop -Filter '*.lnk').Count -ne 1) { throw 'Fallback repair created duplicate icons.' }
  Write-Host 'PASS: Unicode-failure injection creates a real ASCII fallback and repeated repair reuses it'
}
finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
