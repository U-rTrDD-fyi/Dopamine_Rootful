<img src="https://github.com/opa334/Dopamine/assets/52459150/ed04dd3e-d879-456d-9aa3-d4ed44819c7e" width="64" />

# Dopamine Rootful (AIO)

A **rootful** semi-untethered jailbreak for iOS 15, that installs both
**rootless (`iphoneos-arm64`) and legacy rootful (`iphoneos-arm`) tweaks** from
the Sileo GUI.

> **Star [opa334/Dopamine](https://github.com/opa334/Dopamine) first.** None of
> this exists without it. The rootful groundwork is
> [ghh-jb](https://github.com/ghh-jb)'s — see [Credits](#credits).

---

## What this is

Three layers, each building on the one below:

1. **Dopamine** — opa334's semi-untethered jailbreak for iOS 15.
2. **ghh-jb's rootful port** — replaces the rootless-only layout with real
   writable APFS volumes over `/usr`, `/Library`, `/Applications`,
   `/private/etc`, `/sbin` and `/bin`, via `bootstrapfs`.
3. **This fork** — fixes the bugs that stopped tweaks loading at all, and adds
   the machinery to install legacy rootful tweaks alongside rootless ones.

Despite the name, this is **not** a pre-rootless jailbreak. It uses a Procursus
rootless bootstrap in a preboot jbroot with a `/var/jb` symlink, *and* real
writable system volumes. That hybrid is why it can host both kinds of tweak —
and why the code does not look like either kind of jailbreak you may be used to.

**Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing anything.**
Several sharp edges (notably `/usr/lib`) behave the opposite of how they look.

## What is different from upstream Dopamine

| | Upstream | This fork |
|---|---|---|
| System paths | read-only | real writable APFS volumes |
| Tweak architectures | `iphoneos-arm64` | `iphoneos-arm64` **and** `iphoneos-arm` |
| Package managers | Sileo, Zebra | patched Sileo only, installed automatically |
| Legacy tweak signatures | not handled | re-signed to SHA-256 on install |
| Update checks | opa334/Dopamine | this repo |
| SSH | not bundled | `sshd` installed and auto-started (ports 22 / 2222) |

## Status

Verified end to end on **iPhone 6s (iPhone8,1), iOS 15.0.2**: a 2020-era
rootful tweak installed through the Sileo GUI with no forcing, and injected
into SpringBoard alongside a rootless tweak.

ghh-jb reports the rootful base working on iPhone SE 2020 (15.2) and
iPhone SE 2016 (15.8.6). **iOS 16 is not supported** — it panics on userspace
reboot due to Launch Constraints on core daemons.

On A12 and later, legacy tweaks can only inject into arm64 App Store apps, not
arm64e system processes. See [docs/LEGACY-TWEAKS.md](docs/LEGACY-TWEAKS.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | jbroot, bootstrapfs volumes, the `/usr/lib` trap, injection, trustcache |
| [docs/LEGACY-TWEAKS.md](docs/LEGACY-TWEAKS.md) | how both architectures install; diagnosing a tweak that will not load |
| [docs/BUILDING.md](docs/BUILDING.md) | toolchain, SDKs, build order, known build failures, CI |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | runtime failure modes and how to recognise them |

## Building

Full detail in [docs/BUILDING.md](docs/BUILDING.md). Short version:

```bash
# Xcode 14 or 15 (NOT 16+), Theos, and: ldid dpkg trustcache xz coreutils
#                                       findutils libarchive openssl@3
./Application/Dopamine/Resources/download_bootstraps.sh   # ~40 MB, not in git
gmake -j$(sysctl -n hw.logicalcpu) NIGHTLY=1
# -> Application/Dopamine.tipa
```

> **Do not run `git submodule init/update`.** ChOma, XPF, opainject, litehook
> and kfd are vendored as ordinary files; `.gitmodules` is stale and its kfd
> path is wrong. The older instructions in this README were misleading and have
> been removed.

The patched Sileo in [`Sileo/`](Sileo) is vendored the same way and builds
independently:

```bash
cd Sileo && make package SILEO_PLATFORM=iphoneos-arm64
```

Install `Application/Dopamine.tipa` with TrollStore. BaseBin changes need one
re-jailbreak to take effect, because the trustcache has to be regenerated.

## Credits

- **[opa334](https://github.com/opa334)** — Dopamine, TrollStore, ChOma, XPF
- **[ghh-jb](https://github.com/ghh-jb)** — the rootful port this builds on:
  [bootstrapfs](https://github.com/ghh-jb/bootstrapfs),
  [APFSRW](https://github.com/ghh-jb/APFSRW),
  [Makerw](https://github.com/ghh-jb/Makerw),
  [Fugu15_Rootful](https://github.com/ghh-jb/Fugu15_Rootful)
- **[Sileo Team](https://github.com/Sileo/Sileo)** — Sileo
- **[RootHide](https://github.com/roothide)** — Derootifier, whose approach to
  rootful conversion informed the design here
- **[Procursus Team](https://github.com/ProcursusTeam)** — the bootstrap
- **ElleKit**, **Fugu15**, **kfd**, **libgrabkernel2**, **plooshinit** — see the
  licence files in `Application/Dopamine/Resources/`

Original Dopamine site / downloads: https://ellekit.space/dopamine/

## Warnings

- Experimental, and intended for **developers and security researchers**. It is
  not a one-click jailbreak.
- Do not install on a primary or production device.
- Issues about **version support will be closed without response**.
- Issues about this rootful fork must **not** be filed against opa334/Dopamine
  unless they reproduce on unmodified Dopamine.
- Bootstrapping this version can be harder than the original jailbreak.
- No warranty. **Use at your own risk.**

## Legal notice

Retained from ghh-jb's original README:

1. **Purpose:** Studying iOS architecture, kernel protection mechanisms, and
   implementing "rootful" access concepts for legitimate device owners.
2. **Non-malicious use:** This software is NOT designed to gain unauthorized
   access to third-party data, bypass digital rights management (DRM), or
   perform any illegal activities.
3. **No warranty:** The software is provided **"as is"**, without warranty of
   any kind. The author shall not be liable for any claims, damages, or other
   liability arising from the use of this source code.
4. **Compliance:** Users are responsible for complying with their local laws.
   This project is a Proof of Concept and requires manual compilation.

This project **does not** contain malware, and must never be used for malicious
purposes such as bypassing iCloud Lock, MDM, or similar protections. ghh-jb has
stated that malicious use of patterns from `bootstrapfs`, `APFSRW`, `Makerw`,
`Dopamine_Rootful` or `Fugu15_Rootful` will be reported.

## Licence

See [LICENSE.md](LICENSE.md), and the per-component licences in
`Application/Dopamine/Resources/`. The vendored Sileo tree keeps its own
licence at [`Sileo/LICENSE`](Sileo/LICENSE).
