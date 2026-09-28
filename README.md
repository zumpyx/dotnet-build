# Build Artifacts

Compiled binaries built automatically from upstream repositories.

Classic .NET Framework tools ship in three flavours:

| Suffix | CPU Target |
|--------|------------|
| `.any.exe` | AnyCPU — JIT selects 32/64-bit at runtime |
| `.x86.exe` | Forced 32-bit |
| `.x64.exe` | Forced 64-bit |

SDK-style (.NET 5+/Core) tools ship as a single portable binary.

## Build Status

| Tool | Repository | Framework | Engine | Status | Last Successful Build |
|------|-----------|-----------|--------|--------|----------------------|
| Rubeus | [Rubeus](https://github.com/GhostPack/Rubeus.git) | v4.8 | msbuild | ✅ Success | 09/28/2026 01:44:14 |
| Seatbelt | [Seatbelt](https://github.com/GhostPack/Seatbelt.git) | v4.8 | msbuild | ✅ Success | 09/28/2026 01:44:38 |
| SharpUp | [SharpUp](https://github.com/GhostPack/SharpUp.git) | v4.8 | msbuild | ✅ Success | 09/28/2026 01:44:42 |
| SharpHound | [SharpHound](https://github.com/BloodHoundAD/SharpHound.git) | — | dotnet | ✅ Success | 09/28/2026 01:44:44 |
| Certify | [Certify](https://github.com/GhostPack/Certify.git) | v4.8 | msbuild | ✅ Success | 09/28/2026 01:45:30 |
| ADSearch | [ADSearch](https://github.com/tomcarver16/ADSearch.git) | v4.8 | msbuild | ✅ Success | 09/28/2026 01:45:50 |
| SharpDPAPI | [SharpDPAPI](https://github.com/GhostPack/SharpDPAPI.git) | v4.8 | msbuild | ✅ Success | 09/28/2026 01:46:04 |
| SweetPotato | [SweetPotato](https://github.com/CCob/SweetPotato.git) | v4.8 | msbuild | ✅ Success | 09/28/2026 01:46:11 |
| SharpSCCM | [SharpSCCM](https://github.com/Mayyhem/SharpSCCM.git) | v4.8 | msbuild | ✅ Success | 09/28/2026 01:46:22 |
| winPEAS | [winPEAS](https://github.com/peass-ng/PEASS-ng.git) | — | custom | ❌ Failed | Never |

_Last updated: 2026-09-28 01:46 UTC_
