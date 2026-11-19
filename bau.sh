#!/bin/bash
# Eigene Fassungen von Debian-Paketen fuer lisbon (Moto G60s): Debian-Quellpaket holen und pruefen, unsere Patches
# anwenden, arm64-Pakete bauen, ins lokale APT-Repository legen. Ein Einstieg, nicht interaktiv.
#
#   ./bau.sh bau <quelle...>|alle|image [--neu]   bauen und ins Repo legen; uebersprungen, wenn eine Fassung mit
#                                                  gleichem Eingabeschluessel schon im Repo liegt (--neu erzwingt)
#   ./bau.sh pruefen                              Debian-Fassung der Suite mit unserer Basis vergleichen (rc 3: neuer)
#   ./bau.sh nachziehen <quelle> [<fassung>] [--suite <suite>] [--uebernehmen]
#                                                  neue Debian-Fassung holen, Patches darauf anwenden (ohne Bau);
#                                                  --uebernehmen schreibt paket.conf und aufgefrischte Patches
#   ./bau.sh anlegen <quelle> [<fassung>]          neues Rezept, Fassung und .dsc-Pruefsumme aus Debian
#   ./bau.sh liste                                Pakete, Fassungen, Stand im Repo
#   ./bau.sh schluessel <quelle>                  Eingabeschluessel und seine Bestandteile
#
# alle = Pakete mit STATUS=aktiv, image = Pakete mit IMAGE_AN=1 (die der Rootfs-Bau installiert).
# Ausgaben unter $PAKETE_OUT (Standard: <projekt>/out/pakete): dl/ (Debian-Quellen), bau/<quelle>/<fassung>/,
# repo/ (reprepro, Suite wie in pakete.conf, Komponente main, arm64 + source), nachziehen/.
# Umgebung: PAKETE_OUT, PAKETE_PROJEKT (Wurzel fuer DATEIEN, Standard: Ordner ueber diesem Repo),
#   PAKETE_STRENG=1 (gleiche Fassung mit anderem Inhalt ist ein Fehler statt einer Warnung),
#   PAKETE_GPG_KEY (Schluessel-ID zum Signieren des Repos, GNUPGHOME unter $PAKETE_OUT/../keys/pakete-gnupg),
#   PAKETE_TIMEOUT (Sekunden je Containerlauf, Standard 21600), NICE (Standard 10).
# Rueckgabe: 0 gut, 1 Fehler, 2 Aufruf, 3 neuere Debian-Fassung (pruefen) bzw. Patch-Konflikt (nachziehen).
set -euo pipefail
{ # ganzes Skript als ein Block: bash liest es vor dem Start vollstaendig (Aenderungen waehrend eines Laufs schaden nicht)
R=$(cd "$(dirname "$0")" && pwd)
PROJEKT=${PAKETE_PROJEKT:-$(dirname "$R")}
O=${PAKETE_OUT:-$PROJEKT/out/pakete}
. "$R/pakete.conf"
TIMEOUT=${PAKETE_TIMEOUT:-21600}
NI="nice -n ${NICE:-10}"
BAUIMG=lisbon-pakete-bau-$SUITE-arm64
REPOIMG=lisbon-pakete-repo-$SUITE
fehler() { echo "FEHLER: $*" >&2; exit 1; }
log() { echo "=== $(date +%H:%M:%S) $*"; }
mkdir -p "$O"

if [ -n "$SNAPSHOT" ]; then
	APT_BASIS="http://snapshot.debian.org/archive/debian/$SNAPSHOT"; APT_OPT="[check-valid-until=no] "
else
	APT_BASIS=$MIRROR; APT_OPT=
fi

# Bau-Images: fehlen sie, werden sie einmal gebaut (Sperre gegen parallele Aufrufe)
images() {
	local n p
	for n in "$BAUIMG:linux/arm64" "$REPOIMG:linux/amd64"; do
		p=${n#*:} n=${n%%:*}
		docker image inspect "$n" > /dev/null 2>&1 && continue
		( flock -w 3600 9 || true
		  docker image inspect "$n" > /dev/null 2>&1 \
			|| docker build -q --platform "$p" --build-arg SUITE="$SUITE" -t "$n" "$R" ) 9>> "$O/.image.lock"
	done
}

lade_conf() {   # lade_conf <quelle>: Variablen aus <quelle>/paket.conf
	local q=$1
	[ -f "$R/$q/paket.conf" ] || fehler "unbekanntes Paket $q ($R/$q/paket.conf fehlt)"
	QUELLE= DEBIAN= DSC_SHA256= LISBON= OPTIONEN=nocheck PROFILE= BAUART=source,any IMAGE= IMAGE_AN=0 STATUS=aktiv DATEIEN= DATEIEN_KOPF= CHANGELOG= PRUEFEN=
	. "$R/$q/paket.conf"
	[ "$QUELLE" = "$q" ] || fehler "$q/paket.conf: QUELLE=$QUELLE passt nicht zum Ordner"
	OHNE_EPOCHE=${DEBIAN#*:}
	FASSUNG=$DEBIAN+$VERSION_TAG$LISBON
	FASSUNG_DATEI=${FASSUNG#*:}
	export QUELLE DEBIAN FASSUNG OPTIONEN PROFILE BAUART MAINTAINER SUITE CHANGELOG DATEIEN_KOPF
	case $QUELLE in lib?*) POOL=main/${QUELLE:0:4}/$QUELLE ;; *) POOL=main/${QUELLE:0:1}/$QUELLE ;; esac
}

alle_pakete() {   # alle_pakete <alle|image>
	local f
	for f in "$R"/*/paket.conf; do
		( lade_conf "$(basename "$(dirname "$f")")"
		  case $1 in alle) [ "$STATUS" = aktiv ] ;; image) [ "$IMAGE_AN" = 1 ] ;; esac && echo "$QUELLE" ) || true
	done
}

# ---------------- Debian-Quellpaket holen und pruefen ----------------
# Die .dsc wird gegen DSC_SHA256 aus paket.conf geprueft, die uebrigen Dateien gegen Checksums-Sha256 der .dsc.
# Quelle: Spiegel (pool), sonst snapshot.debian.org (aeltere Fassungen).
hole() {   # hole <url> <ziel>
	timeout 900 curl -fsSL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"
}
snapshot_url() {   # snapshot_url <datei>: URL auf snapshot.debian.org ueber die Pruefsumme
	timeout 120 curl -fsSL "https://snapshot.debian.org/mr/package/$QUELLE/$OHNE_EPOCHE/srcfiles?fileinfo=1" \
		| python3 -I -c 'import json,sys
d=json.load(sys.stdin); n=sys.argv[1]
for h,infos in d["fileinfo"].items():
    if any(i["name"]==n for i in infos): print("https://snapshot.debian.org/file/"+h); break' "$1"
}
quelle_holen() {
	D=$O/dl/$QUELLE/$OHNE_EPOCHE
	mkdir -p "$D"
	local dsc=${QUELLE}_$OHNE_EPOCHE.dsc
	if ! echo "$DSC_SHA256  $D/$dsc" | sha256sum -c --status 2>/dev/null; then
		rm -f "$D/$dsc"
		hole "$APT_BASIS/pool/$POOL/$dsc" "$D/$dsc" 2>/dev/null || hole "$(snapshot_url "$dsc")" "$D/$dsc" \
			|| fehler "$dsc nicht ladbar"
		echo "$DSC_SHA256  $D/$dsc" | sha256sum -c --status || fehler "Pruefsumme von $dsc passt nicht zu DSC_SHA256"
	fi
	awk '/^Checksums-Sha256:/ {s=1; next} /^[^ ]/ {s=0} s && NF == 3 {print $1, $3}' "$D/$dsc" | while read -r sum f; do
		echo "$sum  $D/$f" | sha256sum -c --status 2>/dev/null && continue
		rm -f "$D/$f"
		echo "lade $f"
		hole "$APT_BASIS/pool/$POOL/$f" "$D/$f" 2>/dev/null || hole "$(snapshot_url "$f")" "$D/$f" || fehler "$f nicht ladbar"
		echo "$sum  $D/$f" | sha256sum -c --status || fehler "Pruefsumme von $f passt nicht zur .dsc"
	done
}

# ---------------- Eingabeschluessel ----------------
# Alles, was das Ergebnis bestimmt: Suite/Spiegel/Snapshot, Bau-Image, Rezept (pakete.conf, Dockerfile,
# bau-innen.sh), paket.conf (Debian-Fassung, .dsc-Pruefsumme, Revision, Profile), Patches, DATEIEN aus dem Projekt.
# Nicht enthalten: der Stand der Bauabhaengigkeiten im Spiegel zum Bauzeitpunkt (fest nur mit SNAPSHOT).
schluessel_teile() {
	local e
	echo "suite=$SUITE snapshot=${SNAPSHOT:--} spiegel=$MIRROR"
	echo "bauimage=$(docker image inspect -f '{{.Id}}' "$BAUIMG" 2>/dev/null || echo fehlt)"
	(cd "$R" && sha256sum pakete.conf Dockerfile bau-innen.sh "$QUELLE/paket.conf" && find "$QUELLE/patches" -maxdepth 1 -type f -name '*.patch' 2>/dev/null | sort | xargs -r sha256sum)
	for e in $DATEIEN; do
		[ -f "$PROJEKT/${e%%:*}" ] || fehler "DATEIEN: $PROJEKT/${e%%:*} fehlt"
		echo "$(sha256sum < "$PROJEKT/${e%%:*}" | cut -d' ' -f1)  ${e#*:}"
	done
}
schluessel() { schluessel_teile | sha256sum | cut -c1-16; }

# Datum des Changelog-Eintrags: Commit-Zeit des Rezepts (reproduzierbar), bei lokalen Aenderungen die aktuelle Zeit
datum() {
	local pfade="$QUELLE" e
	if [ -n "$(git -C "$R" status --porcelain -- "$QUELLE" 2>/dev/null)" ] || ! git -C "$R" log -1 --format=%cD -- "$QUELLE" 2>/dev/null | grep -q .; then
		date -R; return
	fi
	for e in $DATEIEN; do
		[ -z "$(git -C "$PROJEKT" status --porcelain -- "${e%%:*}" 2>/dev/null)" ] || { date -R; return; }
	done
	git -C "$R" log -1 --format=%cD -- "$pfade"
}

# ---------------- Repo (reprepro) ----------------
repo() {   # repo <reprepro-argumente...>
	local sign= g=$O/../keys/pakete-gnupg
	mkdir -p "$O/repo/conf"
	[ -z "${PAKETE_GPG_KEY:-}" ] || sign="SignWith: $PAKETE_GPG_KEY"
	cat > "$O/repo/conf/distributions" <<EOF
Origin: $REPO_ORIGIN
Label: $REPO_LABEL
Codename: $SUITE
Architectures: arm64 source
Components: $REPO_COMPONENT
Description: $REPO_DESCRIPTION
$sign
EOF
	printf 'verbose\nbasedir /repo\n' > "$O/repo/conf/options"
	flock -w 600 "$O/.repo.lock" docker run --rm -u "$(id -u):$(id -g)" -v "$O/repo:/repo" -v "$O/bau:/bau:ro" \
		${sign:+-v "$(cd "$g" && pwd):/gnupg" -e GNUPGHOME=/gnupg} "$REPOIMG" reprepro -b /repo "$@"
}
im_repo() {   # im_repo: Quelle in unserer Fassung im Repo und mit diesem Schluessel gebaut?
	[ -f "$O/repo/pool/$POOL/${QUELLE}_$FASSUNG_DATEI.dsc" ] && [ -f "$O/repo/lisbon/$QUELLE.stand" ] \
		&& grep -qx "fassung=$FASSUNG schluessel=$1" "$O/repo/lisbon/$QUELLE.stand"
}

# ---------------- Bau ----------------
bau() {   # bau <quelle> <neu 0|1>
	lade_conf "$1"
	local K W rc
	K=$(schluessel)
	# Sperre je Paket: parallele Aufrufe (z. B. zwei Image-Bauten) bauen dasselbe Paket nicht doppelt
	exec 7>> "$O/.bau-$QUELLE.lock"
	flock -w "$TIMEOUT" 7 || fehler "Sperre $O/.bau-$QUELLE.lock"
	if [ "$2" = 0 ] && im_repo "$K"; then
		log "$QUELLE $FASSUNG: uebersprungen (gleicher Eingabeschluessel $K im Repo; --neu erzwingt)"
		return 0
	fi
	log "$QUELLE $FASSUNG: bauen (Schluessel $K)"
	quelle_holen
	W=$O/bau/$QUELLE/$FASSUNG_DATEI
	rm -rf "$W"; mkdir -p "$W/out" "$W/dateien"
	local e
	for e in $DATEIEN; do install -D -m 644 "$PROJEKT/${e%%:*}" "$W/dateien/${e#*:}"; done
	schluessel_teile > "$W/EINGABEN"
	local t0=$SECONDS
	rc=0
	timeout "$TIMEOUT" docker run --rm --platform linux/arm64 \
		-e QUELLE -e DEBIAN -e FASSUNG -e MODUS=bau -e OPTIONEN -e PROFILE -e BAUART -e MAINTAINER -e SUITE -e CHANGELOG -e DATEIEN_KOPF \
		-e DATUM="$(datum)" -e APT_QUELLE="deb $APT_OPT$APT_BASIS $SUITE main" -e HUID="$(id -u)" -e HGID="$(id -g)" \
		-v "$R:/pakete:ro" -v "$R/$QUELLE:/rezept:ro" -v "$D:/dl:ro" -v "$W/dateien:/dateien:ro" -v "$W/out:/out" \
		"$BAUIMG" $NI sh /pakete/bau-innen.sh || rc=$?
	[ $rc = 0 ] || fehler "$QUELLE: Bau fehlgeschlagen (rc $rc, Logs in $W/out/log)"
	echo "Bauzeit $(( (SECONDS - t0) / 60 )) min"
	# Pruefung aus paket.conf (Shell, laeuft im Ergebnisordner mit den .deb)
	if [ -n "$PRUEFEN" ]; then
		(cd "$W/out" && eval "$PRUEFEN") > "$W/pruefung.log" 2>&1 || { cat "$W/pruefung.log"; fehler "$QUELLE: PRUEFEN fehlgeschlagen"; }
		cat "$W/pruefung.log"
	fi
	# Ergebnis ins Repo; gleiche Fassung mit anderem Inhalt wird ersetzt (lokal) bzw. abgelehnt (PAKETE_STRENG=1)
	if [ -f "$O/repo/pool/$POOL/${QUELLE}_$FASSUNG_DATEI.dsc" ]; then
		[ "${PAKETE_STRENG:-0}" != 1 ] || fehler "$QUELLE $FASSUNG liegt mit anderem Inhalt im Repo: LISBON in $QUELLE/paket.conf erhoehen"
		echo "WARNUNG: $QUELLE $FASSUNG lag mit anderen Eingaben im Repo und wird ersetzt (vor einer Veroeffentlichung LISBON erhoehen)" >&2
	fi
	repo removesrc "$SUITE" "$QUELLE" > /dev/null 2>&1 || true
	repo -C "$REPO_COMPONENT" includedsc "$SUITE" "/bau/$QUELLE/$FASSUNG_DATEI/out/${QUELLE}_$FASSUNG_DATEI.dsc"
	local debs=
	for e in "$W"/out/*.deb; do debs="$debs /bau/$QUELLE/$FASSUNG_DATEI/out/$(basename "$e")"; done
	repo -C "$REPO_COMPONENT" includedeb "$SUITE" $debs
	mkdir -p "$O/repo/lisbon"
	echo "fassung=$FASSUNG schluessel=$K" > "$O/repo/lisbon/$QUELLE.stand"
	{
		echo "# $QUELLE $FASSUNG, gebaut $(date -u '+%F %T') UTC mit pakete/bau.sh"
		echo "schluessel=$K"
		echo "pakete_commit=$(git -C "$R" describe --always --dirty 2>/dev/null || echo -)"
		echo "projekt_commit=$(git -C "$PROJEKT" describe --always --dirty 2>/dev/null || echo -)"
		echo "bauimage=$BAUIMG $(docker image inspect -f '{{.Id}}' "$BAUIMG")"
		(cd "$W/out" && sha256sum *.deb *.dsc) | sed 's/^/sha256 /'
	} > "$W/BUILDINFO"
	(cd "$W/out" && sha256sum *.deb > ../SHA256SUMS)
	cat "$W/out/patches.txt"
	cat "$W/SHA256SUMS"
}

# ---------------- Debian-Fassungen abfragen (signierte Quellen-Indizes ueber apt) ----------------
apt_lauf() {   # apt_lauf <suite> <skript>: Container mit deb-src der Suite, Listen zwischengespeichert
	local s=$1; shift
	mkdir -p "$O/apt/$s" "$O/nachziehen"
	docker run --rm -i -e HUID="$(id -u)" -e HGID="$(id -g)" -v "$O/apt/$s:/var/lib/apt/lists" -v "$O/dl:/dl" \
		-v "$O/nachziehen:/nz" "$REPOIMG" sh -c "set -eu
rm -f /etc/apt/sources.list.d/*.sources
echo 'deb-src $APT_OPT$APT_BASIS $s main' > /etc/apt/sources.list
apt-get update -qq -o Acquire::Languages=none 2>&1 | grep -v '^W: ' >&2 || true
$*
chown -R \$HUID:\$HGID /var/lib/apt/lists /dl /nz 2>/dev/null || true"
}
debian_fassung() {   # debian_fassung <suite> <quelle...>: "<quelle> <hoechste fassung>"
	local s=$1; shift
	apt_lauf "$s" "for q in $*; do
max=-
for x in \$(apt-cache showsrc --only-source \$q 2>/dev/null | sed -n 's/^Version: //p'); do
	[ \$max = - ] || dpkg --compare-versions \$x gt \$max || continue; max=\$x
done
echo \"\$q \$max\"; done"
}

pruefen() {
	local qs="" q v rc=0
	for f in "$R"/*/paket.conf; do qs="$qs $(basename "$(dirname "$f")")"; done
	images
	printf '%-14s %-22s %-22s %s\n' QUELLE "UNSERE BASIS" "DEBIAN $SUITE" STAND
	while read -r q v; do
		lade_conf "$q"
		if [ "$v" = - ]; then s="nicht in $SUITE"
		elif [ "$v" = "$DEBIAN" ]; then s=aktuell
		elif dpkg --compare-versions "$v" gt "$DEBIAN"; then s="NEUER: ./bau.sh nachziehen $q"; rc=3
		else s="aelter in Debian"; fi
		printf '%-14s %-22s %-22s %s\n' "$q" "$DEBIAN" "$v" "$s"
	done < <(debian_fassung "$SUITE" $qs)
	return $rc
}

nachziehen() {   # nachziehen <quelle> [<fassung>] [--suite <s>] [--uebernehmen]
	local q=$1 ziel= s=$SUITE ueb=0
	shift
	while [ $# -gt 0 ]; do
		case $1 in --suite) s=$2; shift ;; --uebernehmen) ueb=1 ;; -*) fehler "unbekannte Option $1" ;; *) ziel=$1 ;; esac
		shift
	done
	lade_conf "$q"
	images
	[ -n "$ziel" ] || ziel=$(debian_fassung "$s" "$q" | awk '{print $2}')
	[ -n "$ziel" ] && [ "$ziel" != - ] || fehler "$q nicht in Debian $s"
	log "$q: Basis $DEBIAN -> Debian $ziel ($s)"
	[ "$ziel" != "$DEBIAN" ] || { echo "schon auf $ziel"; return 0; }
	local oe=${ziel#*:}
	mkdir -p "$O/dl/$q/$oe"
	# apt-get source prueft die Kette Release-Signatur (debian-archive-keyring) -> Sources -> Dateien der .dsc
	apt_lauf "$s" "cd /dl/$q/$oe && apt-get source --download-only -qq -o APT::Sandbox::User=root '$q=$ziel'" \
		|| fehler "$q $ziel ueber apt nicht ladbar (aeltere Fassung? dann <fassung> und DSC_SHA256 von Hand)"
	local neu_sum
	neu_sum=$(sha256sum < "$O/dl/$q/$oe/${q}_$oe.dsc" | cut -d' ' -f1)
	local N=$O/nachziehen/$q/$oe W
	rm -rf "$N"; mkdir -p "$N/out" "$N/dateien"
	local e
	for e in $DATEIEN; do install -D -m 644 "$PROJEKT/${e%%:*}" "$N/dateien/${e#*:}"; done
	local rc=0
	docker run --rm -e QUELLE -e DEBIAN="$ziel" -e FASSUNG="$ziel+${VERSION_TAG}1" -e MODUS=nachziehen \
		-e DATEIEN_KOPF -e HUID="$(id -u)" -e HGID="$(id -g)" \
		-v "$R:/pakete:ro" -v "$R/$q:/rezept:ro" -v "$O/dl/$q/$oe:/dl:ro" -v "$N/dateien:/dateien:ro" -v "$N/out:/out" \
		"$REPOIMG" sh /pakete/bau-innen.sh > "$N/lauf.log" 2>&1 || rc=$?
	echo "--- Patches auf $q $ziel:"
	cat "$N/out/patches.txt" 2>/dev/null || { tail -20 "$N/lauf.log"; fehler "Probe fehlgeschlagen ($N/lauf.log)"; }
	if [ $rc != 0 ] || [ "$(cat "$N/out/patches.status")" != ok ]; then
		echo "KONFLIKT: Patches von Hand anpassen. Fehlschlaege und .rej-Inhalt: $N/out/konflikte/" >&2
		return 3
	fi
	# Vergleich mit dem Repo-Stand: unveraendert / aufgefrischt / entfaellt
	local p n
	for p in "$R/$q"/patches/*.patch; do
		[ -f "$p" ] || continue
		n=$(basename "$p")
		if [ ! -f "$N/out/patches-neu/$n" ]; then echo "  $n: entfaellt"
		elif cmp -s "$p" "$N/out/patches-neu/$n"; then echo "  $n: unveraendert"
		else echo "  $n: aufgefrischt ($N/out/patches-neu/$n)"; fi
	done
	[ -n "$(ls "$N"/out/patches-neu/ 2>/dev/null)" ] || [ -n "$DATEIEN" ] \
		|| echo "HINWEIS: keine Patches mehr noetig, das Paket kann entfallen (Debian-Fassung nehmen)"
	if [ $ueb = 1 ]; then
		for p in "$R/$q"/patches/*.patch; do
			[ -f "$p" ] || continue
			n=$(basename "$p")
			if [ -f "$N/out/patches-neu/$n" ]; then cp "$N/out/patches-neu/$n" "$p"; else git -C "$R" rm -q "$p" 2>/dev/null || rm -f "$p"; fi
		done
		sed -i -e "s|^DEBIAN=.*|DEBIAN=$ziel|" -e "s|^DSC_SHA256=.*|DSC_SHA256=$neu_sum|" -e "s|^LISBON=.*|LISBON=1|" "$R/$q/paket.conf"
		echo "uebernommen in $R/$q (pruefen mit git -C $R diff, dann ./bau.sh bau $q)"
	else
		echo "trocken: nichts geaendert. Uebernehmen mit: ./bau.sh nachziehen $q $ziel --suite $s --uebernehmen"
		echo "  (DEBIAN=$ziel DSC_SHA256=$neu_sum LISBON=1)"
	fi
}

anlegen() {   # anlegen <quelle> [<fassung>]: Rezept-Geruest mit Fassung und .dsc-Pruefsumme aus den signierten Quellen
	local q=$1 ziel=${2:-}
	[ ! -e "$R/$q/paket.conf" ] || fehler "$R/$q/paket.conf gibt es schon"
	images
	[ -n "$ziel" ] || ziel=$(debian_fassung "$SUITE" "$q" | awk '{print $2}')
	[ -n "$ziel" ] && [ "$ziel" != - ] || fehler "$q nicht in Debian $SUITE"
	local oe=${ziel#*:}
	mkdir -p "$O/dl/$q/$oe"
	apt_lauf "$SUITE" "cd /dl/$q/$oe && apt-get source --download-only -qq -o APT::Sandbox::User=root '$q=$ziel'" || fehler "$q $ziel nicht ladbar"
	mkdir -p "$R/$q/patches"
	printf '%s\n' "# $q: was die Patches aendern und warum (eine bis drei Zeilen)" "QUELLE=$q" "DEBIAN=$ziel" \
		"DSC_SHA256=$(sha256sum < "$O/dl/$q/$oe/${q}_$oe.dsc" | cut -d' ' -f1)" LISBON=1 STATUS=aktiv 'IMAGE=""' IMAGE_AN=0 \
		'CHANGELOG=""' > "$R/$q/paket.conf"
	echo "angelegt: $R/$q/paket.conf (Patches im DEP-3-Format nach $R/$q/patches/)"
}

liste() {
	local f st
	printf '%-14s %-26s %-7s %-6s %s\n' QUELLE FASSUNG STATUS IMAGE "REPO (Schluessel)"
	for f in "$R"/*/paket.conf; do
		lade_conf "$(basename "$(dirname "$f")")"
		st=$(cat "$O/repo/lisbon/$QUELLE.stand" 2>/dev/null || echo "nicht gebaut")
		printf '%-14s %-26s %-7s %-6s %s\n' "$QUELLE" "$FASSUNG" "$STATUS" "$IMAGE_AN" "$st"
	done
}

CMD=${1:-}
[ $# -gt 0 ] && shift
case "$CMD" in
	bau)
		neu=0 qs=
		for a in "$@"; do
			case $a in --neu) neu=1 ;; alle|image) qs="$qs $(alle_pakete "$a" | tr '\n' ' ')" ;; -*) fehler "unbekannte Option $a" ;; *) qs="$qs $a" ;; esac
		done
		[ -n "${qs// /}" ] || { [ "$*" = image ] || [ "$*" = alle ] || { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }; echo "keine Pakete fuer $*"; exit 0; }
		images
		for q in $qs; do ( bau "$q" "$neu" ); done
		;;
	pruefen) pruefen ;;
	nachziehen) [ $# -ge 1 ] || exit 2; nachziehen "$@" ;;
	liste) liste ;;
	anlegen) [ $# -ge 1 ] || exit 2; anlegen "$@" ;;
	schluessel) lade_conf "${1:?quelle}"; images; schluessel_teile; echo "schluessel=$(schluessel)" ;;
	*) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
exit
}
