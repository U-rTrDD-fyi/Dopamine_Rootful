# How this jailbreak actually works

This fork is *rootful* in the privilege sense, but it is not laid out the way
pre-rootless jailbreaks were, and it is not laid out the way upstream Dopamine
is either. That middle ground is the single biggest source of confusion when
reading the code, so it is worth being precise about.

## The jbroot

The bootstrap is Procursus' **rootless** `bootstrap-iphoneos-arm64.tar.zst`,
extracted to a randomly named directory under the preboot volume:

```
/private/preboot/<bootManifestHash>/dopamine-XXXXXX/procursus
```

`bootManifestHash` comes from the IORegistry (`IODeviceTree:/chosen`,
property `boot-manifest-hash`). `XXXXXX` is six random characters, so the path
differs between installs. Nothing should ever hardcode it.

In C, reach it through `JBROOT_PATH(...)`, which prepends `get_jbroot()`
(`BaseBin/libjailbreak/src/jbroot.c`). In Objective-C, `JBROOT_PATH_NSSTRING`.

`/var/jb` is a **symlink to that directory**. It exists purely for
compatibility: debs ship `/var/jb/...` paths and resolve through it. The
jailbreak itself never depends on it, which is why the jailbreak kept working
for a long time while `/var/jb` was silently missing — see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## What makes it rootful: bootstrapfs

`jbctl internal` runs `bootstrapfs create` for six paths
(`BaseBin/jbctl/src/internal.m`):

```
/usr  /Library  /Applications  /private/etc  /sbin  /bin
```

Each becomes a **real, writable APFS volume** mounted over the sealed system
path, seeded with a copy of the original contents. On device:

```
/dev/disk0s1s8  on /usr           /dev/disk0s1s11 on /private/etc
/dev/disk0s1s9  on /Library       /dev/disk0s1s12 on /sbin
/dev/disk0s1s10 on /Applications  /dev/disk0s1s13 on /bin
```

This is what makes genuine rootful installs possible: a package writing to
`/Library/MobileSubstrate/DynamicLibraries` lands on real, persistent storage,
not a tmpfs and not the jbroot.

This machinery comes from [ghh-jb](https://github.com/ghh-jb) — `bootstrapfs`,
`APFSRW`, `Makerw`, `Fugu15_Rootful`.

`Makerw` is the alternative tmpfs-overlay approach. It is vendored but
**disabled**; the code is commented out in `jbctl/src/internal.m` because the
APFS volumes superseded it.

## The `/usr/lib` trap

This one has bitten us more than once, so read it carefully.

`basebin/.fakelib` is bind-mounted read-only over `/usr/lib` to supply the
patched `dyld` and `systemhook.dylib`. But `bootstrapfs` mounts the `/usr`
volume *afterwards*, which **shadows that bind mount**. The mount table still
lists it, and it looks read-only:

```
.../basebin/.fakelib on /usr/lib (bindfs, local, nosuid, read-only, nobrowse)
/dev/disk0s1s8      on /usr      (apfs,   local, nosuid, journaled, noatime)
```

The practical consequences:

- `/usr/lib` **is writable**, despite what `mount` says. Writes go to the `/usr`
  APFS volume, *not* to `.fakelib`.
- Its contents are a **copy** of `.fakelib` taken when the volume was created.
  The `dyld` and `systemhook.dylib` entries are absolute symlinks into the
  jbroot, so they still resolve.
- `upstream`'s `setFakelibMounted:` is meaningless here, which is why this fork
  removed it. `isFakelibMounted` would always return false.

**Never assume a path under `/usr/lib` is read-only, and never assume writing
there updates `.fakelib`.**

## Tweak injection

`systemhook` is injected into every process. If tweaks are enabled (no
`basebin/.safe_mode`), it dlopens the tweak loader, which is ellekit's
`TweakLoader.dylib` inside the jbroot. ellekit then scans
`<jbroot>/usr/lib/TweakInject/` for `.dylib` + `.plist` pairs.

The loader path **must** go through `JBROOT_PATH`. Hardcoding `/usr/lib` breaks
all injection, because of the shadowing described above.

For legacy tweaks, `/Library/MobileSubstrate/DynamicLibraries` is a symlink into
`TweakInject`, so both worlds land in the directory ellekit already scans. See
[LEGACY-TWEAKS.md](LEGACY-TWEAKS.md).

## Code signing and the trustcache

AMFI will not load a dylib whose cdhash it does not trust. The jailbreak keeps
its own trustcache (`jbctl trustcache info` to inspect) and adds cdhashes as
binaries appear.

Two requirements that are easy to miss:

- The signature must be **SHA-256**. Binaries signed SHA-1 only
  (`CodeDirectory v=20001`, typical of pre-2017 tweaks) cannot be validated by
  iOS 15 at all. `ldid -Hsha256 -S` fixes them.
- Freshly built BaseBin binaries are only trusted after `basebin.tar` is
  re-extracted and the trustcache regenerated. You cannot `scp` a new `jbctl`
  onto a device and run it — install the rebuilt `.tipa` and re-jailbreak once.

## Userspace reboot

`jbctl reboot_userspace` calls `reboot3(RB2_USERREBOOT)`. It must refresh the
`/var/jb` symlink first; a previous version deleted it without recreating it,
which left every booted jailbreak with no `/var/jb`.

## Rootless path rebasing

`BaseBin/rootlesshooks/` keeps the rootless illusion working for system
daemons: `installd` redirects `/Applications` to `/var/jb/Applications`, `lsd`
and `SpringBoard` rebase paths through `JBROOT_PATH`, and `cfprefsd` redirects
preference plists into the jbroot.
