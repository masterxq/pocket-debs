# lisbon-pakete

Debian packages with patches for the Motorola Moto G60s ("lisbon", Mobian on mainline Linux). Each package is the
Debian source package of the target suite plus a few patches, built for arm64 as `<debian version>+lisbon<n>`.

| Source | What the patches change | Why |
|---|---|---|
| libfprint | adds the driver `lisbonfpc` | fingerprint sensor of the phone, reached through a local bridge service to the TEE |
| libcamera | sensor helpers and properties for OV64B40 and OV16A1Q | correct gain, black level and delays for the phone cameras with the software ISP |
| kf6-kirigami | upstream fix 0810418b (KDE bug 523866, in KF 6.31) | rapid taps in ColumnView pages got lost |
| mesa | panfrost: mark a BO shared when its KMS handle is exported (draft) | an exported buffer must not be recycled from the BO cache |

Patches are in `<source>/patches/` in DEP-3 format and are appended to `debian/patches/series` (as
`debian/patches/lisbon/*`), so the resulting source package carries them. Patches in `patches/aus/` are prepared
but not applied. Every patch is under the license of the files it changes (named in its header).

## Build

Needs Docker with qemu-user binfmt for arm64. One entry point, non-interactive:

    ./bau.sh bau <source...>|alle|image [--neu]
    ./bau.sh pruefen          # compares our base version with the Debian suite, exit 3 if Debian is newer
    ./bau.sh liste

Each build fetches the Debian source package (the `.dsc` is checked against `DSC_SHA256` in `paket.conf`, all other
files against the `.dsc`), applies the patches without fuzz, builds in a throwaway `debian:<suite>` container for
linux/arm64 and adds source and binaries to a reprepro repository (`$PAKETE_OUT/repo`). A build is skipped when the
repository already holds the package built from the same inputs (suite, build image, recipe, patches, extra
files); `--neu` forces it.
