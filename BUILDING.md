# Building Dopamine_Rootful

This document records the **exact, validated** way to build this fork into a
`Dopamine.tipa`, every issue that had to be fixed to make it compile on a modern
toolchain, and how that maps onto the GitHub Actions workflow (`.github/workflows/build.yml`).

Everything below was validated end‑to‑end on:

| Component | Version |
|-----------|---------|
| macOS     | Sonoma 14.1.1 (23B81) |
| Xcode     | 15.0.1 (15A507) → iOS 17.0 SDK via `xcrun` |
| Theos     | git `master` at `~/theos` |
| Homebrew  | arm64 (`/opt/homebrew`) |

Result: a clean `gmake NIGHTLY=1` at the repo root finishes in **~45 s** and
produces `Application/Dopamine.tipa` (≈53 MB), main executable carrying its 14
entitlements, nested exploit frameworks ad‑hoc signed, `_CodeSignature/CodeResources`
sealed. Ready to sideload / install via TrollStore.

---

## 1. Toolchain

Install once (Homebrew is assumed on `PATH`):

```bash
brew install make ldid dpkg xz coreutils findutils libarchive openssl@3
```

- **GNU make** is required (the Makefiles use GNU‑isms). Use `gmake`, or put
  `"$(brew --prefix make)/libexec/gnubin"` first on `PATH` so `make` == GNU make.
- **`trustcache`** must be on `PATH` (used by `BaseBin` to seal `basebin.tc`).
  Homebrew doesn't ship it; build it from source once:
  ```bash
  git clone https://github.com/CRKatri/trustcache /tmp/trustcache && cd /tmp/trustcache
  export CFLAGS="-I$(brew --prefix openssl@3)/include -arch $(uname -m)"
  export LDFLAGS="-L$(brew --prefix openssl@3)/lib -arch $(uname -m)"
  gmake OPENSSL=1 && sudo cp trustcache /usr/local/bin/
  ```

Verify: `gmake ldid dpkg-deb trustcache xz` all resolve.

## 2. SDKs (Theos)

Theos needs at least one iOS SDK in `$THEOS/sdks` for the tweak sub‑projects
(`opainject`, `rootlesshooks`, `bootstrapfs`, `makerw`, `systemhook`, …). The
C/Objective‑C sub‑projects that use `xcrun --sdk iphoneos --show-sdk-path`
(`ChOma`, `XPF`, `libjailbreak`, `Packages`) build against **Xcode's own iOS SDK**,
not these.

```bash
export THEOS=~/theos
mkdir -p "$THEOS/sdks"
# Theos-provided SDKs:
for v in 14.5 16.5; do
  curl -fL "https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS${v}.sdk.tar.xz" | tar -xJ -C "$THEOS/sdks"
done
```

> `sdk-fix.sh` in this repo downloads and patches an extra `iPhoneOS15.2.sdk`
> from `xybp888/iOS-SDKs` (rewriting `platform: (null)` → `platform: ios` in the
> `.tbd` stubs so `make` doesn't choke). It is **optional** — the build works
> with just 14.5 / 16.5 present — but harmless. Note the script has a typo
> (`-o "ZIP"` should be `-o "$ZIP"`); the CI workflow inlines a correct version.

## 3. Build order

The top‑level `Makefile` runs `BaseBin → Packages → Application`. Bootstraps must
be fetched before the Application step.

```bash
export THEOS=~/theos
export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"

# 1. on-device payloads the app bundles (≈40 MB, not in git)
( cd Application/Dopamine/Resources && ./download_bootstraps.sh )

# 2. everything (this is exactly what CI runs)
gmake -j"$(sysctl -n hw.logicalcpu)" NIGHTLY=1
# → Application/Dopamine.tipa  and  Application/Dopamine.ipa
```

`NIGHTLY=1` just bakes the commit hash into the app; a plain `gmake` also works
for local device testing.

---

## 4. Issues found and fixed

The fork did **not** build as‑is on a current (Xcode 15.0.1 / clang 15) toolchain.
Three fixes were required. All are in‑tree (committed source), so CI picks them up
automatically.

### 4.1 `XPF`: `'xpc/xpc.h' file not found`

`BaseBin/XPF` `#include <xpc/xpc.h>`, but no iOS SDK ≤ 17.2 ships that header.
`BaseBin` bundles a copy in `_external/include/xpc/` and the `.include` target
keeps it (it only deletes the bundled copy when the SDK provides `xpc.modulemap`,
i.e. iOS 17.4+). **But nothing ever put `BaseBin/.include` on XPF's include path.**
Upstream "works" only because a new enough SDK (Xcode 16 / iOS 18 on CI runners)
supplies `xpc/xpc.h` directly.

**Fix** — thread the bundled headers into XPF's compile via an appendable var:
- `BaseBin/XPF/Makefile`: `CFLAGS … $(EXTRA_CFLAGS)`
- `BaseBin/Makefile` XPF rule: `… EXTRA_CFLAGS="-I../.include"`

Robust on both toolchains: old SDK → finds bundled `xpc.h`; new SDK → `.include/xpc`
was removed, so it falls through to the SDK's copy.

### 4.2 `libjailbreak` / `launchdhook`: `call to undeclared function 'audit_token_to_pid'`

Modern clang promotes implicit function declarations to a **hard error** (older
clang only warned — that's why it built for the original author). `audit_token_to_pid`
/ `audit_token_to_euid` were only ever declared in the **bundled** `bsm/audit.h`,
which the `.include` target *deletes* when the SDK ships its own `bsm/audit.h`
(to avoid shadowing the SDK's `Darwin.bsm.audit` Clang module). The SDK's
`bsm/audit.h` does **not** declare those functions, and the "kept" `bsm/libbsm.h`
turned out to be a **truncated copy of `audit.h`** (same `_BSM_AUDIT_H` guard, cut
off before the prototypes) — so it declared nothing and collided with the SDK header.

> Suppressing the warning was rejected on purpose: an implicitly‑declared function
> is assumed to return `int`, which silently truncates 64‑bit/pointer returns — a
> real runtime hazard in a jailbreak. The declarations must be correct.

**Fix**
- Replaced `BaseBin/_external/include/bsm/libbsm.h` with a proper minimal
  `libbsm.h` (correct `_LIBBSM_H_` guard, self‑contained includes, the
  `audit_token_to_*` prototypes actually used). `-lbsm` provides them at link time.
- Added `#include <bsm/libbsm.h>` to the four callers:
  `libjailbreak/src/jbserver_boomerang.c`,
  `launchdhook/src/jbserver/jbdomain_{platform,root,systemwide}.c`.

### 4.3 Application signing: `ldid.cpp(3335): _assert(): flag_S`

`Application/Makefile` signed the built app with `ldid -s <App.app>`. Homebrew
`ldid` (2.1.5) **cannot** ad‑hoc‑sign a *bundle directory* with lowercase `-s`
(it asserts `flag_S`); a bundle requires uppercase `-S`. CI's Procursus `ldid` is
patched and accepts `-s`, which is why upstream CI didn't hit this.

**Fix** — reordered to two `-S` calls (works with *both* ldids, and keeps the
exploit frameworks ad‑hoc, matching upstream output):
```make
ldid -S build/.../Dopamine.app                                   # seal bundle + frameworks (ad-hoc)
ldid -SDopamine/Dopamine.entitlements build/.../Dopamine.app/Dopamine   # entitlements on main exec only
```
A single `ldid -S<ents> <App.app>` also works but stamps the app's entitlements
onto every nested framework (inert on iOS, but not what upstream produces).

### 4.4 Runtime: "Install package manager" does nothing / Sileo never appears

Not a build error — the app compiled and jailbroke fine, but tapping **Install
package manager** (or picking one on first jailbreak) never installed Sileo/Zebra.
Cause: `Application/Dopamine/Jailbreak/DOBootstrapper.m -installPackage:` had its
entire body **commented out** and just `return 0;` — so `installPackageManagers`
looped over the enabled managers and "succeeded" without ever running `dpkg`.

**Fix** — restore the original implementation:
```objc
- (int)installPackage:(NSString *)packagePath {
    if (getuid() == 0)
        return exec_cmd_trusted(JBROOT_PATH("/usr/bin/dpkg"), "-i", packagePath.fileSystemRepresentation, NULL);
    exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "install_pkg", packagePath.fileSystemRepresentation, NULL);
    return 0;
}
```
`reinstallPackageManagers` wraps this in `runAsRoot` (`setuid(0)`), so the
`getuid()==0` branch runs `dpkg -i` on the bundled `sileo.deb` / `zebra.deb`
(shipped in `Application/Dopamine/Resources`, copied into the `.app`). Those debs
install `Sileo.app`/`Zebra.app` under `/var/jb/Applications/` and their `postinst`
runs `uicache`, so the icons appear without any extra call. No BaseBin changes
needed — `jbctl internal install_pkg` already implements the non-root path.

> Incremental-rebuild gotcha: the `.include` target regenerates `xpc/xpc.h` every
> run, which bumps its mtime and invalidates cached clang PCMs, giving
> `fatal error: file '…/.include/xpc/xpc.h' has been modified since the module file
> … was built`. It's stale-cache noise, not a code error — delete the clang
> ModuleCache dirs (`.../C/clang/ModuleCache`, Xcode DerivedData
> `ModuleCache.noindex`) and rebuild. Fresh CI runners never hit it.

### 4.5 Runtime: `/var/jb` missing after every reboot (package managers break)

Even with 4.4, installed package managers / debs still failed because `/var/jb`
was **absent** on the running jailbreak. `/var/jb` is the compatibility symlink
→ the real jbroot (`/private/preboot/<bootManifestHash>/dopamine-XXXXXX/procursus`);
debs ship `/var/jb/...` paths and resolve through it. The core jailbreak works
without it (internally everything uses absolute `JBROOT_PATH`), so the breakage is
silent.

`DOBootstrapper.m` *does* create `/var/jb` (in `prepareBootstrapWithCompletion:`),
but every jailbreak ends in a userspace reboot, and `BaseBin/jbctl/src/main.m`'s
`reboot_userspace` command **`unlink()`ed `/var/jb` immediately before rebooting
and never recreated it** (a half-finished "delete stale symlink" idea — the
recreate on the far side was missing). Net result: `/var/jb` is gone on every
booted jailbreak. Confirmed on-device via timestamps (jbroot created 14:22,
`/var/jb` never present until hand-made) and the tell-tale `OK: /var/jb unlinked`
string in the deployed `jbctl`.

**Fix** — `reboot_userspace` now *recreates* the symlink pointing at the current
jbroot instead of only deleting it (jbctl already populates `rootPath` from
`jbclient_get_jbroot()` at startup, so `get_jbroot()` is valid here):
```c
const char *jbroot = get_jbroot();
unlink("/var/jb");
if (jbroot && jbroot[0]) symlink(jbroot, "/var/jb");
return reboot3(RB2_USERREBOOT);
```
Bonus: the in-app **Reboot Userspace** button used the same path, so it was also
silently destroying `/var/jb` on every press — now fixed too. This is a BaseBin
change, so it only reaches the device after installing the rebuilt `.tipa` **and**
re-jailbreaking once (that re-extracts `basebin.tar`, regenerating the trustcache
so the new `jbctl` is allowed to run).

---

## 5. GitHub Actions (`build.yml`) — what works / what to watch

The workflow mirrors the local steps: pin Xcode → checkout → Procursus toolchain
(`ldid dpkg …`) → Homebrew `make libarchive openssl@3` → build `trustcache` →
download bootstraps → `gmake NIGHTLY=1` → upload `.tipa`/`.ipa`.

**Validated locally** (identical commands): the whole `gmake NIGHTLY=1` flow, on
Xcode 15.0.1 / iOS 17.0 SDK.

**Runner / Xcode choice (important):**
- Set to **`runs-on: macos-14`** + **`xcode-version: '15.2'`**.
- Rationale: the app target only builds on Xcode **14–15** (README). `macos-15`
  images ship **only Xcode 16.x**, which is *untested* here and the single most
  likely thing to break the `xcodebuild` step (the user already saw "Xcode too
  new" fail on macOS Tahoe). `macos-14` carries Xcode 15.0.1–15.4.
- Xcode **15.2** was chosen because its iOS **17.2** SDK has *no* `xpc.modulemap`
  and *does* ship `bsm/audit.h` — i.e. it exercises the **same header code paths**
  proven locally (bundled `xpc.h`; the `libbsm.h` fix). Any 15.0.1 … 15.4 works.
  **Do not use 16.x** without re‑testing the app build.

**Things that are fine as‑is:**
- `submodules: recursive` on checkout is a harmless no‑op — this fork vendors
  ChOma / XPF / opainject / litehook / kfd as **regular files**, not real git
  submodules (there are no gitlink entries), so nothing is fetched. The stale
  `.gitmodules` (its `kfd` path `Application/Dopamine/Dopamine/Exploits/kfd/kfd`
  is wrong/non‑existent; the real path is `Application/Dopamine/Exploits/kfd`) is
  ignored by `git submodule update`.
- The Theos SDK download (14.5 / 16.5 / patched 15.2) is needed so the Theos tweak
  targets have an SDK; the `xcrun`‑based sub‑projects use Xcode's SDK.

**Harmless warnings** you'll see (present upstream, not errors):
- `ld: warning: search path '.../../Exploits' not found`
- `DOGlobalAppearance.m: method definition for 'windowColorWithAlpha:' not found`
- theos: `Building for iOS 11.0, but … can't produce arm64e … earlier than 14.0`

**Not verifiable from here:** an actual GitHub Actions run. The logic and every
build command are validated locally; the only CI‑specific unknown is the exact
Xcode image contents on the runner. If `setup-xcode` can't find `15.2`, bump to
another installed 15.x (it prints the available list on failure).
