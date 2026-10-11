# Dependencies and attribution

The launcher, selector, PowerShell modules, GUI, tests and documentation are
provided under the repository's MIT license. That license does not grant rights
to separately downloaded software or game files.

| Dependency | Source | Terms / purpose |
|---|---|---|
| MGPU Bridge 0.3.1 | [Neural-coprocessor](https://github.com/maohgad-web/Neural-coprocessor/releases/tag/0.3.1) | Upstream MIT project; performs neural rendering and display composition. Not vendored here. |
| Microsoft Detours | [Pinned source](https://github.com/microsoft/Detours/tree/1dbd4ea281d73d478aa8d09a8b83fbd265f715f7) | MIT; compiled locally into the selector and launcher. Preserve its [license](https://github.com/microsoft/Detours/blob/1dbd4ea281d73d478aa8d09a8b83fbd265f715f7/LICENSE.md) when distributing resulting binaries. |
| LLVM-MinGW 20261006 | [Release](https://github.com/mstorsjo/llvm-mingw/releases/tag/20261006) | Portable compiler; upstream component licenses apply. Not redistributed. |
| ReShade 6.8.0 full add-on build | [Official download site](https://reshade.me/) | Separately downloaded; upstream licenses apply. Installer payload is extracted, not executed by the downloader. |
| NVIDIA neural model, community-modified 310.8.SF-v2 | [Community mirror](https://github.com/RankFTW/rhi-repo/releases/tag/dlssnr-310.8.SF-v2) | Modified proprietary NVIDIA binary, unsigned. Mirror is not an NVIDIA download channel. No NVIDIA endorsement or redistribution authorization is claimed. Not included here. |
| NVAPI / NVIDIA driver | [NVAPI declarations](https://github.com/NVIDIA/nvapi/blob/main/nvapi.h) | Driver API used to map physical adapters to current Windows LUIDs. Driver files are not redistributed. |
| MSI Afterburner | [MSI](https://www.msi.com/Landing/afterburner/graphics-cards) | Optional, separately installed tool used manually in the reported session. Not installed or controlled by this repository. |

No game files, neural model binaries, ReShade binaries, bridge binaries,
downloaded archives or compiled executables are included in this repository.
Download scripts record and verify fixed archive SHA-256 hashes. A matching hash
establishes consistency with that pin, not safety or authorization to redistribute.
