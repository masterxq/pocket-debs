# pocket-debs

Debian packages with patches for phones running mainline Linux (Debian/Mobian). Each package is the Debian source
package of the target suite plus a few patches, built for arm64 as `<debian version>+pd<n>`. The first device is
the Motorola Moto G60s ("lisbon"); device specific parts keep the device name (e.g. the `lisbonfpc` driver).

| Source | What the patches change | Why |
|---|---|---|
| callaudiod | EnableSpeaker selects the voice call profile with the speaker port, only while a call is active; the call is tracked also when WirePlumber does the routing (speaker off and microphone unmuted after a call); the microphone state follows the source of the card and reads as unknown until the card has been seen; a mute request during a profile switch applies to the next source | with one sink per UCM device the earpiece sink has no speaker port, the speaker button of the call UI did nothing; a speaker-off request at the end of a call brought the voice call profile back and the card stayed in it, the speaker setting carried over into the next call; right after it started, callaudiod reported the microphone as off, and an unmute request was skipped when another client had muted the source |
| dolphin | a touch press held on the background of the view opens the context menu of the view when it is released without dragging a rubber band | the actions for the folder itself (Paste, Create New, ...) could not be reached by touch; on a phone copied files could not be pasted |
| libfprint | adds the driver `lisbonfpc` (Moto G60s); a running identification continues across system sleep | fingerprint sensor of the phone, reached through a local bridge service to the TEE; a touch can wake and unlock the phone |
| libcamera | sensor helpers and properties for OV64B40 and OV16A1Q; simple IPA AGC with tunable step size and frame length extension; MediaTek MT6785 ISP (DIP) as debayer backend of the software ISP, contrast autofocus, zone metering and AWB along a colour temperature curve | correct gain, black level and delays for the Moto G60s cameras with the software ISP; exposure control that settles quickly and reaches indoor brightness; hardware image processing for the main camera when the DIP driver is present (`software_isp.mode: mtk-dip`), software ISP otherwise |
| gtk4 | upstream fix d4fa0b3b (GTK issue 8456): the GStreamer media backend marks the EGL display as foreign on Wayland | GStreamer terminated the EGL display GTK renders with when the first GtkMediaFile was released; GNOME Snapshot crashed on the second picture (shutter sound) |
| gst-plugins-bad1.0 | v4l2codecs: the H.264 decoder waits for the second field of a pair before it outputs the picture; the MPEG-2 decoder builds the quantisation matrices of every picture from the sequence header and the quant matrix extensions. codecs: the MPEG-2 base class keeps matrices of earlier quant matrix extensions | with a V4L2 stateless decoder the last field pair of a stream could be output while its second field was still being decoded; MPEG-2 streams that repeat an unchanged sequence header after a quant matrix extension were dequantised with stale matrices |
| firefox-esr | RDD sandbox: the broker admits a `/dev/media*` node whose topology holds an admitted M2M video node (plus its sysfs uevent); seccomp allows only the four Request API media ioctls (Mozilla bug 2080696, backported) | V4L2 stateless decoders used through VA-API (libva-v4l2-request) need the media controller; without it Firefox decodes in software unless its media sandbox is switched off |
| kwin | upstream fix 0f3aee69 (KDE bug 459136): the on-screen keyboard is hidden as soon as the input method is deactivated; a resize back to the committed size is sent to the client while a configure event with another size is still pending; fullscreen and maximized windows keep the geometry KWin requested instead of an interim size the client committed; Wayland protocols for a system-wide back ([back navigation](docs/back-navigation.md)): applications report per window whether back has an effect and receive back, the shell reads that state and asks for back | a window shrunk for the on-screen keyboard kept the reduced height when the application ended the text input itself (Firefox, tapping outside the text field); after rotating the screen a fullscreen or maximized window could stay at a partial size; there was no way for a shell to offer one back control for all applications |
| kf6-kirigami | system-wide back navigation (overview: [docs/back-navigation.md](docs/back-navigation.md)): each window tells the compositor through the Wayland protocol `kde_back_navigation_v1` whether back currently has an effect and goes back one step on its back event: the topmost open popup is closed as by Escape, then GlobalDrawer submenus, PageRow layers and columns; new attached type `Kirigami.BackNavigation` for items with their own navigation. `PageRow.goBack()` accepts the event when a page handles back and stops at the topmost layer; `ApplicationItem` no longer quits the application from `goBack()` | one back control in the navigation bar of the phone shell for all Kirigami applications, shown instead of the close button only while back does something; without the protocol (other compositors, X11) nothing changes. The back button of a page header in an `ApplicationItem` could quit the application on a phone |
| mesa | Debian's 26.3 source package from experimental, built for the suite. panfrost: mark a BO shared when its KMS handle is exported; fix MTK 16L32S detiling before Valhall. PanVK on Mali-G76 (Bifrost v7, job manager): enabled for the MT6785 without the opt-in, an address space per VkDevice, queue priorities, fixes for textureQueryLod, MIRRORED_REPEAT texel offsets, cube storage image bounds, rectangular lines and several draw cases, fewer job chain switches for indexed and indirect draws and occlusion queries (patches from [mesa-lisbon](https://github.com/masterxq/mesa-lisbon)) | an exported buffer must not be recycled from the BO cache; MM21 frames of MediaTek video decoders came out mostly black on Mali-G76; a Vulkan driver for the Moto G60s from the same Mesa version as OpenGL |
| plasma-dialer | default SIM for calls (shared with the cellular network settings); with several SIMs the call button carries the icon of the default SIM and a smaller second call button calls through the other SIM (a choice with three and more SIMs); call back from the history through the SIM of the call; USSD through the default SIM; the call screen shows the SIM of the call; the modem daemon connects to each modem once and finds a call on the modem that has it. Independent of the SIM choice: a view to add and edit a contact (photo, name, numbers; opened from the dial pad, the contacts and the history), an edit and a call button for each contact, history entries with the photo of the contact and the direction of the call, call back with one tap; contacts of a number are looked up in the daemon. The daemon follows the microphone and speaker state of callaudiod instead of sending the state it read back as a request. German translation of the new strings | with more than one modem the dialer chose no modem: dialling, USSD and the controls of the call screen did nothing on dual SIM phones with one ModemManager modem per SIM; after ModemManager restarted, the modem daemon announced each call once for every earlier appearance of the modems; a number could not be saved as a contact from the dialer, and contacts and history entries could only fill the dial pad; the daemon muted the microphone at every login, so the other side of the next call heard nothing |
| plasma-mobile | the status bar has one indicator per connection: the signal of every SIM, Wi-Fi, the hotspot, airplane mode; the icons are the ones of the plasma-nm connection icon (the SIM with mobile data with the letter of its network type, VPN and limited connectivity variants); the letter of the network type and the Wi-Fi icon pulse a few steps per second while the connection is activated (in red after a minute) and show a red cross after a failed activation; no generic internet icon and no busy indicator; the mobile data quick setting and the initial setup follow the modem chosen for mobile data; APN autodetection binds connections to their SIM and starts none by itself with several modems; German translation of the new strings; upstream fixes ce647d80 and 0f35c4af: the labels of the quick settings scroll only while the action drawer shows them; the lock screen shows hints and errors of the fingerprint reader and vibrates on a rejected finger; the navigation bar shows a back arrow instead of the close button while the active window can go back, tapping it goes back in that window ([back navigation](docs/back-navigation.md)) | the shell showed and switched only the first modem; with two SIMs mobile data was started on both; while any connection was activated, a busy indicator replaced the Wi-Fi icon, without telling which connection it stood for; a quick setting label too long for its tile kept scrolling in the closed drawer, on a timer of the shell that shaped the text again on every step; the lock screen ignored all messages of the fingerprint authenticator; the navigation bar had no back button, the back controls of the applications sat at the top of the screen |
| plasma-nm | cellular library: SIM name after the SIM slot (`SimSlots`/`PrimarySimSlot`), one icon per SIM (ICCID) shared with plasma-mobile, plasma-dialer and spacebar (`simidentitiesrc`), the modem for mobile data kept as autoconnect on a connection bound to the SIM (`gsm.sim-id`); the SIM for calls and text messages shared with plasma-dialer and spacebar; settings: choice of the SIM for mobile data, of the SIM for calls and messages and of the icon of each SIM; the chosen SIM stays shown while mobile data moves to it, a connection with the detected APN is added when the SIM has none, errors of every modem are shown; the operator name comes from the mobile broadband provider database when the network sends none (in the home country of the SIM the provider of the SIM, since virtual operators share network codes); the mobile data switch no longer ignores the tap after a change; the state of the Wi-Fi connection and of the mobile data connection of each modem (connected, activating, failed until connected or switched off and on) for status indicators; German translation of the new strings | SIMs were named after ModemManager object numbers that change at every start, and mobile data, quick setting and status bar always used the first modem; moving mobile data to a SIM without a matching connection failed without a message, and a network without a name was shown by its code |
| plasma-workspace | upstream fix aa326ad9: three KCMs link Qt::Qml (the build failed with the KDE Frameworks of the suite); users KCM (fingerprints): the fprintd calls that wait for polkit authentication (EnrollStart, DeleteEnrolledFinger, Claim of another user) run without a D-Bus timeout; a duplicate fingerprint ends the enrollment with a message; the end of an enrollment the user stopped is not shown as a failure; no binding to `flatFooterButtons` in the dialog; German translation of the new message | enrolling and deleting a finger failed with "Did not receive a reply" when entering the password in the authentication dialog took longer than 25 s, which on a phone with the on-screen keyboard is common; with a finger already enrolled under another name the dialog waited for the finger forever |
| powerdevil | a device declares the kind of its wakeups in the udev property `POWERDEVIL_WAKEUP_TYPE` and counts as wakeup source when its event count rose; after a wakeup by a biometric sensor the display stays off until fprintd reports the result (`VerifyStatus`): a match turns it on, a rejected finger too unless the device configuration keeps it off; without a result the phone sleeps again after 5 s without input; a full wakeup (`wakeup()`) ends the wait and restarts the display idle time | the wakeup source detection relied on `wakeup_count`, which only counts with the `/sys/power/wakeup_count` protocol that systemd does not use, so every wakeup turned the display on; a touch on the fingerprint sensor should turn it on only on a match |
| qt6-base | a touch (or pen) press held on a text input widget (QLineEdit, QTextEdit, QPlainTextEdit, editable combo and spin boxes) opens its context menu; widgets with their own touch handling are left alone | Qt widgets get touch as left button mouse events and had no way to open the context menu by touch: without a hardware keyboard nothing could be pasted into a text field or copied from it |
| rust-gst-plugin-gtk4 | upstream fix d346b181 (gst-plugins-rs MR 3429): gtk4paintablesink passes the stride of tiled dmabufs in bytes | the sink handed GTK the tile counts of the video meta as row pitch; MM21 frames of MediaTek video decoders were garbled in every GTK 4 player using the sink (GNOME Showtime) |
| spacebar | the daemon handles the SMS of every modem and stores the SIM of each message; replies go through the SIM the latest message came in on, else through the default SIM shared with the cellular network settings, never through another SIM than the chosen one; the send button carries the SIM as a badge, pressing and holding it sends one message through another SIM; German translation of the new strings | the daemon used the first modem only: SMS to the SIM of another modem were lost on dual SIM phones with one ModemManager modem per SIM, and every message went out through the first modem |

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
- **Pull requests build once.** A pull request builds the final version, the same `main` builds (there is no
  separate test version: a package from a pull request cannot be told apart on a device from the published one of
  the same version, so a changed package needs a new `REVISION` before it is tested). After the merge the run on
  `main` cannot read the cache of the pull request; on a cache miss it takes over the artifact `<source>_<version>`
  of an earlier run of this repository (the pull request, or an earlier run on `main`) whose `STAND` has the same
  key, checks `SHA256SUMS` and stores it in its own cache. Artifacts of forks are never taken over. Only without
  such an artifact the package is built again.
- **Compiler cache.** Builds run through ccache. Locally the cache lives in `$PAKETE_OUT/ccache/<source>/`
  (`PAKETE_CCACHE=0` builds without it, `PAKETE_CCACHE_MAX` caps it per package, default 2G); in CI each built
  package restores the newest `ccache-<source>-*` entry and saves the updated one, so rebuilding the same package
  after a patch change mostly hits the cache. A hit yields the same object file as the compiler, so the cache is not
  part of the input key. `BUILDINFO` records the hit rate (`ccache_treffer`).
- **Expiry and upkeep.** Cache entries unused for 7 days and artifacts after 90 days (`apt-repo` after 30) are
  deleted by GitHub; the weekly run keeps the cache in use, and a missing entry is taken over from an artifact or
  built again. The repository has 10 GB of cache. After every run on `main` the job `pflege` deletes the entries of
  closed pull requests and deleted branches, all compiler caches but the newest per package and branch, and on
  `main` the results of active packages whose key is no longer current.

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
