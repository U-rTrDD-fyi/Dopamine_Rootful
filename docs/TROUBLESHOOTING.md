# Troubleshooting

Runtime failure modes found on real hardware, with the evidence that identified
each one. All of these are fixed in this branch; they are documented because
the symptoms are misleading and worth recognising if they resurface.

The common thread: **every one of them reported success while doing nothing.**
When something here is wrong, nothing errors — it just quietly fails.

## No tweaks load at all

*Symptom:* tweaks install fine, `TweakInject` contains them, nothing is injected
into any process. Affects rootless tweaks too, not just legacy ones.

`systemhook` hardcoded `/usr/lib/TweakLoader.dylib`. That path can never exist:
`/usr/lib` is the `bootstrapfs` volume seeded from `basebin/.fakelib`, which
holds only dyld/libSystem stubs. The `access()` check failed on every process
spawn and the loader was never dlopened.

```bash
# nothing at all before the fix:
DYLD_PRINT_LIBRARIES=1 /var/jb/usr/bin/id 2>&1 | grep -i "ellekit\|tweak"
```

Fixed by loading via `JBROOT_PATH`. Upstream and roothide both do this — the
hardcoded path was a regression.

## "Install package manager" does nothing

`DOBootstrapper -installPackage:` had its entire body commented out with a bare
`return 0;`, so every install "succeeded" without running dpkg.

```bash
# the built binary should contain these:
strings -a Dopamine.app/Dopamine | grep -E "install_pkg|/usr/bin/dpkg"
```

## `/var/jb` missing after every reboot

*Symptom:* the jailbreak works, but anything shipping `/var/jb` paths breaks.

`jbctl reboot_userspace` called `unlink("/var/jb")` immediately before
`reboot3()` and never recreated it. Every jailbreak ends in a userspace reboot,
so `/var/jb` was always destroyed. The in-app "Reboot Userspace" button hit the
same path.

The core jailbreak was unaffected because it uses absolute `JBROOT_PATH`
internally, which is exactly why this went unnoticed.

```bash
readlink /var/jb    # should print the jbroot path
```

## A legacy tweak installs but never loads

Work through the checklist in [LEGACY-TWEAKS.md](LEGACY-TWEAKS.md). In order of
how often it was the cause:

1. **SHA-1 signature.** `codesign -dvvv --arch arm64 x.dylib | grep "Hash type"`
   — if it says `sha1`, iOS 15 cannot validate it. `ldid -Hsha256 -S` fixes it.
   Sileo now does this automatically.
2. **Missing CydiaSubstrate bridge.** `otool -L` shows
   `/Library/Frameworks/CydiaSubstrate.framework/...`; if that path does not
   resolve, dlopen fails silently.
3. **Broken tweak directory bridge.** `ls -ld
   /Library/MobileSubstrate/DynamicLibraries` — if it is a real directory rather
   than a symlink, the tweaks inside it are invisible to ellekit.

## Sileo: "Install Identifier Mismatch"

Upstream Sileo bug with foreign-arch packages. APT reports
`name:iphoneos-arm`; Sileo looks it up by bare identifier, misses, and throws
before dpkg runs. Fixed in the bundled build.

Confirm what APT actually emits:

```bash
apt-get -sqf -oAPT::Format::JSON=true install --reinstall <pkg> | tail -1
```

## Build: "file has been modified since the module file was built"

Local incremental builds only. The `.include` target regenerates `xpc/xpc.h`
each run, invalidating cached clang modules.

```bash
rm -rf "$(getconf DARWIN_USER_CACHE_DIR)/clang/ModuleCache"/*
```

Fresh CI runners never hit this.

## Deployed BaseBin changes appear to do nothing

BaseBin binaries must be in the trustcache to execute. A freshly built `jbctl`
cannot be copied onto a device and run — AMFI blocks it.

Install the rebuilt `.tipa` **and re-jailbreak once**, so `basebin.tar` is
re-extracted and the trustcache regenerated.

## Debugging on device

```bash
iproxy 2222 2222 &        # then ssh to localhost:2222
lsof -p $(pgrep SpringBoard) | grep -i TweakInject   # what is injected
jbctl trustcache info                                # what is trusted
mount | grep -E "disk0s1s(8|9|10|11|12|13)"          # bootstrapfs volumes
dpkg --print-foreign-architectures                   # should list iphoneos-arm
```

`lsof` is not installed by default: `apt-get install lsof`.
