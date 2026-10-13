param(
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AI Video Restore'),
  [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
  [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $InstallDir 'start-windows.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
  throw "未找到已安装的工具：$InstallDir。请先完成安装；如果装在其他目录，请用 -InstallDir 指定实际目录。"
}
if (-not (Test-Path -LiteralPath (Join-Path $InstallDir '.venv\Scripts\python.exe') -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $InstallDir '.runtime\runtime-version.txt') -PathType Leaf)) {
  throw '安装尚未完成。请先查看原安装窗口：仍在下载时请等待，出现红色报错时请先修复安装。快捷方式会在环境部署完成后生成。'
}
if ([string]::IsNullOrWhiteSpace($DesktopDir)) { throw '无法定位 Windows 桌面目录，请用 -DesktopDir 指定实际桌面。' }
New-Item -ItemType Directory -Path $DesktopDir -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
$names = @('AI 视频高清修复.lnk', 'AI Video Restore.lnk')
# Reuse an existing ASCII fallback instead of creating a second desktop icon.
if (Test-Path -LiteralPath (Join-Path $DesktopDir $names[1])) { $names = @($names[1]) }
$failures = @()
foreach ($name in $names) {
  $shortcutPath = Join-Path $DesktopDir $name
  try {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
    $shortcut.Description = 'AI Video Restore'
    $shortcut.Save()
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { throw "未生成文件：$shortcutPath" }
    Write-Host "桌面快捷方式已创建：$shortcutPath" -ForegroundColor Green
    Write-Host "回到桌面按 F5 刷新，然后双击“$([IO.Path]::GetFileNameWithoutExtension($name))”。"
    if ($PassThru) { Write-Output $shortcutPath }
    return
  } catch {
    $failures += $_.Exception.Message
    if ($name -ne $names[-1]) { Write-Warning '中文快捷方式保存失败，正在尝试英文名称 AI Video Restore。' }
  }
}
throw "AI 环境保留，但无法保存桌面快捷方式。请检查桌面目录写入权限：$DesktopDir。详细错误：$($failures -join ' / ')"
