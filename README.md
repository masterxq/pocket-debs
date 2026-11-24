# pocket-debs

Debian packages with patches for phones running mainline Linux (Debian/Mobian). Each package is the Debian source
package of the target suite plus a few patches, built for arm64 as `<debian version>+pd<n>`. The first device is
the Motorola Moto G60s ("lisbon"); device specific parts keep the device name (e.g. the `lisbonfpc` driver).

| Source | What the patches change | Why |
|---|---|---|
| callaudiod | EnableSpeaker selects the voice call profile with the speaker port, only while a call is active; the call is tracked also when WirePlumber does the routing (speaker off and microphone unmuted after a call) | with one sink per UCM device the earpiece sink has no speaker port, the speaker button of the call UI did nothing; a speaker-off request at the end of a call brought the voice call profile back and the card stayed in it, the speaker setting carried over into the next call |
| libfprint | adds the driver `lisbonfpc` (Moto G60s) | fingerprint sensor of the phone, reached through a local bridge service to the TEE |
| libcamera | sensor helpers and properties for OV64B40 and OV16A1Q; simple IPA AGC with tunable step size and frame length extension; MediaTek MT6785 ISP (DIP) as debayer backend of the software ISP, contrast autofocus, zone metering and AWB along a colour temperature curve | correct gain, black level and delays for the Moto G60s cameras with the software ISP; exposure control that settles quickly and reaches indoor brightness; hardware image processing for the main camera when the DIP driver is present (`software_isp.mode: mtk-dip`), software ISP otherwise |
| gtk4 | upstream fix d4fa0b3b (GTK issue 8456): the GStreamer media backend marks the EGL display as foreign on Wayland | GStreamer terminated the EGL display GTK renders with when the first GtkMediaFile was released; GNOME Snapshot crashed on the second picture (shutter sound) |
| gst-plugins-bad1.0 | v4l2codecs: the H.264 decoder waits for the second field of a pair before it outputs the picture; the MPEG-2 decoder builds the quantisation matrices of every picture from the sequence header and the quant matrix extensions. codecs: the MPEG-2 base class keeps matrices of earlier quant matrix extensions | with a V4L2 stateless decoder the last field pair of a stream could be output while its second field was still being decoded; MPEG-2 streams that repeat an unchanged sequence header after a quant matrix extension were dequantised with stale matrices |
| firefox-esr | RDD sandbox: the broker admits a `/dev/media*` node whose topology holds an admitted M2M video node (plus its sysfs uevent); seccomp allows only the four Request API media ioctls (Mozilla bug 2080696, backported) | V4L2 stateless decoders used through VA-API (libva-v4l2-request) need the media controller; without it Firefox decodes in software unless its media sandbox is switched off |
| mesa | panfrost: mark a BO shared when its KMS handle is exported; fix MTK 16L32S detiling before Valhall | an exported buffer must not be recycled from the BO cache; MM21 frames of MediaTek video decoders came out mostly black on Mali-G76 (not tested on a device yet) |
| rust-gst-plugin-gtk4 | upstream fix d346b181 (gst-plugins-rs MR 3429): gtk4paintablesink passes the stride of tiled dmabufs in bytes | the sink handed GTK the tile counts of the video meta as row pitch; MM21 frames of MediaTek video decoders were garbled in every GTK 4 player using the sink (GNOME Showtime) |

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
- **Test builds.** In a pull request and on other branches than `main` a package that is built gets the version
  `<debian version>+pd<n>~test.<commit>` (`PAKETE_TEST`). It sorts before the version `main` builds later, so apt
  replaces a test build on a device once the build of `main` is in the APT repository. A package the pull request
  does not change comes from the cache and keeps the version of `main`.
- **Compiler cache.** Builds run through ccache. Locally the cache lives in `$PAKETE_OUT/ccache/<source>/`
  (`PAKETE_CCACHE=0` builds without it, `PAKETE_CCACHE_MAX` caps it per package, default 2G); in CI each built
  package restores the newest `ccache-<source>-*` entry and saves the updated one, so rebuilding the same package
  after a patch change mostly hits the cache. A hit yields the same object file as the compiler, so the cache is not
  part of the input key. `BUILDINFO` records the hit rate (`ccache_treffer`).
- **Expiry.** Cache entries unused for 7 days and artifacts after 90 days (`apt-repo` after 30) are deleted by
  GitHub. The weekly run keeps the cache in use. A missing cache entry simply means the package is built again.

### Following Debian

`.github/workflows/nachziehen.yml` runs once a week (and on request). For every active package whose Debian version
in the suite is newer than the base of the recipe it runs `./bau.sh nachziehen <source> --uebernehmen` and builds the
result. If the patches apply and the build succeeds, the changed recipe (`DEBIAN`, `DSC_SHA256`, `REVISION=1`,
refreshed patches) is committed to `main` and the workflow `bau` is started; it finds the build in the cache and
publishes it. If not, `main` and the published version stay as they are and an issue `nachziehen: <source> <debian
version>` is opened, once per Debian version; the run that later moves the package closes it. A second kind of issue
reports a patch that was dropped because Debian already contains the change: then the package may no longer be
needed. Drafts are not moved. "Run workflow" with `probe` tries everything without the commit and without issues.

Fetch the CI results instead of building (needs an authenticated GitHub CLI `gh`):

    ./bau.sh holen <source...>|alle|image   # newest unexpired artifact from main, checks SHA256SUMS and the key

`holen` refuses an artifact whose key differs from the local recipe (local changes, or CI has not built this state
yet; `--trotzdem` takes it anyway) and puts it into `$PAKETE_OUT/repo` like a local build, so a following
`./bau.sh bau` skips it. If no artifact is left, start a CI run or build locally.

## APT repository

Every run on `main` publishes its packages to the public APT registry of the organisation
[moblix on Codeberg](https://codeberg.org/moblix/-/packages), suite `testing`, component `main` (runs for pull
requests and runs with additional draft packages do not publish; debug symbol, test and example packages such as
`gtk-4-tests` are left out, see `REG_OHNE` in `registry.sh`). A version
that is already there is not replaced, so a changed package needs a new `REVISION`. As in the Debian archive the
registry holds one version per package: after publishing, `registry.sh aufraeumen` removes older versions of the
source packages of this repository and binary packages a source no longer builds. Packages that other repositories
publish to the same registry are not touched.
A source package that is removed from this repository altogether is removed from the registry by hand:
`./registry.sh entfernen <folder> <source>` (the folder holds the packages of a current run, for the index).
Forgejo rebuilds the index only on upload, so after removing packages the script removes and uploads again the
smallest package of the run for each affected architecture; otherwise the index would keep listing removed files.

Publishing is the reusable workflow `.github/workflows/registry.yml`. A fork that builds its own Debian package
(e.g. `omacam`) calls it from its workflow for pushes to its main branch, so its package reaches the registry without
a build in this repository; the cleanup then keeps one version of that package as well. The header of the workflow
shows the call.

Codeberg signs the index (`InRelease`) with the key of the registry; apt verifies it and, through the checksums in
the index, every package. The packages themselves carry no signature (as in Debian). `registry.sh pruefen` checks
in every run that the signed index describes exactly the files this run built, and warns when the registry holds a
different build of the same version (for example after a rebuild without the cache).

    sudo curl -o /etc/apt/keyrings/forgejo-moblix.asc https://codeberg.org/api/packages/moblix/debian/repository.key
    echo "deb [signed-by=/etc/apt/keyrings/forgejo-moblix.asc] https://codeberg.org/api/packages/moblix/debian testing main" \
        | sudo tee /etc/apt/sources.list.d/moblix.list

The packages are built against Debian `forky` and are test builds for development, not a stable release.

## License

The build scripts, the workflow and the documentation of this repository are under the GNU General Public License,
version 3 or (at your option) any later version, see `LICENSE`. Every patch and every file under `<source>/dateien/`
is under the license of the source package it changes (named in its header).

This repository was developed with heavy AI assistance; review and release on the device are done by a human.
