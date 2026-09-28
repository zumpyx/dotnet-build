<#
.SYNOPSIS
    Publishes staged build artifacts and build status.

.DESCRIPTION
    1. Renders the README for the artifacts branch from status.json
    2. Pushes the staging directory to the artifacts branch (default NET4.8)
    3. Commits the updated status.json back to the current branch (main)

    Run scripts/build.ps1 first — this script expects staging/ and an
    up-to-date status.json to exist.
#>
[CmdletBinding()]
param(
    [string]$StatusFile      = 'status.json',
    [string]$StagingDir      = 'staging',
    [string]$ArtifactsBranch = 'NET4.8'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $StatusFile)) { throw "$StatusFile not found — run scripts/build.ps1 first" }
if (-not (Test-Path $StagingDir)) { throw "$StagingDir not found — run scripts/build.ps1 first" }

$status = @(Get-Content $StatusFile -Raw | ConvertFrom-Json)

# ─────────────────── 1. Render artifacts-branch README ─────────────────────

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Build Artifacts')
$lines.Add('')
$lines.Add('Compiled binaries built automatically from upstream repositories.')
$lines.Add('')
$lines.Add('Classic .NET Framework tools ship in three flavours:')
$lines.Add('')
$lines.Add('| Suffix | CPU Target |')
$lines.Add('|--------|------------|')
$lines.Add('| `.any.exe` | AnyCPU — JIT selects 32/64-bit at runtime |')
$lines.Add('| `.x86.exe` | Forced 32-bit |')
$lines.Add('| `.x64.exe` | Forced 64-bit |')
$lines.Add('')
$lines.Add('SDK-style (.NET 5+/Core) tools ship as a single portable binary.')
$lines.Add('')
$lines.Add('## Build Status')
$lines.Add('')
$lines.Add('| Tool | Repository | Framework | Engine | Status | Last Successful Build |')
$lines.Add('|------|-----------|-----------|--------|--------|----------------------|')

foreach ($tool in $status) {
    $icon   = if ($tool.buildStatus -eq 'success') { '✅ Success' } else { '❌ Failed' }
    $lastOk = if ($tool.lastSuccess) { $tool.lastSuccess } else { 'Never' }
    $fw     = if ($tool.framework) { $tool.framework } else { '—' }
    $engine = if ($tool.engine) { $tool.engine } else { '—' }
    $name   = [string]$tool.name
    $lines.Add("| $name | [$name]($($tool.repoUrl)) | $fw | $engine | $icon | $lastOk |")
}

$lines.Add('')
$lines.Add("_Last updated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC_")

($lines -join "`n") | Set-Content (Join-Path $StagingDir 'README.md') -Encoding UTF8
Write-Host "artifacts README rendered from $StatusFile"

# ─────────────────── 2. Push artifacts to NET4.8 branch ────────────────────

git config user.name  'github-actions[bot]'
git config user.email 'github-actions[bot]@users.noreply.github.com'

$stagingAbs = (Resolve-Path $StagingDir).Path
$netDir = Join-Path (Split-Path $env:GITHUB_WORKSPACE -Parent) 'artifacts-worktree'

git fetch origin $ArtifactsBranch --depth=1 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    git worktree add $netDir $ArtifactsBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git worktree add $ArtifactsBranch failed" }
} else {
    git worktree add --orphan -b $ArtifactsBranch $netDir 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git worktree add --orphan $ArtifactsBranch failed" }
}

Get-ChildItem $netDir -Force |
    Where-Object { $_.Name -ne '.git' } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Copy-Item -Path "$stagingAbs\*" -Destination $netDir -Recurse -Force

Push-Location $netDir
try {
    git add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add failed in artifacts worktree' }
    git diff --staged --quiet
    if ($LASTEXITCODE -ne 0) {
        git commit -m "build: update artifacts $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed in artifacts worktree' }

        git push origin $ArtifactsBranch
        if ($LASTEXITCODE -ne 0) {
            # Lost a race against a concurrent run — rebase on its push and retry once
            Write-Warning 'push rejected, retrying on top of the latest remote state'
            git pull --rebase origin $ArtifactsBranch
            if ($LASTEXITCODE -ne 0) { throw 'git pull --rebase failed' }
            git push origin $ArtifactsBranch
            if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
        }
        Write-Host "Pushed artifacts to $ArtifactsBranch branch"
    } else {
        Write-Host "No changes to push to $ArtifactsBranch"
    }
} finally {
    Pop-Location
    git worktree remove $netDir --force 2>&1 | Out-Null
}

# ─────────────────── 3. Commit status.json back to main ────────────────────

git add $StatusFile
git diff --staged --quiet
if ($LASTEXITCODE -ne 0) {
    git commit -m 'chore: update build status [skip ci]'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed for status.json' }
    git push origin HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git push failed for status.json' }
    Write-Host "$StatusFile committed"
} else {
    Write-Host "$StatusFile unchanged, nothing to commit"
}
