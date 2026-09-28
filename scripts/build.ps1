<#
.SYNOPSIS
    Universal .NET build engine for dotnet-build.

.DESCRIPTION
    Reads config.json, clones each configured upstream repository, locates the
    project/solution (supporting nested paths and explicit file selection),
    restores packages, builds with the appropriate engine (MSBuild for classic
    .NET Framework projects, dotnet CLI for SDK-style projects, or a fully
    custom command) and stages the binaries for publishing.

.OUTPUTS
    - <StagingDir>/<Tool>/   staged binaries (published to the artifacts branch)
    - status.json            per-tool build status (committed back to main)
#>
[CmdletBinding()]
param(
    [string]$ConfigFile  = 'config.json',
    [string]$StatusFile  = 'status.json',
    [string]$StagingDir  = 'staging',
    [string]$SourceDir   = 'src',
    [string]$BuildOutDir = 'build_out'
)

$ErrorActionPreference = 'Continue'

# ─────────────────────────────── helpers ───────────────────────────────────

function Write-Step([string]$Message) { Write-Host "  → $Message" }

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "required build tool '$Name' is not available on PATH"
    }
}

function Get-CsprojKind([string]$ProjFile) {
    try {
        $text = Get-Content $ProjFile -Raw -ErrorAction Stop
        if ($text -match '<Project[^>]*\bSdk\s*=') { return 'sdk' }
        if ($text -match '<Project[^>]*xmlns\s*=') { return 'legacy' }
        if ($text -match '<TargetFramework[s]?[ >]') { return 'sdk' }
    } catch { }
    return 'legacy'
}

function Get-ProjectKind([string]$ProjectFile) {
    if ($ProjectFile -notmatch '\.sln$') { return Get-CsprojKind $ProjectFile }

    $slnDir = Split-Path $ProjectFile -Parent
    $projRefs = @(Select-String -Path $ProjectFile -Pattern '"([^"]+\.(?:csproj|vbproj|fsproj))"' -AllMatches |
        ForEach-Object { $_.Matches } |
        ForEach-Object { $_.Groups[1].Value -replace '\\', '/' } |
        Where-Object { Test-Path (Join-Path $slnDir ($_ -replace '/', [IO.Path]::DirectorySeparatorChar)) })

    if ($projRefs.Count -eq 0) { return 'legacy' }
    foreach ($r in $projRefs) {
        $p = Join-Path $slnDir ($r -replace '/', [IO.Path]::DirectorySeparatorChar)
        if ((Get-CsprojKind $p) -eq 'legacy') { return 'legacy' }
    }
    return 'sdk'
}

function Get-SdkFramework([string]$ProjectFile) {
    $text = Get-Content $ProjectFile -Raw -ErrorAction SilentlyContinue
    if ($text -match '<TargetFrameworks?>\s*([^<;]+)') { return $Matches[1].Trim() }
    return $null
}

function Find-ProjectFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowNull()][AllowEmptyString()][string]$ExplicitFile,
        [Parameter(Mandatory)][string]$ToolName
    )

    if (-not (Test-Path $Root)) { return $null }

    # Explicit file name / wildcard — prefer the shallowest match
    if ($ExplicitFile) {
        $hit = Get-ChildItem $Root -Recurse -File -Filter $ExplicitFile -ErrorAction SilentlyContinue |
               Sort-Object { $_.FullName.Length } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
        return $null
    }

    $noise = '(?i)(test|sample|example|demo|benchmark)'

    # 1) Solution files — prefer one named after the tool, then the shallowest
    $slns = @(Get-ChildItem $Root -Recurse -File -Filter '*.sln' -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -notmatch $noise })
    if ($slns.Count -gt 0) {
        $exact = $slns | Where-Object { $_.BaseName -ieq $ToolName } | Select-Object -First 1
        if ($exact) { return $exact.FullName }
        return ($slns | Sort-Object { $_.FullName.Length } | Select-Object -First 1).FullName
    }

    # 2) Project files — same preference order
    $projs = @(Get-ChildItem $Root -Recurse -File -Include '*.csproj', '*.vbproj', '*.fsproj' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notmatch $noise })
    if ($projs.Count -gt 0) {
        $exact = $projs | Where-Object { $_.BaseName -ieq $ToolName } | Select-Object -First 1
        if ($exact) { return $exact.FullName }
        return ($projs | Sort-Object { $_.FullName.Length } | Select-Object -First 1).FullName
    }
    return $null
}

function Invoke-PackageRestore([string]$ProjectFile, [string]$Kind) {
    $dir = Split-Path $ProjectFile -Parent
    $hasPackagesConfig = Get-ChildItem $dir -Recurse -Filter 'packages.config' -ErrorAction SilentlyContinue |
                         Select-Object -First 1
    if ($hasPackagesConfig) {
        Write-Step 'Restoring packages via nuget (packages.config)'
        Assert-Command nuget
        nuget restore $ProjectFile 2>&1 | Write-Host
        return
    }
    if ($Kind -eq 'sdk') {
        Write-Step 'Restoring packages via dotnet restore'
        Assert-Command dotnet
        dotnet restore $ProjectFile 2>&1 | Write-Host
    }
}

function Copy-Artifacts {
    param(
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)][string]$ToolStaging,
        $ArtifactCfg,
        [Parameter(Mandatory)][string]$Suffix
    )

    $include = @('*.exe')
    $exclude = @()
    if ($ArtifactCfg) {
        if ($ArtifactCfg.include) { $include = @($ArtifactCfg.include) }
        if ($ArtifactCfg.exclude) { $exclude = @($ArtifactCfg.exclude) }
    }

    $outFull = (Resolve-Path $OutDir).Path
    $files = @(Get-ChildItem $outFull -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $rel = $_.FullName.Substring($outFull.Length).TrimStart('\', '/')
        $in = $false
        foreach ($g in $include) {
            $pattern = ([string]$g) -replace '\\', '/'
            if ($rel -like $pattern -or $_.Name -like $pattern) { $in = $true; break }
        }
        if (-not $in) { return $false }
        foreach ($e in $exclude) {
            $pattern = ([string]$e) -replace '\\', '/'
            if ($rel -like $pattern -or $_.Name -like $pattern) { return $false }
        }
        return $_.Name -notmatch '\.vshost\.exe$'
    } | Sort-Object FullName -Unique)

    foreach ($f in $files) {
        $dest = if ($Suffix -eq 'bin') { Join-Path $ToolStaging $f.Name }
                else { Join-Path $ToolStaging "$($f.BaseName).$Suffix$($f.Extension)" }
        Copy-Item $f.FullName $dest -Force
        Write-Host "    ✔ $($f.Name) → $([IO.Path]::GetFileName($dest))"
    }
    return $files.Count
}

function Build-LegacyProject {
    param(
        [AllowNull()]$ProjCfg,
        [AllowNull()]$ArtifactCfg,
        [Parameter(Mandatory)][string]$ProjectFile,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ToolStaging,
        [Parameter(Mandatory)][string[]]$ExtraArgs
    )

    $cfg = if ($ProjCfg -and $ProjCfg.configuration) { [string]$ProjCfg.configuration } else { 'Release' }
    $fw  = if ($ProjCfg -and $ProjCfg.framework)     { [string]$ProjCfg.framework }     else { 'v4.8' }

    $targets = @(
        @{ PlatformTarget = 'AnyCPU'; Suffix = 'any' },
        @{ PlatformTarget = 'x86';    Suffix = 'x86' },
        @{ PlatformTarget = 'x64';    Suffix = 'x64' }
    )

    $built = @()
    foreach ($t in $targets) {
        $outDir = [IO.Path]::GetFullPath((Join-Path $BuildOutDir "$Name/$($t.Suffix)"))
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        Write-Step "msbuild [$($t.Suffix)] (framework $fw, $cfg)"

        $msbuildArgs = @(
            $ProjectFile, '/t:Rebuild', "/p:Configuration=$cfg",
            "/p:TargetFrameworkVersion=$fw",
            "/p:PlatformTarget=$($t.PlatformTarget)",
            "/p:OutputPath=$outDir",
            '/p:AllowUnsafeBlocks=true', '/m', '/nologo',
            '/verbosity:minimal', '/restore'
        ) + $ExtraArgs

        $exes = @()
        & msbuild @msbuildArgs 2>&1 | Write-Host
        if ($LASTEXITCODE -eq 0) {
            $exes = @(Get-ChildItem $outDir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -notmatch '\.vshost\.exe$' } |
                      Sort-Object Length -Descending)
        }
        if ($exes.Count -eq 0) {
            Write-Warning "    ✘ no .exe produced for [$($t.Suffix)]"
            continue
        }

        if ($exes.Count -eq 1) {
            Copy-Item $exes[0].FullName (Join-Path $ToolStaging "$Name.$($t.Suffix).exe") -Force
            Write-Host "    ✔ $Name.$($t.Suffix).exe"
        } else {
            foreach ($e in $exes) {
                Copy-Item $e.FullName (Join-Path $ToolStaging "$($e.BaseName).$($t.Suffix).exe") -Force
                Write-Host "    ✔ $($e.BaseName).$($t.Suffix).exe"
            }
        }
        $built += $t.Suffix
    }
    return $built
}

function Build-SdkProject {
    param(
        [AllowNull()]$ProjCfg,
        [AllowNull()]$ArtifactCfg,
        [Parameter(Mandatory)][string]$ProjectFile,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ToolStaging,
        [Parameter(Mandatory)][string[]]$ExtraArgs
    )

    $cfg    = if ($ProjCfg -and $ProjCfg.configuration) { [string]$ProjCfg.configuration } else { 'Release' }
    $outDir = [IO.Path]::GetFullPath((Join-Path $BuildOutDir "$Name/bin"))
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $dotnetArgs = @('build', $ProjectFile, '-c', $cfg, '-o', $outDir, '--nologo')
    if ($ProjCfg -and $ProjCfg.framework) { $dotnetArgs += @('-f', [string]$ProjCfg.framework) }
    $dotnetArgs += $ExtraArgs

    Write-Step "dotnet build ($cfg)"
    & dotnet @dotnetArgs 2>&1 | Write-Host
    if ($LASTEXITCODE -ne 0) { return @() }

    $staged = Copy-Artifacts $outDir $ToolStaging $ArtifactCfg 'bin'
    if ($staged -eq 0) { return @() }
    return @('bin')
}

# ────────────────────────────── load config ────────────────────────────────

if (-not (Test-Path $ConfigFile)) { throw "Config file not found: $ConfigFile" }
$rawConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
# Support both a bare array and { "tools": [...] }
# (Note: `$array.missingProp` returns an array of $nulls which is truthy — check the type instead)
if ($rawConfig -is [System.Array]) { $config = $rawConfig }
else { $config = @($rawConfig.tools) }
if ($config.Count -eq 0) { throw "No tools configured in $ConfigFile" }

$statusMap = @{}
if (Test-Path $StatusFile) {
    try {
        foreach ($entry in @(Get-Content $StatusFile -Raw | ConvertFrom-Json)) {
            $statusMap[$entry.name] = $entry
        }
    } catch { }
}

New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

# ────────────────────────────── build loop ─────────────────────────────────

foreach ($tool in $config) {
    if (-not $tool.enabled) { Write-Host "Skipping disabled tool: $($tool.name)"; continue }

    $name    = [string]$tool.name
    $repoUrl = [string]$tool.repository
    $branch  = if ($tool.branch) { [string]$tool.branch } else { $null }
    $projCfg = $tool.project
    $artCfg  = $tool.artifacts
    $now     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $extraArgs = @()
    if ($projCfg -and $projCfg.arguments) { $extraArgs = @($projCfg.arguments | ForEach-Object { [string]$_ }) }

    $prev = $statusMap[$name]
    $result = [ordered]@{
        name        = $name
        repoUrl     = $repoUrl
        branch      = $branch
        buildStatus = 'failed'
        lastUpdated = $now
        lastSuccess = if ($prev) { $prev.lastSuccess } else { $null }
        projectFile = $null
        engine      = $null
        framework   = $null
        archs       = @()
        error       = $null
    }

    Write-Host ''
    Write-Host '════════════════════════════════════════'
    Write-Host "  Building: $name"
    Write-Host "  Repo:     $repoUrl"
    if ($branch) { Write-Host "  Branch:   $branch" }
    Write-Host '════════════════════════════════════════'

    try {
        # ── Clone ───────────────────────────────────────────────────────────
        $srcDir = Join-Path $SourceDir $name
        Remove-Item $srcDir -Recurse -Force -ErrorAction SilentlyContinue
        $cloneArgs = @('clone', '--depth', '1')
        if ($branch) { $cloneArgs += @('--branch', $branch) }
        $cloneArgs += @($repoUrl, $srcDir)
        git @cloneArgs 2>&1 | Write-Host
        if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)" }

        $toolStaging = Join-Path $StagingDir $name
        New-Item -ItemType Directory -Path $toolStaging -Force | Out-Null

        # ── Fully custom build (script or command) ──────────────────────────
        if ($projCfg -and ($projCfg.buildScript -or $projCfg.buildCommand)) {
            $result.engine = 'custom'
            $customOut = [IO.Path]::GetFullPath((Join-Path $BuildOutDir "$name/custom"))
            New-Item -ItemType Directory -Path $customOut -Force | Out-Null

            if ($projCfg.buildScript) {
                # Repo-relative PowerShell script, invoked with -Src / -Out parameters
                $scriptRel = [string]$projCfg.buildScript
                $repoRoot  = Split-Path $PSScriptRoot -Parent
                $scriptPath = $scriptRel
                if (-not ([IO.Path]::IsPathRooted($scriptPath))) { $scriptPath = Join-Path $repoRoot $scriptRel }
                $scriptPath = [IO.Path]::GetFullPath($scriptPath)
                if (-not (Test-Path $scriptPath)) { throw "buildScript '$scriptRel' not found in this repository" }

                Write-Step "custom script: $scriptRel"
                $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
                if (-not $pwshExe) { $pwshExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
                if (-not $pwshExe) { throw 'neither pwsh nor powershell is available to run the build script' }
                & $pwshExe -NoProfile -File $scriptPath `
                    -Src ([IO.Path]::GetFullPath($srcDir)) `
                    -Out $customOut 2>&1 | Write-Host
                if ($LASTEXITCODE -ne 0) { throw "build script '$scriptRel' failed (exit $LASTEXITCODE)" }
            } else {
                $cmdLine = [string]$projCfg.buildCommand
                $cmdLine = $cmdLine.Replace('{src}', "`"$([IO.Path]::GetFullPath($srcDir))`"")
                $cmdLine = $cmdLine.Replace('{out}', "`"$customOut`"")

                Write-Step "custom command: $cmdLine"
                # Write to a temporary .cmd file to avoid PowerShell native-argument quoting issues
                $tmpCmd = Join-Path ([IO.Path]::GetTempPath()) "dotnet-build-$name.cmd"
                Set-Content -Path $tmpCmd -Value $cmdLine -Encoding ASCII
                try {
                    & cmd /c $tmpCmd 2>&1 | Write-Host
                    if ($LASTEXITCODE -ne 0) { throw "custom build command failed (exit $LASTEXITCODE)" }
                } finally {
                    Remove-Item $tmpCmd -Force -ErrorAction SilentlyContinue
                }
            }

            $staged = Copy-Artifacts $customOut $toolStaging $artCfg 'bin'
            if ($staged -eq 0) { throw 'custom build produced no artifacts' }
            $result.archs = @('bin')
        } else {
            # ── Locate project ──────────────────────────────────────────────
            $searchRoot = $srcDir
            if ($projCfg -and $projCfg.path) {
                $searchRoot = Join-Path $srcDir ([string]$projCfg.path)
                if (-not (Test-Path $searchRoot)) {
                    throw "project.path '$($projCfg.path)' does not exist in the repository"
                }
            }
            $explicit = if ($projCfg -and $projCfg.file) { [string]$projCfg.file } else { $null }

            $projectFile = Find-ProjectFile -Root $searchRoot -ExplicitFile $explicit -ToolName $name
            if (-not $projectFile) {
                if ($explicit) { throw "project file '$explicit' not found under '$searchRoot'" }
                throw "no .sln / .csproj / .vbproj / .fsproj found under '$searchRoot'"
            }
            $result.projectFile = $projectFile.Substring((Resolve-Path $srcDir).Path.Length).TrimStart('\', '/')
            Write-Step "project file: $($result.projectFile)"

            # ── Choose engine ───────────────────────────────────────────────
            $kind = Get-ProjectKind $projectFile
            $engine = if ($projCfg -and $projCfg.tool -and [string]$projCfg.tool -ne 'auto') {
                          [string]$projCfg.tool
                      } elseif ($kind -eq 'legacy') { 'msbuild' } else { 'dotnet' }
            $result.engine = $engine
            Write-Step "engine: $engine (detected project kind: $kind)"

            # Record the intended framework up-front so it survives build failures
            if ($engine -eq 'msbuild') {
                $result.framework = if ($projCfg -and $projCfg.framework) { [string]$projCfg.framework } else { 'v4.8' }
                Assert-Command msbuild
            } elseif ($engine -eq 'dotnet') {
                $result.framework = if ($projCfg -and $projCfg.framework) { [string]$projCfg.framework }
                                      else { Get-SdkFramework $projectFile }
                Assert-Command dotnet
            } else {
                throw "unknown engine '$engine' (expected: auto, msbuild or dotnet)"
            }

            Invoke-PackageRestore $projectFile $kind

            # ── Build ───────────────────────────────────────────────────────
            switch ($engine) {
                'msbuild' { $built = Build-LegacyProject $projCfg $artCfg $projectFile $name $toolStaging $extraArgs }
                'dotnet'  { $built = Build-SdkProject $projCfg $artCfg $projectFile $name $toolStaging $extraArgs }
            }

            $result.archs = @($built)
            if (@($built).Count -eq 0) { throw 'build produced no artifacts' }
        }

        $result.buildStatus = 'success'
        $result.lastSuccess = $now
        Write-Host "  ✔ $name complete ($([string]::Join(', ', @($result.archs))))"
    } catch {
        $result.error = (($_.Exception.Message -split "`r?`n")[0]).Trim()
        Write-Warning "  ✘ $name failed: $($result.error)"
    }

    $results.Add([PSCustomObject]$result)
}

# ─────────────────────────────── write status ──────────────────────────────

ConvertTo-Json -Depth 10 -InputObject @($results) | Set-Content $StatusFile -Encoding UTF8
Write-Host ''
Write-Host "Build results saved to $StatusFile"
