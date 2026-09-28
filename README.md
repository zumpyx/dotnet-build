# AutoBuild

Automated build repository for open-source .NET projects. Compiled binaries are
published to the [`NET4.8`](../../tree/NET4.8) branch on every successful build.

The build engine supports both classic .NET Framework projects (MSBuild) and
SDK-style projects (dotnet CLI), repositories where the project lives in a
subdirectory, and fully custom build commands.

## Branches

| Branch | Description |
|--------|-------------|
| `main` | Source configuration, build scripts, and status tracking |
| `NET4.8` | Compiled binaries (see artifact naming below) |

## How It Works

1. `scripts/build.ps1` reads `config.json` and, for each enabled tool:
   - clones the upstream repository (shallow, optional branch),
   - locates the solution/project file,
   - restores NuGet packages (`nuget restore` for `packages.config`,
     `dotnet restore` for SDK-style projects),
   - builds with the detected or configured engine,
   - stages the binaries and records the result in `status.json`.
2. `scripts/publish.ps1` renders the artifacts-branch README, pushes the
   binaries to the `NET4.8` branch, and commits `status.json` back to `main`.

### Project Detection

Unless configured explicitly, the engine picks the project file in this order:

1. `.sln` named after the tool, then the shallowest `.sln` in the search root
   (test/sample/example/demo/benchmark solutions are ignored)
2. same preference order for `.csproj` / `.vbproj` / `.fsproj`

The search root is the repository root, or `project.path` when set.

### Engine Detection

| Project style | Engine | Notes |
|---------------|--------|-------|
| Classic (`<Project xmlns=...>`) | `msbuild` | Built for AnyCPU / x86 / x64, forced to `framework` (default `v4.8`) |
| SDK-style (`<Project Sdk="...">`) | `dotnet` | Single portable build, native target framework |

## Configuration

`config.json` is a list of tool entries. Only `name`, `repository` and
`enabled` are required — everything else is optional and all existing entries
without them keep working unchanged.

```json
{
    "name": "MyTool",
    "repository": "https://github.com/author/MyTool.git",
    "branch": null,
    "enabled": true,
    "project": {
        "path": null,
        "file": null,
        "tool": "auto",
        "framework": null,
        "configuration": "Release",
        "arguments": [],
        "buildCommand": null
    },
    "artifacts": {
        "include": ["**/*.exe"],
        "exclude": []
    }
}
```

### Top-level fields

| Field | Default | Description |
|-------|---------|-------------|
| `name` | — | Tool name; used for artifact naming and project detection |
| `repository` | — | Git URL of the upstream repository |
| `branch` | default | Branch to clone (`null` = repository default) |
| `enabled` | `true` | Set to `false` to skip |
| `project` | — | Build tuning, see below |
| `artifacts` | — | Artifact collection, see below |

### `project` fields

| Field | Default | Description |
|-------|---------|-------------|
| `path` | repo root | Subdirectory inside the repository to search for the project |
| `file` | auto | Explicit file name or wildcard (e.g. `MyTool.sln`, `*.sln`) |
| `tool` | `auto` | `auto` / `msbuild` / `dotnet`; `auto` detects from the project file |
| `framework` | `v4.8` (classic) / project default (SDK) | Target framework — `v4.8`, `v4.6.2`, `net8.0`, ... |
| `configuration` | `Release` | Build configuration |
| `arguments` | `[]` | Extra arguments passed to msbuild/dotnet |
| `buildCommand` | — | Fully custom command line, see below |

### `artifacts` fields

| Field | Default | Description |
|-------|---------|-------------|
| `include` | `["*.exe"]` | Glob(s) matched against output files |
| `exclude` | `[]` | Glob(s) to drop |

### Custom build commands

For projects that need a non-standard build, set `project.buildCommand`.
The placeholders `{src}` (cloned repo path) and `{out}` (empty output
directory) are substituted before execution:

```json
{
    "name": "BadAssTools",
    "repository": "https://github.com/Flangvik/BadAssTools.git",
    "enabled": true,
    "project": {
        "buildCommand": "cmd /c \"C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\MSBuild\\Current\\Bin\\MSBuild.exe\" {src}\\BadAssTools.sln /p:Configuration=Release /p:OutputPath={out}"
    }
}
```

### Examples

Standard tool (works out of the box):

```json
{
    "name": "Rubeus",
    "repository": "https://github.com/GhostPack/Rubeus.git",
    "enabled": true
}
```

Project nested in a subdirectory:

```json
{
    "name": "SomeTool",
    "repository": "https://github.com/author/SomeTool.git",
    "enabled": true,
    "project": { "path": "src", "file": "SomeTool.sln" }
}
```

SDK-style project (e.g. .NET 8):

```json
{
    "name": "NewTool",
    "repository": "https://github.com/author/NewTool.git",
    "enabled": true,
    "project": { "framework": "net8.0", "configuration": "Release" }
}
```

## Artifact Naming

Classic .NET Framework builds produce one binary per CPU target:

| Suffix | Platform |
|--------|----------|
| `<Tool>.any.exe` | AnyCPU (JIT selects 32/64-bit at runtime) |
| `<Tool>.x86.exe` | Forced 32-bit |
| `<Tool>.x64.exe` | Forced 64-bit |

SDK-style builds produce a single binary per included artifact, keeping the
original file name.

## Build Status

See [`status.json`](status.json) for per-tool build status (including the
detected project file, engine, framework, built architectures and the last
error message), or visit the [`NET4.8`](../../tree/NET4.8) branch README for a
rendered table.

## Triggering a Build

Builds run automatically:

- Every **Monday at 02:00 UTC** (weekly scheduled run)
- On every **push to `main`** that modifies `config.json`, `scripts/`, or the
  workflow file
- Manually via **Actions → Build .NET Tools → Run workflow**

To add a tool: edit `config.json` on `main` and push — the workflow picks it
up automatically.

## License

This repository contains only build automation scripts. Each tool retains its
original license — refer to each tool's upstream repository for details.
