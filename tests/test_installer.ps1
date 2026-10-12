param([string]$SourceUrl = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$entry = Join-Path $root 'install.ps1'
$bytes = [IO.File]::ReadAllBytes($entry)
if (@($bytes | Where-Object { $_ -gt 127 }).Count) { throw 'Bootstrap must remain ASCII without a BOM.' }
$script:entryText = if ($SourceUrl) {
  Invoke-RestMethod -UseBasicParsing -Uri $SourceUrl
} else {
  [IO.File]::ReadAllText($entry)
}
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($script:entryText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install-windows.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# Exercise the actual iex entry and a real Windows PowerShell child process.
# Replace only the installer download with a fixture so tests do not deploy GBs
# of models or change the user's desktop. The fixture itself carries a BOM.
$script:testDir = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-installer-test-' + [Guid]::NewGuid().ToString('N'))
$script:fixture = Join-Path $script:testDir 'fixture.ps1'
$env:AI_VIDEO_INSTALL_TEST_RESULT = Join-Path $script:testDir 'result.json'
$oldTestExit = $env:AI_VIDEO_INSTALL_TEST_EXIT
New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null
$fixtureText = @'
param([string]$InstallDir, [string]$DesktopDir, [string]$Repository, [string]$Branch, [switch]$NoOpen)
$ErrorActionPreference = 'Stop'
@{
  InstallDir=$InstallDir; DesktopDir=$DesktopDir; Repository=$Repository;
  Branch=$Branch; NoOpen=[bool]$NoOpen; Policy=[string](Get-ExecutionPolicy -Scope Process)
} | ConvertTo-Json | Set-Content -LiteralPath $env:AI_VIDEO_INSTALL_TEST_RESULT -Encoding UTF8
exit ([int]$env:AI_VIDEO_INSTALL_TEST_EXIT)
'@
try {
  [IO.File]::WriteAllText($script:fixture, $fixtureText, (New-Object Text.UTF8Encoding($true)))
  function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [int]$TimeoutSec, [string]$Uri, [string]$OutFile)
    if ($Uri -notmatch '/install-windows\.ps1\?t=\d+$') { throw "Unexpected installer URL: $Uri" }
    Copy-Item -LiteralPath $script:fixture -Destination $OutFile
    $script:downloadedInstaller = $OutFile
  }
  $env:AI_VIDEO_INSTALL_TEST_EXIT = '0'
  $script:entryText | Invoke-Expression
  $result = Get-Content -LiteralPath $env:AI_VIDEO_INSTALL_TEST_RESULT -Raw | ConvertFrom-Json
  if ($result.Policy -ne 'Bypass') { throw 'Child execution policy was not scoped to Bypass.' }
  if ($result.InstallDir -ne (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AI Video Restore')) { throw 'Default install path changed.' }
  if (Test-Path -LiteralPath $script:downloadedInstaller) { throw 'Bootstrap left its temporary download behind.' }
  Write-Host 'PASS: irm text -> iex -> BOM file -> child PowerShell'

  $customPath = Join-Path $script:testDir ('space ' + [char]0x6D4B + [char]0x8BD5)
  & ([ScriptBlock]::Create($script:entryText)) -InstallDir $customPath -DesktopDir $customPath -NoOpen
  $result = Get-Content -LiteralPath $env:AI_VIDEO_INSTALL_TEST_RESULT -Raw | ConvertFrom-Json
  if ($result.InstallDir -ne $customPath -or $result.DesktopDir -ne $customPath -or -not $result.NoOpen) { throw 'Installer arguments were not forwarded intact.' }
  Write-Host 'PASS: spaces, Unicode paths and NoOpen arguments'

  $env:AI_VIDEO_INSTALL_TEST_EXIT = '17'
  $failed = $false
  try { $script:entryText | Invoke-Expression }
  catch {
    if ($_.Exception.Message -notmatch 'exit code 17') { throw }
    $failed = $true
  }
  if (-not $failed) { throw 'Child installation failure was swallowed.' }
  if (Test-Path -LiteralPath $script:downloadedInstaller) { throw 'Failed bootstrap left its download behind.' }
  Write-Host 'PASS: nonzero installer exit propagates and cleans up'
}
finally {
  Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
  $env:AI_VIDEO_INSTALL_TEST_EXIT = $oldTestExit
  Remove-Item Env:\AI_VIDEO_INSTALL_TEST_RESULT -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $script:testDir -Recurse -Force
}
