param(
  [string]$InstallDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AI Video Restore'),
  [string]$DesktopDir = [Environment]::GetFolderPath('Desktop')
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
$shortcutPath = Join-Path $DesktopDir 'AI 视频高清修复.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $launcher + '"'
$shortcut.WorkingDirectory = $InstallDir
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,220"
$shortcut.Description = '启动 AI 视频高清修复并检查更新'
$shortcut.Save()
if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { throw "快捷方式保存失败：$shortcutPath" }
Write-Host "桌面快捷方式已创建：$shortcutPath" -ForegroundColor Green
Write-Host '回到桌面按 F5 刷新，然后双击“AI 视频高清修复”。'
