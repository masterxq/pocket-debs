#!/bin/sh
# Laeuft im Container pocket-debs-bau-<suite>-arm64 als root (Aufruf durch bau.sh, nicht direkt).
# Paket ohne Debian-Quellpaket: packt das Upstream-Tarball aus, legt die Paketierung aus dem Rezept (<quelle>/debian/)
# dazu, schreibt den Changelog-Eintrag der Fassung <upstream>-0<tag><n> und baut Quell- und arch-abhaengige
# Binaerpakete. Das Quellpaket (.orig.tar, .debian.tar, .dsc) entsteht dabei mit dpkg-buildpackage.
#   /rezept   pakete/<quelle> (nur lesend): paket.conf, debian/ (ohne changelog)
#   /dl       Upstream-Tarball als <quelle>_<upstream>.orig.tar.<komp> (bau.sh hat es gegen TARBALL_SHA256 geprueft)
#   /out      Ergebnisse: Pakete, .dsc/.orig.tar/.debian.tar/.changes/.buildinfo, log/, patches.txt
#   /ccache   Compiler-Cache dieses Pakets (ccache, optional; fehlt der Ordner, baut der Container ohne)
# Umgebung: QUELLE UPSTREAM FASSUNG OPTIONEN PROFILE BAUART MAINTAINER DATUM SUITE APT_QUELLE CHANGELOG HUID HGID
#           CCACHE_MAXSIZE (Obergrenze des Caches, Standard 2G)
set -eu
trap 'chown -R "$HUID:$HGID" /out /ccache 2>/dev/null || true' EXIT
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
L=/out/log
mkdir -p $L
fehler() { echo "FEHLER: $*" >&2; exit 1; }

if [ -n "${APT_QUELLE:-}" ]; then
	rm -f /etc/apt/sources.list.d/debian.sources
	echo "$APT_QUELLE" > /etc/apt/sources.list
fi

B=/build
mkdir -p $B/src
ORIG=$(ls /dl/"${QUELLE}_$UPSTREAM".orig.tar.*)
[ "$(echo "$ORIG" | wc -l)" = 1 ] || fehler "genau ein ${QUELLE}_$UPSTREAM.orig.tar.* in /dl erwartet"
cp "$ORIG" $B/
ORIG=$B/$(basename "$ORIG")
# wie dpkg-source: das Tarball hat genau einen Ordner auf oberster Ebene, sein Inhalt wird der Quellbaum
[ "$(tar -tf "$ORIG" | sed -e 's|^\./||' -e 's|/.*||' -e '/^$/d' | sort -u | wc -l)" = 1 ] \
	|| fehler "$(basename "$ORIG"): mehr als ein Eintrag auf oberster Ebene"
tar -xf "$ORIG" -C $B/src --strip-components=1 --no-same-owner
cd $B/src
[ ! -e debian ] || fehler "das Upstream-Tarball bringt schon debian/ mit"
cp -r /rezept/debian debian
chmod 755 debian/rules
[ ! -e debian/changelog ] || fehler "$QUELLE/debian/changelog: der Eintrag entsteht beim Bau aus paket.conf"
FORMAT=$(cat debian/source/format 2>/dev/null || echo "1.0")
[ "$FORMAT" = "3.0 (quilt)" ] || fehler "Quellformat $FORMAT: nur 3.0 (quilt) wird unterstuetzt"

# Patches der Paketierung (debian/patches/series) prueft dpkg-source beim Bau; hier nur die Liste fuer den Bericht
if [ -s debian/patches/series ]; then
	sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's|^|debian/patches/|' -e 's|$| (Paketierung)|' debian/patches/series > /out/patches.txt
else
	echo "keine Patches (Upstream $UPSTREAM unveraendert)" > /out/patches.txt
fi
cat /out/patches.txt

# Changelog: ein Eintrag je Fassung (Datum kommt von bau.sh: Commit-Zeit des Rezepts)
{
	printf '%s (%s) %s; urgency=medium\n\n' "$QUELLE" "$FASSUNG" "$SUITE"
	printf '  * pocket-debs build of upstream release %s.\n' "$UPSTREAM"
	printf '%s\n' "$CHANGELOG" | sed -e '/^[[:space:]]*$/d' -e 's/^/  * /'
	printf '\n -- %s  %s\n' "$MAINTAINER" "$DATUM"
} > debian/changelog
dpkg-parsechangelog -S Version | grep -qx "$FASSUNG" || fehler "Fassung im Changelog"

apt-get update -qq > $L/apt.log 2>&1 || { tail -20 $L/apt.log; fehler "apt-get update"; }
PROF=$(echo $PROFILE | tr ' ' ,)
case "$BAUART" in *all*) NUR= ;; *) NUR=--arch-only ;; esac
apt-get build-dep -y $NUR --no-install-recommends ${PROF:+-P $PROF} ./ >> $L/apt.log 2>&1 \
	|| { tail -40 $L/apt.log; fehler "Bauabhaengigkeiten"; }
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' > $L/bauumgebung.txt

export DEB_BUILD_OPTIONS="$OPTIONEN noautodbgsym parallel=$(nproc)"
[ -z "$PROFILE" ] || export DEB_BUILD_PROFILES="$PROFILE"
# ccache vor allen C/C++-Compilern (auch fuer die cc-Aufrufe aus Build-Skripten von Rust-Crates)
if [ -d /ccache ] && command -v ccache > /dev/null; then
	export PATH=/usr/lib/ccache:$PATH CCACHE_DIR=/ccache CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-2G}
	ccache -z > /dev/null
fi
dpkg-buildpackage --build=$BAUART -sa -us -uc > $L/build.log 2>&1 || { tail -80 $L/build.log; fehler "dpkg-buildpackage"; }
[ -z "${CCACHE_DIR:-}" ] || { ccache -s > $L/ccache.txt; cat $L/ccache.txt; }
cd $B

V0=${FASSUNG#*:}
for f in *.deb ${QUELLE}_$V0.dsc ${QUELLE}_$V0.debian.tar.* *.orig.tar.* *.buildinfo *.changes; do
	[ -f "$f" ] && cp "$f" /out/
done
cp $B/src/debian/changelog /out/log/changelog
ls /out/*.deb > /dev/null || fehler "keine Binaerpakete"
