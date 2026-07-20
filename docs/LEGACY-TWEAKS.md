# Installing legacy (rootful) tweaks

This fork installs both `iphoneos-arm` and `iphoneos-arm64` packages from the
Sileo GUI, with no forcing and no per-package conversion step.

## Why the arch label is not a real constraint

`iphoneos-arm` and `iphoneos-arm64` are dpkg *architecture* strings. On any
arm64 device they describe the same ABI. The only thing the label ever encoded
was the install prefix:

| Label | Set by | Installs to |
|---|---|---|
| `iphoneos-arm` | `THEOS_PACKAGE_SCHEME` unset | `/` |
| `iphoneos-arm64` | `THEOS_PACKAGE_SCHEME=rootless` | `/var/jb` |

So a tweak marked `iphoneos-arm` is not incompatible with an
`iphoneos-arm64` jailbreak in any meaningful sense — it just expects its files
somewhere else. Since `bootstrapfs` gives this fork real writable `/usr` and
`/Library` volumes, that expectation can simply be satisfied.

The label is also unreliable in practice. Repositories carry packages declaring
`Architecture: iphoneos-arm` whose actual file is
`..._iphoneos-arm64.deb` in a `debs2.0-rootless/` directory.

One caveat that *is* real: on A12 and later, system processes run as arm64e and
cannot load an arm64-only dylib. Legacy tweaks predate arm64e, so on those
devices they will only inject into arm64 App Store apps, not SpringBoard. On
pre-A12 hardware (A9, A10, A11) everything is arm64 and this does not apply.

## What the jailbreak sets up

`DOBootstrapper -setupLegacyTweakSupport` runs from `finalizeBootstrap` on every
jailbreak and is idempotent.

**0. Bundles ElleKit.** ElleKit is the tweak loader — it ships `TweakLoader`,
`CydiaSubstrate.framework` and provides `mobilesubstrate`, and nothing loads
tweaks without it. It normally only arrives as a dependency of the first tweak,
and its repo metadata is *not* `Multi-Arch: foreign`, so on a fresh device a
legacy tweak's `mobilesubstrate` dependency cannot resolve until ellekit is both
installed and marked. `finalizeBootstrap` installs the bundled `ellekit.deb`
**before** the steps below, so the bridges and the `Multi-Arch` marking have it
to work with. Everything after depends on ellekit being present first.

**1. Registers the foreign architecture.**
`dpkg --add-architecture iphoneos-arm`. The Procursus bootstrap ships no
`var/lib/dpkg/arch`, so without this dpkg refuses the packages outright. Sileo
reads `dpkg --print-foreign-architectures` at startup, so this is also what
makes them appear in the GUI.

**2. Bridges the paths legacy tweaks hardcode.**

| Path | Points to |
|---|---|
| `/Library/MobileSubstrate/DynamicLibraries` | `/var/jb/usr/lib/TweakInject` |
| `/Library/Frameworks/CydiaSubstrate.framework` | jbroot equivalent |
| `/usr/lib/libsubstrate.dylib` | jbroot equivalent |
| `/usr/lib/libhooker.dylib` | jbroot equivalent |
| `/usr/lib/libellekit.dylib` | jbroot equivalent |

dpkg unpacks straight through the `DynamicLibraries` symlink, so a legacy deb's
tweaks land in the directory ellekit already scans while dpkg still records
them under their rootful paths.

`CydiaSubstrate.framework` matters more than it looks. Nearly every pre-rootless
tweak links it at `/Library/Frameworks/...`, and without the link the tweak
installs, re-signs and trust-caches correctly and *still* refuses to load.

These links **self-heal**. dpkg deletes the `DynamicLibraries` symlink when the
last package owning that directory is removed; the next install then creates a
real directory, and everything in it becomes invisible to ellekit. Both the
bootstrap and Sileo's patcher migrate stray contents back into `TweakInject`
and restore the link, only discarding the directory once it is verifiably empty.

**3. Marks installed packages `Multi-Arch: foreign`.**
APT resolves a foreign-arch package's dependencies *within its own
architecture*. A legacy tweak depending on `preferenceloader` wants
`preferenceloader:iphoneos-arm`, which does not exist — that library, like
`com.opa334.altlist` and `com.rpetrich.rocketbootstrap`, ships only as arm64.
Marking installed packages `Multi-Arch: foreign` lets the arm64 build satisfy
the dependency. This is the single change that unblocks the majority of legacy
packages, and it means they resolve against *modern, working* libraries rather
than dragging in stale rootful copies.

The status database is only rewritten after the parse is validated, a one-time
`status.premultiarch` backup is kept, and the new file is renamed into place so
an interrupted write cannot truncate it.

**4. Registers `dopamine-legacy-compat`.**
A status entry providing the virtual packages legacy tweaks declare —
`firmware`, `cydia`, `cy+cpu.*`, `cy+model.*` — which nothing on a rootless
bootstrap provides. Procursus already ships bare virtual entries like this. It
also gets an empty `info/dopamine-legacy-compat.list`, without which dpkg warns
"files list file … missing" on every transaction (the name is not
arch-qualified — dpkg only does that for packages installed in multiple arches).

## What Sileo does

The bundled Sileo is the patched build from [`Sileo/`](../Sileo).

**Strips the arch qualifier from APT output.** APT reports foreign-arch
packages as `name:iphoneos-arm`. Sileo's package database is keyed by the bare
identifier, so every lookup missed and installs failed with *"Install Identifier
Mismatch"* before dpkg ever ran. Fixed in `APTOperation.init(from:)`. This is an
upstream Sileo bug affecting foreign-arch installs on any jailbreak.

**Re-signs legacy dylibs.** Tweaks published before ~2017 carry SHA-1-only
signatures (`CodeDirectory v=20001`). iOS 15's AMFI cannot validate those, so
the tweak installs, reports success, and silently never loads.
`LegacyTweakPatcher` re-signs them with `ldid -Hsha256 -S` after each install
and reports what it did in the install log.

Executables are deliberately **not** re-signed — that would strip their
entitlements — so they are reported and left alone.

## Diagnosing a tweak that does not load

Work down this list; each step rules out one layer.

```bash
# 1. Is the loader itself being injected?
DYLD_PRINT_LIBRARIES=1 /var/jb/usr/bin/id 2>&1 | grep -i ellekit

# 2. Did the files land where ellekit scans?
ls -la /var/jb/usr/lib/TweakInject/
ls -ld /Library/MobileSubstrate/DynamicLibraries   # must be a symlink

# 3. Is the signature SHA-256?
codesign -dvvv --arch arm64 <tweak>.dylib 2>&1 | grep "Hash type"

# 4. Is its cdhash trusted?
jbctl trustcache info | grep -i <cdhash>

# 5. Are its linked libraries resolvable?
otool -L -arch arm64 <tweak>.dylib

# 6. Is it actually loaded?
lsof -p $(pgrep SpringBoard) | grep -i TweakInject
```

A tweak can pass every one of these and still do nothing visible, simply because
it targets behaviour that changed in iOS 15. That is a genuine incompatibility,
as opposed to the packaging problems above.
