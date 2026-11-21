#!/bin/sh
# Laeuft im Container pocket-debs-repo-<suite> ohne Netz (Aufruf durch bau.sh, nicht direkt). Baut aus einer
# Upstream-Quelle ohne Debian-Paketierung (ART=upstream in paket.conf) ein Debian-Quellpaket 3.0 (quilt):
#   /upstream/<archiv>.tar.gz  Archiv eines festen Commits (von bau.sh geprueft) -> <quelle>_<up>.orig.tar.gz
#   /crates/liste, *.crate     Rust-Kisten aus Cargo.lock (von bau.sh geprueft; nur mit CARGO_VENDOR=1)
#                              -> <quelle>_<up>.orig-vendor.tar.xz, im Quellbaum vendor/<name>-<fassung>/
#   /rezept/debian             Paketierung aus diesem Repo
#   /out                       .dsc, orig-Archive, debian.tar.xz
# Umgebung: QUELLE DEBIAN (Fassung der Paketierung, muss zu debian/changelog passen) CARGO_VENDOR HUID HGID
# Die Kisten bekommen eine .cargo-checksum.json mit der Pruefsumme aus Cargo.lock und ohne Dateiliste: cargo prueft
# die Kiste gegen Cargo.lock, die Dateien nicht (sie liegen unveraendert aus der geprueften .crate im Archiv).
set -eu
trap 'chown -R "$HUID:$HGID" /out 2>/dev/null || true' EXIT
export LC_ALL=C.UTF-8
fehler() { echo "FEHLER: $*" >&2; exit 1; }

UP=${DEBIAN#*:}
UP=${UP%-*}
W=/tmp/quelle
rm -rf $W
mkdir -p $W/src
set -- /upstream/*.tar.gz
[ $# = 1 ] && [ -f "$1" ] || fehler "genau ein Upstream-Archiv (.tar.gz) in /upstream erwartet"
cp "$1" "$W/${QUELLE}_$UP.orig.tar.gz"
tar -xzf "$1" -C $W/src --strip-components=1
[ ! -e $W/src/debian ] || fehler "das Upstream-Archiv bringt debian/ mit: ART=upstream erwartet eine Quelle ohne Paketierung"
cp -r /rezept/debian $W/src/debian
V=$(cd $W/src && dpkg-parsechangelog -S Version)
[ "$V" = "$DEBIAN" ] || fehler "debian/changelog nennt $V, paket.conf DEBIAN=$DEBIAN"
SDE=$(cd $W/src && dpkg-parsechangelog -S Timestamp)

if [ "${CARGO_VENDOR:-0}" = 1 ]; then
	[ -s /crates/liste ] || fehler "keine Kisten (/crates/liste leer)"
	mkdir -p $W/vendor
	while read -r n v c; do
		d=$W/vendor/$n-$v
		mkdir -p "$d"
		tar -xzf "/crates/$n-$v.crate" -C "$d" --strip-components=1
		printf '{"files":{},"package":"%s"}\n' "$c" > "$d/.cargo-checksum.json"
	done < /crates/liste
	(cd $W && tar --sort=name --mtime="@$SDE" --owner=0 --group=0 --numeric-owner -cf - vendor) \
		| xz -6 -T1 > "$W/${QUELLE}_$UP.orig-vendor.tar.xz"
	mv $W/vendor $W/src/vendor
	echo "vendor/: $(ls $W/src/vendor | wc -l) Kisten"
fi

cd $W
SOURCE_DATE_EPOCH=$SDE dpkg-source -b src > dpkg-source-b.log 2>&1 || { cat dpkg-source-b.log; fehler "dpkg-source -b"; }
cp "${QUELLE}_$V.dsc" ${QUELLE}_$UP.orig*.tar.* "${QUELLE}_$V".debian.tar.* /out/
ls -l /out
