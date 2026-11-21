#!/bin/sh
# Laeuft im Container pocket-debs-bau-<suite>-arm64 als root (Aufruf durch bau.sh, nicht direkt).
# Packt ein Debian-Quellpaket aus, haengt unsere Patches an debian/patches/series an (Unterordner pocket-debs/),
# setzt die Fassung <debian>+<tag><n> und baut Quell- und arch-abhaengige Binaerpakete.
#   /rezept   pakete/<quelle> (nur lesend): paket.conf, patches/*.patch
#   /dl       Debian-Quellpaket dieser Fassung (.dsc und die Dateien daraus, nur lesend)
#   /dateien  zusaetzliche Dateien (<quelle>/dateien/), als Baum unter ihrem Pfad in der Quelle
#   /out      Ergebnisse: Pakete, .dsc/.changes/.buildinfo, log/, patches-neu/, konflikte/
#   /ccache   Compiler-Cache dieses Pakets (ccache, optional; fehlt der Ordner, baut der Container ohne)
# Umgebung: QUELLE DEBIAN FASSUNG MODUS (bau|probe|nachziehen) OPTIONEN PROFILE BAUART MAINTAINER DATUM SUITE APT_QUELLE
#           CHANGELOG (Zeilen fuer den Changelog-Eintrag) DATEIEN_KOPF (DEP-3-Kopf des Datei-Patches) HUID HGID
#           CCACHE_MAXSIZE (Obergrenze des Caches, Standard 2G)
# probe: nur auspacken und Patches anwenden (fuzz 0), Ergebnis je Patch in /out/patches.txt.
# nachziehen: wie probe, Patches mit Versatz oder Unschaerfe werden aufgefrischt (/out/patches-neu/).
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
mkdir -p $B
cp /dl/* $B/
DSC=$(ls $B/*.dsc)
[ "$(echo "$DSC" | wc -l)" = 1 ] || fehler "genau eine .dsc in /dl erwartet"
cd $B
# dpkg-source prueft die Dateien gegen die Pruefsummen der .dsc (die .dsc selbst hat bau.sh geprueft)
dpkg-source --no-check -x "$DSC" src > $L/dpkg-source-x.log 2>&1 || { cat $L/dpkg-source-x.log; fehler "dpkg-source -x"; }
cd src
FORMAT=$(cat debian/source/format 2>/dev/null || echo "1.0")
[ "$FORMAT" = "3.0 (quilt)" ] || fehler "Quellformat $FORMAT: nur 3.0 (quilt) wird unterstuetzt"

export QUILT_PATCHES=debian/patches QUILT_PC=.pc
auffrischen() { quilt refresh -p ab --no-timestamps --no-index > /dev/null; }
Z=pocket-debs
mkdir -p debian/patches/$Z
touch debian/patches/series
# Debian-Patches sind nach dpkg-source -x angewendet; quilt muss das ebenso sehen
if [ -n "$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' debian/patches/series)" ]; then
	quilt applied > /dev/null 2>&1 || fehler "quilt sieht die Debian-Patches nicht als angewendet"
fi

: > /out/patches.txt
STATUS=ok
# 1. Zusaetzliche Dateien als eigener Patch (<quelle>/dateien/, Kopf aus DATEIEN_KOPF in paket.conf)
if [ -n "$(find /dateien -type f 2>/dev/null | head -1)" ]; then
	P=$Z/0000-$Z-files.patch
	quilt new $P > /dev/null
	(cd /dateien && find . -type f | sort) | while read -r f; do
		f=${f#./}
		quilt add "$f" > /dev/null
		mkdir -p "$(dirname "$f")"
		cp "/dateien/$f" "$f"
	done
	printf '%s\n' "$DATEIEN_KOPF" | quilt header -r > /dev/null
	auffrischen
	echo "$P ok (erzeugt aus dateien/)" >> /out/patches.txt
fi
# 2. Patches aus pakete/<quelle>/patches, nach Namen sortiert
for p in /rezept/patches/*.patch; do
	[ -f "$p" ] || continue
	n=$Z/$(basename "$p")
	cp "$p" debian/patches/$n
	echo "$n" >> debian/patches/series
	if quilt push --fuzz=0 > $L/quilt-$(basename "$p").log 2>&1; then
		if grep -q 'offset' $L/quilt-$(basename "$p").log; then
			echo "$n versatz" >> /out/patches.txt
			[ "$MODUS" != nachziehen ] || auffrischen
		else
			echo "$n ok" >> /out/patches.txt
		fi
		continue
	fi
	# Ursache feststellen: schon enthalten (rueckwaerts anwendbar), nur mit Unschaerfe anwendbar, Konflikt
	if patch -p1 -R --dry-run -s -f < "debian/patches/$n" > /dev/null 2>&1; then
		echo "$n enthalten (Aenderung steckt schon in der Quelle: Patch entfaellt)" >> /out/patches.txt
		[ "$MODUS" = nachziehen ] || STATUS=fehler
		sed -i "\|^$n\$|d" debian/patches/series
		rm -f "debian/patches/$n"
	elif [ "$MODUS" = nachziehen ] && quilt push --fuzz=3 > $L/quilt-fuzz-$(basename "$p").log 2>&1; then
		auffrischen
		echo "$n unschaerfe (mit fuzz angewendet und aufgefrischt: Ergebnis pruefen)" >> /out/patches.txt
	elif patch -p1 -F3 --dry-run -s -f < "debian/patches/$n" > /dev/null 2>&1; then
		echo "$n unschaerfe (nur mit fuzz anwendbar: bau.sh nachziehen)" >> /out/patches.txt
		STATUS=fehler
		break
	else
		echo "$n konflikt" >> /out/patches.txt
		mkdir -p /out/konflikte
		# Ausgabe von patch und die abgelehnten Hunks fuer die Nacharbeit (der Baum wird verworfen)
		patch -p1 -f -r /out/konflikte/$(basename "$p").rej < "debian/patches/$n" > /out/konflikte/$(basename "$p").txt 2>&1 || true
		STATUS=fehler
		break
	fi
done
cat /out/patches.txt
if [ "$MODUS" = nachziehen ]; then
	mkdir -p /out/patches-neu
	for p in debian/patches/$Z/*.patch; do
		case "$p" in */0000-$Z-files.patch) continue ;; esac
		[ -f "$p" ] && cp "$p" /out/patches-neu/
	done
fi
echo "$STATUS" > /out/patches.status
[ "$STATUS" = ok ] || fehler "Patches lassen sich nicht sauber anwenden (siehe oben und /out/konflikte)"
[ "$MODUS" = bau ] || exit 0

# 3. Aenderungen an der Paketierung selbst (debian/rules und Aehnliches), die quilt nicht fuehren kann:
#    <quelle>/debian-patches/*.patch, nach Namen sortiert, muessen ohne Unschaerfe passen
for p in /rezept/debian-patches/*.patch; do
	[ -f "$p" ] || continue
	patch -p1 --fuzz=0 -s < "$p" || fehler "debian-patches/$(basename "$p") passt nicht auf die Paketierung von $DEBIAN"
	echo "debian-patches/$(basename "$p") ok" >> /out/patches.txt
done

# Changelog-Eintrag unserer Fassung (Datum kommt von bau.sh: Commit-Zeit des Rezepts)
{
	printf '%s (%s) %s; urgency=medium\n\n' "$QUELLE" "$FASSUNG" "$SUITE"
	printf '  * pocket-debs build of Debian %s.\n' "$DEBIAN"
	printf '%s\n' "$CHANGELOG" | sed -e '/^[[:space:]]*$/d' -e 's/^/  * /'
	for p in $(sed -n "s|^$Z/||p" debian/patches/series); do printf '  * debian/patches/%s/%s\n' "$Z" "$p"; done
	printf '\n -- %s  %s\n\n' "$MAINTAINER" "$DATUM"
	cat debian/changelog
} > $B/changelog.neu
mv $B/changelog.neu debian/changelog
dpkg-parsechangelog -S Version | grep -qx "$FASSUNG" || fehler "Fassung im Changelog"

apt-get update -qq > $L/apt.log 2>&1 || { tail -20 $L/apt.log; fehler "apt-get update"; }
PROF=$(echo $PROFILE | tr ' ' ,)
case "$BAUART" in *all*) NUR= ;; *) NUR=--arch-only ;; esac
apt-get build-dep -y $NUR --no-install-recommends ${PROF:+-P $PROF} ./ >> $L/apt.log 2>&1 \
	|| { tail -40 $L/apt.log; fehler "Bauabhaengigkeiten"; }
dpkg-query -W -f '${Package} ${Version} ${Architecture}\n' > $L/bauumgebung.txt

# Quellpaket und arch-abhaengige Binaerpakete (BAUART=source,any); arch:all nur, wenn sie an der genauen Fassung
# haengen (BAUART=source,any,all), sonst bleiben es die von Debian
export DEB_BUILD_OPTIONS="$OPTIONEN noautodbgsym parallel=$(nproc)"
[ -z "$PROFILE" ] || export DEB_BUILD_PROFILES="$PROFILE"
# ccache vor allen Compilern (cc/gcc/g++/clang ueber /usr/lib/ccache, gilt fuer meson, cmake und make gleich). Gebaut
# wird immer in /build/src, die Pfade (auch in -ffile-prefix-map der Debian-Flags) bleiben also von Lauf zu Lauf gleich.
# Ein Treffer liefert dieselbe Objektdatei wie der Compiler, das Ergebnis haengt nicht am Cache.
if [ -d /ccache ] && command -v ccache > /dev/null; then
	export PATH=/usr/lib/ccache:$PATH CCACHE_DIR=/ccache CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-2G}
	ccache -z > /dev/null
fi
dpkg-buildpackage --build=$BAUART -sa -us -uc > $L/build.log 2>&1 || { tail -80 $L/build.log; fehler "dpkg-buildpackage"; }
[ -z "${CCACHE_DIR:-}" ] || { ccache -s > $L/ccache.txt; cat $L/ccache.txt; }
cd $B

# Absicherung gegen stille Fehlfunde: findet der Bau eine optionale Abhaengigkeit nicht, baut er ohne Fehler mit
# weniger Funktionen. Daher jedes Binaerpaket mit Debians Paket der Grundfassung vergleichen (Dateiliste ohne
# usr/share/doc, Paketnamen in Depends/Pre-Depends/Recommends). Fehlt bei uns etwas: Fehler. Ergebnis in
# /out/log/vergleich.txt. Pakete, deren Debian-Fassung nicht mehr im Index steht, werden nicht verglichen.
namen() { dpkg-deb -f "$1" Depends Pre-Depends Recommends | sed 's/^[A-Za-z-]*: //; s/([^)]*)//g; s/:any//g' \
	| tr ',|' '\n\n' | tr -d ' ' | sed '/^$/d' | sort -u; }
dateien() { dpkg-deb --fsys-tarfile "$1" | tar -t | sed 's|^\./||; \|^usr/share/doc/|d; \|/$|d' | sort -u; }
mkdir -p $B/debian-ref
V=$L/vergleich.txt
: > $V
abw=0
for d in $B/*.deb; do
	p=$(dpkg-deb -f "$d" Package)
	dv=$(apt-cache madison "$p" 2>/dev/null | awk -v v="$DEBIAN" '$3 == v || index($3, v "+b") == 1 {print $3}' | sort -V | tail -1)
	if [ -z "$dv" ]; then echo "$p: Debian $DEBIAN nicht im Index, nicht verglichen" >> $V; continue; fi
	(cd $B/debian-ref && apt-get download -q "$p=$dv" > /dev/null 2>&1) || { echo "$p: Debian $dv nicht ladbar, nicht verglichen" >> $V; continue; }
	r=$(ls $B/debian-ref/${p}_*.deb)
	T=$B/debian-ref
	dateien "$r" > $T/r.d; dateien "$d" > $T/e.d; namen "$r" > $T/r.n; namen "$d" > $T/e.n
	fehlt=$(comm -23 $T/r.d $T/e.d; comm -23 $T/r.n $T/e.n | sed 's/^/Abhaengigkeit /')
	mehr=$(comm -13 $T/r.d $T/e.d; comm -13 $T/r.n $T/e.n | sed 's/^/Abhaengigkeit /')
	rm -f "$r"
	echo "$p: verglichen mit Debian $dv" >> $V
	# bewusst weggelassene Teile (FEHLT_ERLAUBT in paket.conf: erweiterter regulaerer Ausdruck) nur vermerken
	if [ -n "${FEHLT_ERLAUBT:-}" ] && [ -n "$fehlt" ]; then
		printf '%s\n' "$fehlt" | grep -E -- "$FEHLT_ERLAUBT" | sed "s|^|  $p fehlt wie vorgesehen: |" >> $V || true
		fehlt=$(printf '%s\n' "$fehlt" | grep -Ev -- "$FEHLT_ERLAUBT" || true)
	fi
	[ -z "$mehr" ] || printf '%s\n' "$mehr" | sed "s|^|  $p mehr: |" >> $V
	if [ -n "$fehlt" ]; then printf '%s\n' "$fehlt" | sed "s|^|  $p FEHLT: |" >> $V; abw=1; fi
done
rm -rf $B/debian-ref
cat $V
[ $abw = 0 ] || fehler "Binaerpakete weichen von Debian ab (fehlende Dateien oder Abhaengigkeiten, siehe oben): Bauumgebung pruefen"

V0=${FASSUNG#*:}
for f in *.deb ${QUELLE}_$V0.dsc ${QUELLE}_$V0.debian.tar.* *.orig.tar.* *.orig-*.tar.* *.buildinfo *.changes; do
	[ -f "$f" ] && cp "$f" /out/
done
cp $B/src/debian/changelog /out/log/changelog
ls /out/*.deb > /dev/null || fehler "keine Binaerpakete"
