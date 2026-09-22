# Run only on an ephemeral GitHub Windows runner. Never run on a user's machine.
param([Parameter(Mandatory = $true)][string]$Installer)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') {
  throw 'The installation smoke test is restricted to an ephemeral Windows Actions runner.'
}
$Installer = (Resolve-Path $Installer).Path
$UpgradeCode = '{1482A8E8-9217-517B-8528-93A6C90E0C2F}'
$LegacyProductCode = '{F71E3F3F-A463-4397-AB46-206D3FAC3FBD}'
$LegacySha256 = 'e0f2f172a31f860806a9714bab2e67eb38b85d525d7e5f0f569667cbeadfb152'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Codex-X'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex-X'
$Work = Join-Path $env:RUNNER_TEMP 'codex-x-installer-smoke'
New-Item -ItemType Directory -Force $Work | Out-Null
Add-Type @'
using System.Runtime.InteropServices;
using System.Text;
public static class CodexXMsiSmoke {
  [DllImport("msi.dll", CharSet = CharSet.Unicode)]
  public static extern uint MsiEnumRelatedProducts(string code, uint reserved, uint index, StringBuilder product);
}
'@
function Related-Products {
  $results = @()
  for ($index = 0; $index -lt 64; $index++) {
    $product = [Text.StringBuilder]::new(39)
    $result = [CodexXMsiSmoke]::MsiEnumRelatedProducts($UpgradeCode, 0, $index, $product)
    if ($result -eq 259) { return $results }
    if ($result -ne 0) { throw "MsiEnumRelatedProducts failed: $result" }
    $results += $product.ToString()
  }
  throw 'Unexpected number of MSI registrations.'
}
function Invoke-Installer([string]$File, [string]$Arguments, [int]$ExpectedExit = 0) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $process = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru
  if (-not $process.WaitForExit(600000)) {
    # Do not kill msiexec or an installer transaction. Fail the disposable job.
    throw "Installer has not finished after ten minutes (PID $($process.Id)); no forced termination was attempted."
  }
  $process.Refresh()
  if ($process.ExitCode -ne $ExpectedExit) { throw "Installer returned $($process.ExitCode), expected $ExpectedExit" }
  Write-Host "Installer completed in $([math]::Round($watch.Elapsed.TotalSeconds, 1)) seconds."
}
function Assert-Installed {
  if (-not (Test-Path (Join-Path $InstallDir 'codex-x.exe'))) { throw 'EXE not installed in original user LOCALAPPDATA.' }
  $registration = Get-ItemProperty $UninstallKey
  if ($registration.MainBinaryName -ne 'codex-x.exe') { throw 'Invalid NSIS registration.' }
  if (@(Related-Products).Count -ne 0) { throw 'Legacy MSI is still registered.' }
  foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
    $found = @(Get-ChildItem $root -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.DisplayName -eq 'Codex-X' })
    if ($root.StartsWith('HKCU:')) {
      if ($found.Count -ne 1) { throw 'Expected exactly one current-user uninstall entry.' }
    } elseif ($found.Count -ne 0) { throw 'A machine-wide Codex-X uninstall entry remains.' }
  }
  foreach ($entry in $Sentinels.GetEnumerator()) {
    if (-not (Test-Path $entry.Key) -or (Get-FileHash $entry.Key -Algorithm SHA256).Hash -ne $entry.Value) {
      throw "User configuration changed during installation: $($entry.Key)"
    }
  }
}
function Remove-TestNsis {
  # _?= avoids NSIS's detached temporary uninstaller process so WaitForExit
  # actually covers registry/files removal. This is NSIS's documented syntax.
  $uninstaller = Join-Path $InstallDir 'uninstall.exe'
  if (Test-Path $uninstaller) { Invoke-Installer $uninstaller "/S _?=$InstallDir" }
  if (Test-Path $UninstallKey) { throw 'NSIS uninstall registration was not removed.' }
}
if ((Test-Path $UninstallKey) -or @(Related-Products).Count -ne 0) { throw 'Runner already has a Codex-X installation.' }
$Sentinels = @{}
foreach ($relative in @('.codex\config.toml', '.codex\auth.json', '.codexx\installer-smoke-data.txt')) {
  $file = Join-Path $env:USERPROFILE $relative
  if (Test-Path $file) { throw "Refusing to overwrite an existing file: $file" }
  New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
  [IO.File]::WriteAllText($file, "Codex-X installer sentinel: $relative")
  $Sentinels[$file] = (Get-FileHash $file -Algorithm SHA256).Hash
}
try {
  Write-Host 'Scenario 1: clean current-user install and subsequent NSIS update.'
  Invoke-Installer $Installer '/S'
  Assert-Installed
  Invoke-Installer $Installer '/S /UPDATE'
  Assert-Installed
  # A 3010/incomplete migration barrier must survive immediate retries. Once
  # the boot identity differs, it must be cleared and allow the install.
  $pendingKey = 'HKCU:\Software\yynxxxxx\Codex-X\Installer'
  New-Item -Force $pendingKey | Out-Null
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc().ToString()
  Set-ItemProperty $pendingKey PendingBoot $boot
  Invoke-Installer $Installer '/S /UPDATE' 1
  Assert-Installed
  Set-ItemProperty $pendingKey PendingBoot 'previous-boot-smoke-fixture'
  Invoke-Installer $Installer '/S /UPDATE'
  if ((Get-ItemProperty $pendingKey -ErrorAction SilentlyContinue).PendingBoot) { throw 'Previous-boot marker was not cleared.' }
  Assert-Installed
  Remove-TestNsis

  Write-Host 'Scenario 2: released v0.3.20 machine MSI -> current-user NSIS -> NSIS update.'
  $legacyMsi = Join-Path $Work 'Codex-X-0.3.20.msi'
  Invoke-WebRequest 'https://github.com/yynxxxxx/Codex-X/releases/download/v0.3.20/Codex-X-0.3.20-windows-x64.msi' -OutFile $legacyMsi
  if ((Get-FileHash $legacyMsi -Algorithm SHA256).Hash.ToLowerInvariant() -ne $LegacySha256) { throw 'Released MSI hash mismatch.' }
  Invoke-Installer (Join-Path $env:SystemRoot 'System32\msiexec.exe') "/i `"$legacyMsi`" /qn /norestart /L*v `"$Work\legacy-install.log`""
  if ($LegacyProductCode -notin @(Related-Products)) { throw 'The genuine legacy MSI did not register.' }
  # Deliberately keep the real MSI's HKCU manufacturer path to verify that the
  # NSIS installer does not inherit a legacy Program Files directory.
  Invoke-Installer $Installer '/S /UPDATE'
  Assert-Installed
  Invoke-Installer $Installer '/S /UPDATE'
  Assert-Installed
  Write-Host 'Windows installation smoke tests passed; configuration sentinels unchanged.'
} finally {
  Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Codex-X-updates\logs') -Filter 'install-*.log' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "--- $($_.Name) ---"
    Get-Content $_.FullName -Tail 100
  }
  Remove-TestNsis
}
