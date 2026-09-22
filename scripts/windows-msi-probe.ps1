# Diagnostic only; installs/removes the hash-pinned fixture on an ephemeral runner.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') {
  throw 'This MSI diagnostic is restricted to an ephemeral Windows Actions runner.'
}
$work = Join-Path $env:RUNNER_TEMP 'codex-x-msi-probe'
New-Item -ItemType Directory -Force $work | Out-Null
$legacyMsi = Join-Path $work 'legacy.msi'
Invoke-WebRequest 'https://github.com/yynxxxxx/Codex-X/releases/download/v0.3.20/Codex-X-0.3.20-windows-x64.msi' -OutFile $legacyMsi
if ((Get-FileHash $legacyMsi -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'e0f2f172a31f860806a9714bab2e67eb38b85d525d7e5f0f569667cbeadfb152') {
  throw 'MSI fixture hash mismatch.'
}
$compiler = (Get-Command makensis.exe -ErrorAction SilentlyContinue).Source
if (-not $compiler) { $compiler = Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe' }
if (-not (Test-Path $compiler)) { throw 'makensis.exe is required for the native MSI probe.' }
$psProbe = @'
$ErrorActionPreference = 'Stop'
Add-Type @"
using System.Runtime.InteropServices;
using System.Text;
public static class MsiProbeNative {
 [DllImport("msi.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
 public static extern uint MsiEnumRelatedProductsW(string upgrade, uint reserved, uint index, StringBuilder product);
 [DllImport("msi.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
 public static extern uint MsiGetProductInfoExW(string product, System.IntPtr sid, uint context, string property, StringBuilder value, ref uint length);
}
"@
$product = [Text.StringBuilder]::new(39)
$rc = [MsiProbeNative]::MsiEnumRelatedProductsW('{1482A8E8-9217-517B-8528-93A6C90E0C2F}', 0, 0, $product)
Write-Host "PS Is64Bit=$([Environment]::Is64BitProcess) EnumRelated rc=$rc product=$product"
foreach ($property in @('VersionString', 'InstallLocation')) {
 $value = [Text.StringBuilder]::new(1024)
 [uint32]$length = 1024
 $rc = [MsiProbeNative]::MsiGetProductInfoExW('{F71E3F3F-A463-4397-AB46-206D3FAC3FBD}', [IntPtr]::Zero, 4, $property, $value, [ref]$length)
 Write-Host "PS Is64Bit=$([Environment]::Is64BitProcess) machine $property rc=$rc value=$value"
}
'@
$psProbePath = Join-Path $work 'probe-api.ps1'
Set-Content $psProbePath $psProbe -Encoding utf8
$nsis = @'
Unicode true
RequestExecutionLevel user
OutFile "probe.exe"
Name "Codex-X MSI API probe"
SilentInstall silent
Function .onInit
 FileOpen $9 "$EXEDIR\nsis-probe.log" w
 FileWriteUTF16LE /BOM $9 "NSIS x86 Unicode native MSI API probe$\r$\n"
 System::Call 'msi::MsiEnumRelatedProductsW(w "{1482A8E8-9217-517B-8528-93A6C90E0C2F}",i 0,i 0,w .r0)i.r1'
 FileWriteUTF16LE $9 "EnumRelatedW result=$1 product=$0$\r$\n"
 System::Call 'msi::MsiEnumRelatedProductsA(m "{1482A8E8-9217-517B-8528-93A6C90E0C2F}",i 0,i 0,m .r0)i.r1'
 FileWriteUTF16LE $9 "EnumRelatedA result=$1 product=$0$\r$\n"
 System::Call 'msi::MsiGetProductInfoExW(w "{F71E3F3F-A463-4397-AB46-206D3FAC3FBD}",p 0,i 4,w "VersionString",w .r0,*i 1024)i.r1'
 FileWriteUTF16LE $9 "Machine VersionString result=$1 value=$0$\r$\n"
 System::Call 'msi::MsiGetProductInfoExW(w "{F71E3F3F-A463-4397-AB46-206D3FAC3FBD}",p 0,i 4,w "InstallLocation",w .r0,*i 1024)i.r1'
 FileWriteUTF16LE $9 "Machine InstallLocation result=$1 value=$0$\r$\n"
 FileClose $9
 SetErrorLevel 0
 Quit
FunctionEnd
Section
SectionEnd
'@
$nsisPath = Join-Path $work 'probe.nsi'
Set-Content $nsisPath $nsis -Encoding utf8
function Run-Wait([string]$File, [string]$Arguments) {
 $process = Start-Process $File -ArgumentList $Arguments -PassThru
 if (-not $process.WaitForExit(300000)) { throw 'Probe subprocess timed out; no MSI process was terminated.' }
 $process.Refresh()
 Write-Host "Process completed: $File, exit=$($process.ExitCode)"
 if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) { throw "Subprocess failure: $($process.ExitCode)" }
}
try {
 Run-Wait "$env:SystemRoot\System32\msiexec.exe" "/i `"$legacyMsi`" INSTALLDIR=`"$env:ProgramFiles\Codex-X`" /qn /norestart /L*v `"$work\install.log`""
 & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File $psProbePath
 & "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File $psProbePath
 & $compiler /V3 $nsisPath
 if ($LASTEXITCODE -ne 0) { throw 'Native NSIS probe compilation failed.' }
 Run-Wait (Join-Path $work 'probe.exe') '/S'
} finally {
 $probeLog = Join-Path $work 'nsis-probe.log'
 if (Test-Path $probeLog) { Get-Content $probeLog }
 Run-Wait "$env:SystemRoot\System32\msiexec.exe" "/x {F71E3F3F-A463-4397-AB46-206D3FAC3FBD} /qn /norestart /L*v `"$work\uninstall.log`""
}
