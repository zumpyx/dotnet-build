<#
.SYNOPSIS
    Builds the obfuscated ("_ofs") winPEAS binaries, mirroring the official
    PEASS-ng CI pipeline (CI-master_tests.yml).

.DESCRIPTION
    1. nuget restore + MSBuild winPEAS.sln in Release for x64 / x86 / Any CPU
    2. Stage the binaries with the official names (winPEASx64/x86/any.exe)
    3. Extract the bundled Dotfuscator Community Edition, install its license
    4. Run the repo's Dotfuscator configs to produce the *_ofs.exe binaries
    5. Copy the three *_ofs.exe artifacts to -Out

.PARAMETER Src
    Absolute path to the cloned PEASS-ng repository.

.PARAMETER Out
    Absolute path to an empty directory; the *_ofs.exe artifacts land here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Src,
    [Parameter(Mandatory)][string]$Out
)

$ErrorActionPreference = 'Stop'
Set-Location $Src   # Dotfuscator XML paths are relative to the repo root

function Invoke-Native([string]$File, [string[]]$Args, [string]$Step) {
    Write-Host "  -> $Step"
    & $File @Args 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit $LASTEXITCODE)" }
}

$sln    = 'winPEAS\winPEASexe\winPEAS.sln'
$proj   = 'winPEAS\winPEASexe\winPEAS'
$binDir = 'winPEAS\winPEASexe\binaries'
$ofsDir = Join-Path $binDir 'Obfuscated Releases'

# ── 1. Restore + build (same three platforms as the official pipeline) ──────
Invoke-Native nuget @('restore', $sln) 'nuget restore'

foreach ($platform in @('x64', 'x86', 'Any CPU')) {
    Invoke-Native msbuild @(
        '-m', "`"$sln`"", '/t:Rebuild',
        '/p:Configuration=Release', "/p:Platform=`"$platform`"",
        '/p:UseSharedCompilation=false'
    ) "msbuild [$platform]"
}

# ── 2. Stage binaries with official names (Dotfuscator XML input paths) ─────
New-Item -ItemType Directory -Force "$binDir\x64\Release", "$binDir\x86\Release", "$binDir\Release" | Out-Null
Copy-Item "$proj\bin\x64\Release\winPEAS.exe" "$binDir\x64\Release\winPEASx64.exe" -Force
Copy-Item "$proj\bin\x86\Release\winPEAS.exe" "$binDir\x86\Release\winPEASx86.exe" -Force
Copy-Item "$proj\bin\Release\winPEAS.exe"     "$binDir\Release\winPEASany.exe"   -Force

# ── 3. Dotfuscator Community Edition (bundled in the upstream repo) ─────────
Invoke-Native 7z @('x', 'winPEAS\winPEASexe\Dotfuscator\DotfuscatorCE.zip', '-y') 'extract DotfuscatorCE'

$licDir = Join-Path $env:USERPROFILE 'AppData\Local\PreEmptive Solutions\Dotfuscator Community Edition\6.0'
New-Item -ItemType Directory -Force $licDir | Out-Null
Copy-Item 'DotfuscatorCE\license\*' $licDir -Force -ErrorAction SilentlyContinue

# ── 4. Obfuscate ────────────────────────────────────────────────────────────
foreach ($arch in @('x64', 'x86', 'any')) {
    Invoke-Native 'DotfuscatorCE\dotfuscator.exe' @("`"$ofsDir\$arch.xml`"") "dotfuscator [$arch]"
}

# ── 5. Collect the *_ofs artifacts ──────────────────────────────────────────
Copy-Item "$ofsDir\Dotfuscated\x64\winPEASx64.exe" (Join-Path $Out 'winPEASx64_ofs.exe') -Force
Copy-Item "$ofsDir\Dotfuscated\x86\winPEASx86.exe" (Join-Path $Out 'winPEASx86_ofs.exe') -Force
Copy-Item "$ofsDir\Dotfuscated\any\winPEASany.exe" (Join-Path $Out 'winPEASany_ofs.exe') -Force

Write-Host 'winPEAS *_ofs artifacts built'
