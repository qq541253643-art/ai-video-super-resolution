# Shared by setup, desktop launch and the five-second CLI test.
function Get-VerifiedDownload([string]$Uri, [string]$Destination, [string]$Sha256 = '') {
  New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
  if ((Test-Path -LiteralPath $Destination) -and $Sha256 -and
      (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash -eq $Sha256) { return }
  $partial = "$Destination.download"
  if ($Sha256 -and (Test-Path -LiteralPath $partial) -and
      (Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash -eq $Sha256) {
    Move-Item -LiteralPath $partial -Destination $Destination -Force
    return
  }
  $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Write-Host "Download ($attempt/3): $Uri"
      if ($curl) {
        & $curl.Source --fail --location --connect-timeout 30 --speed-time 120 --speed-limit 1024 --continue-at - --output $partial $Uri
        $downloadExit = $LASTEXITCODE
        if ($downloadExit -ne 0) {
          # A source that does not support ranges must restart, not append a full response.
          if ($downloadExit -in @(33, 36) -and (Test-Path -LiteralPath $partial)) {
            Remove-Item -LiteralPath $partial -Force
          }
          throw "curl exit $downloadExit"
        }
      } else {
        # Older Windows without curl still gets retries, but cannot resume this request.
        $savedProgress = $ProgressPreference
        try {
          $ProgressPreference = 'SilentlyContinue'
          Invoke-WebRequest -UseBasicParsing -TimeoutSec 1800 -Uri $Uri -OutFile $partial
        } finally { $ProgressPreference = $savedProgress }
      }
      if (-not (Test-Path -LiteralPath $partial) -or (Get-Item -LiteralPath $partial).Length -eq 0) {
        throw 'Downloaded file is empty.'
      }
      if ($Sha256 -and (Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash -ne $Sha256) {
        Remove-Item -LiteralPath $partial -Force
        throw 'SHA-256 mismatch; refusing to install this file.'
      }
      Move-Item -LiteralPath $partial -Destination $Destination -Force
      return
    } catch {
      if ($attempt -eq 3) { throw "Download failed: $Uri. Cached progress: $partial. $($_.Exception.Message)" }
      Write-Warning "Download interrupted; retrying with saved progress. $($_.Exception.Message)"
      Start-Sleep -Seconds 2
    }
  }
}

function Add-RuntimePath([string]$RuntimeDir) {
  foreach ($folder in @((Join-Path $RuntimeDir 'uv'), (Join-Path $RuntimeDir 'ffmpeg\bin'))) {
    if ((Test-Path -LiteralPath $folder) -and ($env:Path -split ';') -notcontains $folder) {
      $env:Path = "$folder;$env:Path"
    }
  }
}

function Install-PortableZip([string]$Uri, [string]$Destination, [string]$Sha256) {
  $temporary = Join-Path ([IO.Path]::GetTempPath()) ('ai-video-tools-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $temporary -Force | Out-Null
  $savedProgress = $ProgressPreference
  try {
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $zip = "$Destination.zip"
    Get-VerifiedDownload $Uri $zip $Sha256
    $expanded = Join-Path $temporary 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded
    $items = @(Get-ChildItem -LiteralPath $expanded)
    $source = if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $items[0].FullName } else { $expanded }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $Destination -Recurse -Force
  }
  finally {
    $ProgressPreference = $savedProgress
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
  }
}

function Ensure-BasicTools([string]$RuntimeDir) {
  Add-RuntimePath $RuntimeDir
  if (-not (Get-Command uv.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host 'Downloading portable uv (no winget required)...' -ForegroundColor Green
    Install-PortableZip `
      'https://github.com/astral-sh/uv/releases/download/0.13.0/uv-x86_64-pc-windows-msvc.zip' `
      (Join-Path $RuntimeDir 'uv') `
      '088962F9E7B7BD9EA740C04C650B2A21C8928C345BD99AC24350DC924DBA656C'
    Add-RuntimePath $RuntimeDir
  }
  if (-not (Get-Command ffmpeg.exe -CommandType Application -ErrorAction SilentlyContinue) -or
      -not (Get-Command ffprobe.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host 'Downloading portable FFmpeg + FFprobe (no winget required)...' -ForegroundColor Green
    Install-PortableZip `
      'https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip' `
      (Join-Path $RuntimeDir 'ffmpeg') `
      '60F467265B1E312373DBCD92200C2618A74850F98D3D078E94296BB3FA2047BA'
    Add-RuntimePath $RuntimeDir
  }
  foreach ($tool in @('uv.exe', 'ffmpeg.exe', 'ffprobe.exe')) {
    $command = Get-Command $tool -CommandType Application -ErrorAction Stop
    $argument = if ($tool -eq 'uv.exe') { '--version' } else { '-version' }
    $version = & $command.Source $argument
    if ($LASTEXITCODE -ne 0) { throw "$tool failed to start (exit $LASTEXITCODE)." }
    Write-Host ($version | Select-Object -First 1)
  }
}
