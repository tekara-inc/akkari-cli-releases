# Akkari CLI installer for Windows. Everything runs inside Install-Akkari so a truncated download executes nothing.
# Usage: irm https://app.akkari.io/install.ps1 | iex
# Environment: AKKARI_INSTALL_VERSION (default latest), AKKARI_CONFIG_DIR (parent of the akkari home),
#              AKKARI_RELEASES_BASE_URL (default GitHub releases), AKKARI_NO_MODIFY_PATH (leave the user PATH alone).

function Install-Akkari {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  # Windows PowerShell 5.1 defaults to TLS 1.0, which GitHub refuses.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $base = if ($env:AKKARI_RELEASES_BASE_URL) { $env:AKKARI_RELEASES_BASE_URL.TrimEnd('/') } else { 'https://github.com/tekara-inc/akkari-cli-releases/releases' }
  $akkariHome = if ($env:AKKARI_CONFIG_DIR) { Join-Path $env:AKKARI_CONFIG_DIR 'akkari' } else { Join-Path $env:USERPROFILE '.config\akkari' }
  # Windows 11 on Arm runs the x64 build under emulation.
  if ($env:PROCESSOR_ARCHITECTURE -notin @('AMD64', 'ARM64') -and $env:PROCESSOR_ARCHITEW6432 -notin @('AMD64', 'ARM64')) {
    Fail "unsupported architecture: $env:PROCESSOR_ARCHITECTURE"
  }
  $platform = 'win32-x64'
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (-not (Test-Path $tar)) { Fail 'tar.exe is missing; Windows 10 1803 or later is required' }

  $work = Join-Path ([IO.Path]::GetTempPath()) ("akkari-install." + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    if ($env:AKKARI_INSTALL_VERSION) { $version = $env:AKKARI_INSTALL_VERSION }
    else {
      # A unique query skips GitHub's cached /latest/download right after a release.
      $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
      Fetch "$base/latest/download/manifest.json?t=$stamp" (Join-Path $work 'manifest.json')
      $version = (Get-Content -Raw (Join-Path $work 'manifest.json') | ConvertFrom-Json).version
      if (-not $version) { Fail 'could not determine the latest version' }
    }
    $release = "$base/download/v$version"
    $name = "akkari-$version-$platform"
    Write-Host "Installing akkari $version for $platform"
    Fetch "$release/SHA256SUMS" (Join-Path $work 'SHA256SUMS')
    $tarball = Join-Path $work "$name.tar.gz"
    Fetch "$release/$name.tar.gz" $tarball
    $line = Get-Content (Join-Path $work 'SHA256SUMS') | Where-Object { $_ -match "^([a-f0-9]{64})  $([regex]::Escape("$name.tar.gz"))$" } | Select-Object -First 1
    if (-not $line) { Fail "SHA256SUMS has no entry for $name.tar.gz" }
    $expected = $line.Substring(0, 64)
    # Not Get-FileHash: Windows PowerShell 5.1 defines it in a script module, which goes missing when an
    # inherited PSModulePath points at PowerShell 7's modules (Git Bash started from pwsh, as under Claude Code).
    $stream = [IO.File]::OpenRead($tarball)
    try { $actual = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
    finally { $stream.Dispose() }
    if ($actual -ne $expected) { Fail "checksum mismatch for $name.tar.gz" }

    $cli = Join-Path $akkariHome 'cli'
    $versions = Join-Path $cli 'versions'
    New-Item -ItemType Directory -Force -Path $versions | Out-Null
    $target = Join-Path $versions $version
    $partial = "$target.partial"
    if (Test-Path $partial) { Remove-Item -Recurse -Force $partial }
    New-Item -ItemType Directory -Path $partial | Out-Null
    & $tar -xzf $tarball -C $partial --strip-components 1
    if ($LASTEXITCODE -ne 0) { Fail "could not extract $name.tar.gz" }
    if (-not (Test-Path (Join-Path $partial 'akkari.exe'))) { Fail "$name.tar.gz has no akkari.exe" }
    if (Test-Path $target) {
      try { Remove-Item -Recurse -Force $target }
      catch { Fail "akkari $version is running from $target; run 'akkari tracker stop', close other akkari windows, and retry" }
    }
    Move-Item $partial $target

    # Symlinks need Developer Mode; a junction is the unprivileged directory link. Deleting the junction
    # non-recursively removes only the link, never the version it points at.
    $current = Join-Path $cli 'current'
    if (Test-Path $current) { [IO.Directory]::Delete($current, $false) }
    New-Item -ItemType Junction -Path $current -Target $target | Out-Null
    Write-Receipt $cli $version $platform $actual

    $binary = Join-Path $current 'akkari.exe'
    & $binary update --verify-install *> $null
    if ($LASTEXITCODE -ne 0) { Fail "the installed release failed signature verification; remove $cli and retry" }
    Add-ToPath $current
    Write-Host ''
    Write-Host "akkari $version installed to $binary"
    Write-Host 'Next:'
    Write-Host '  akkari auth login'
    Write-Host '  akkari setup --apply'
  } finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
  }
}

function Fetch($url, $out) {
  try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out -MaximumRedirection 10 }
  catch { Fail "download failed: $url" }
}

function Write-Receipt($cli, $version, $platform, $sha256) {
  $receipt = [ordered]@{
    schema = 1; version = $version; installed_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    method = 'install-script'; source = 'github:tekara-inc/akkari-cli-releases'; platform = $platform; tarball_sha256 = $sha256
  }
  $tmp = Join-Path $cli 'install-receipt.json.tmp'
  # WriteAllText writes UTF-8 without a byte-order mark, which JSON.parse rejects.
  [IO.File]::WriteAllText($tmp, (($receipt | ConvertTo-Json) + "`n"))
  Move-Item -Force $tmp (Join-Path $cli 'install-receipt.json')
}

function Add-ToPath($directory) {
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @($userPath -split ';' | Where-Object { $_ })
  if ($entries -contains $directory) { return }
  if ($env:AKKARI_NO_MODIFY_PATH) {
    Write-Host "Add $directory to your PATH, then open a new terminal."
    return
  }
  [Environment]::SetEnvironmentVariable('Path', (@($directory) + $entries) -join ';', 'User')
  $env:Path = "$directory;$env:Path"
  Write-Host "Added $directory to your user PATH; open a new terminal for other windows to see it."
}

function Fail($message) { throw "akkari install: $message" }

Install-Akkari
