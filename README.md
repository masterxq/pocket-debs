# pocket-debs

Debian packages with patches for phones running mainline Linux (Debian/Mobian). Each package is the Debian source
package of the target suite plus a few patches, built for arm64 as `<debian version>+pd<n>`. The first device is
the Motorola Moto G60s ("lisbon"); device specific parts keep the device name (e.g. the `lisbonfpc` driver).

| Source | What the patches change | Why |
|---|---|---|
| callaudiod | EnableSpeaker selects the voice call profile with the speaker port | with one sink per UCM device the earpiece sink has no speaker port, the speaker button of the call UI did nothing |
| libfprint | adds the driver `lisbonfpc` (Moto G60s) | fingerprint sensor of the phone, reached through a local bridge service to the TEE |
| libcamera | sensor helpers and properties for OV64B40 and OV16A1Q; simple IPA AGC with tunable step size and frame length extension; MediaTek MT6785 ISP (DIP) as debayer backend of the software ISP, contrast autofocus, zone metering and AWB along a colour temperature curve | correct gain, black level and delays for the Moto G60s cameras with the software ISP; exposure control that settles quickly and reaches indoor brightness; hardware image processing for the main camera when the DIP driver is present (`software_isp.mode: mtk-dip`), software ISP otherwise |
| kf6-kirigami | upstream fix 0810418b (KDE bug 523866, in KF 6.31); a build-only CMake lookup order change | rapid taps in ColumnView pages got lost; the lookup change works around cmake sporadically missing Qt6QmlIntegration under qemu-user |
| gtk4 | upstream fix d4fa0b3b (GTK issue 8456): the GStreamer media backend marks the EGL display as foreign on Wayland | GStreamer terminated the EGL display GTK renders with when the first GtkMediaFile was released; GNOME Snapshot crashed on the second picture (shutter sound) |
| mesa | panfrost: mark a BO shared when its KMS handle is exported (draft) | an exported buffer must not be recycled from the BO cache (not tested on a device yet) |

Layout per source package: `<source>/paket.conf` (Debian version, `.dsc` checksum, `REVISION`, status, binary
packages a rootfs installs), `<source>/patches/*.patch` in DEP-3 format, applied in name order and appended to
`debian/patches/series` as `debian/patches/pocket-debs/*`, so the resulting source package carries them.
`<source>/dateien/` holds additional files as a tree relative to the source root (e.g.
`libfprint/dateien/libfprint/drivers/lisbonfpc.c`); they become the patch `0000-pocket-debs-files.patch`. Changes to the
packaging itself that quilt cannot carry go to `<source>/debian-patches/*.patch` (applied to `debian/` before the
build); `FEHLT_ERLAUBT` in `paket.conf` names files that are then missing on purpose compared with Debian. Patches
in `patches/aus/` are prepared but not applied. Every patch is under the license of the files it changes (named in
its header). `STATUS=entwurf` marks drafts, which are only built on request.

## Build locally

Needs Docker; on an amd64 host additionally qemu-user binfmt for arm64, on an arm64 host the build runs natively.
One entry point, non-interactive (comments and messages of the scripts are in German):

    ./bau.sh bau <source...>|alle|image [--neu]   # build into the APT repository under $PAKETE_OUT (default out/)
    ./bau.sh pruefen          # compares our base version with the Debian suite, exit 3 if Debian is newer
    ./bau.sh liste            # packages, versions, state in the repository
    ./bau.sh schluessel <source>   # input key of a package and what goes into it

`alle` = all packages with `STATUS=aktiv`, `image` = those with `IMAGE_AN=1`. Each build fetches the Debian source
package (the `.dsc` is checked against `DSC_SHA256` in `paket.conf`, all other files against the `.dsc`), applies
the patches without fuzz, builds in a throwaway `debian:<suite>` container for linux/arm64, compares every binary
package with Debian's package of the same base version (file list without `usr/share/doc`, dependency names;
anything missing fails the build, so a dependency that the build silently did not find cannot drop a feature) and
adds source and binaries to a reprepro repository (`$PAKETE_OUT/repo`).

A build is skipped when the repository already holds the package built from the same inputs; `--neu` forces it.
The input key hashes the suite, mirror and snapshot, `pakete.conf`, `Dockerfile`, `bau-innen.sh`, the package's
`paket.conf`, `patches/*.patch` and `dateien/`. It depends only on files in this repository, so it is the same on
every machine and in CI. Not part of the key: `bau.sh` itself, the state of the build image and of the build
dependencies in the mirror at build time (pinned only with `SNAPSHOT` in `pakete.conf`); build with `--neu` after
changing those.

## CI (GitHub Actions)

`.github/workflows/bau.yml` builds natively on the `ubuntu-24.04-arm` runner, on every push to `main`, on pull
requests, weekly and on request (Actions, "Run workflow": extra packages such as `mesa`, or a rebuild without
cache).

- **Only changed packages are built.** A plan job computes the input key of every active package. The result of
  each build is stored in the Actions cache under `paket-<source>-<key>`; a package whose key is cached is restored
  instead of built. A change to a shared file (`pakete.conf`, `Dockerfile`, `bau-innen.sh`) changes every key and
  rebuilds everything; a change below `<source>/` rebuilds that package only.
- **Every run carries all packages.** Each run uploads one artifact per package, named `<source>_<version>`
  (`.deb` files, source package, `STAND` with version and key, `BUILDINFO`, `SHA256SUMS`, patch and comparison
  results), and `apt-repo` with the complete repository (`dists/`, `pool/`, `stand/`).
- **Compiler cache.** Builds run through ccache. Locally the cache lives in `$PAKETE_OUT/ccache/<source>/`
  (`PAKETE_CCACHE=0` builds without it, `PAKETE_CCACHE_MAX` caps it per package, default 2G); in CI each built
  package restores the newest `ccache-<source>-*` entry and saves the updated one, so rebuilding the same package
  after a patch change mostly hits the cache. A hit yields the same object file as the compiler, so the cache is not
  part of the input key. `BUILDINFO` records the hit rate (`ccache_treffer`).
- **Expiry.** Cache entries unused for 7 days and artifacts after 90 days (`apt-repo` after 30) are deleted by
  GitHub. The weekly run keeps the cache in use. A missing cache entry simply means the package is built again.

Fetch the CI results instead of building (needs an authenticated GitHub CLI `gh`):

    ./bau.sh holen <source...>|alle|image   # newest unexpired artifact from main, checks SHA256SUMS and the key

`holen` refuses an artifact whose key differs from the local recipe (local changes, or CI has not built this state
yet; `--trotzdem` takes it anyway) and puts it into `$PAKETE_OUT/repo` like a local build, so a following
`./bau.sh bau` skips it. If no artifact is left, start a CI run or build locally.

This repository was developed with heavy AI assistance; review and release on the device are done by a human.
