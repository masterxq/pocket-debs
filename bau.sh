#!/bin/bash
# pocket-debs: eigene Fassungen von Debian-Paketen fuer Telefone mit Mainline-Linux. Debian-Quellpaket holen und
# pruefen, unsere Patches und Dateien anwenden, arm64-Pakete bauen, ins APT-Repository legen. Ein Einstieg, nicht
# interaktiv. Laeuft auf amd64 (Bau unter qemu-user-binfmt) und nativ auf arm64.
#
#   ./bau.sh bau <quelle...>|alle|image [--neu]   bauen und ins Repo legen; uebersprungen, wenn eine Fassung mit
#                                                  gleichem Eingabeschluessel schon im Repo liegt (--neu erzwingt)
#   ./bau.sh holen <quelle...>|alle|image [--trotzdem]
#                                                  fertige Pakete aus der CI (GitHub Actions, Artefakt je Paket, gh)
#                                                  pruefen und ins Repo legen, statt sie zu bauen
#   ./bau.sh einlegen <ordner...>                 Ergebnisordner (PAKETE_ERGEBNIS oder ein CI-Artefakt) ins Repo
#   ./bau.sh pruefen                              Debian-Fassung der Suite mit unserer Basis vergleichen (rc 3: neuer)
#   ./bau.sh nachziehen <quelle> [<fassung>] [--suite <suite>] [--uebernehmen]
#                                                  neue Debian-Fassung holen, Patches darauf anwenden (ohne Bau);
#                                                  --uebernehmen schreibt paket.conf und aufgefrischte Patches
#   ./bau.sh anlegen <quelle> [<fassung>]          neues Rezept, Fassung und .dsc-Pruefsumme aus Debian
#   ./bau.sh liste                                Pakete, Fassungen, Stand im Repo
#   ./bau.sh namen alle|image                     Namen der Pakete (ohne Docker)
#   ./bau.sh schluessel <quelle>                  Eingabeschluessel und seine Bestandteile (ohne Docker)
#
# alle = Pakete mit STATUS=aktiv, image = Pakete mit IMAGE_AN=1 (die ein Rootfs-Bau installiert).
# Ausgaben unter $PAKETE_OUT (Standard: out/ in diesem Repo): dl/ (Debian-Quellen), bau/<quelle>/<fassung>/,
# repo/ (reprepro, Suite wie in pakete.conf, arm64 + source; repo/stand/<quelle> = Fassung und Schluessel), nachziehen/.
# Umgebung: PAKETE_OUT, PAKETE_ERGEBNIS (Ordner: Ergebnis jedes Baus zusaetzlich nach <ordner>/<quelle>/, fuer einlegen),
#   PAKETE_STRENG=1 (gleiche Fassung mit anderem Inhalt ist ein Fehler statt einer Warnung),
#   PAKETE_GPG_KEY (Schluessel zum Signieren des Repos) mit PAKETE_GNUPGHOME (Standard $GNUPGHOME bzw. ~/.gnupg),
#   PAKETE_TIMEOUT (Sekunden je Containerlauf, Standard 21600), NICE (Standard 10).
# Rueckgabe: 0 gut, 1 Fehler, 2 Aufruf, 3 neuere Debian-Fassung (pruefen) bzw. Patch-Konflikt (nachziehen).
set -euo pipefail
{ # ganzes Skript als ein Block: bash liest es vor dem Start vollstaendig (Aenderungen waehrend eines Laufs schaden nicht)
R=$(cd "$(dirname "$0")" && pwd)
O=${PAKETE_OUT:-$R/out}
. "$R/pakete.conf"
TIMEOUT=${PAKETE_TIMEOUT:-21600}
NI="nice -n ${NICE:-10}"
BAUIMG=pocket-debs-bau-$SUITE-arm64
REPOIMG=pocket-debs-repo-$SUITE
fehler() { echo "FEHLER: $*" >&2; exit 1; }
log() { echo "=== $(date +%H:%M:%S) $*"; }
mkdir -p "$O"
O=$(cd "$O" && pwd)

if [ -n "$SNAPSHOT" ]; then
	APT_BASIS="http://snapshot.debian.org/archive/debian/$SNAPSHOT"; APT_OPT="[check-valid-until=no] "
else
	APT_BASIS=$MIRROR; APT_OPT=
fi

# Bau-Images: fehlen sie, werden sie einmal gebaut (Sperre gegen parallele Aufrufe). Das Bau-Image ist immer arm64
# (auf amd64 ueber qemu-user-binfmt, auf arm64 nativ), das Repo-Image hat die Architektur des Rechners.
bild() {   # bild <name> [<docker-build-optionen...>]
	local n=$1; shift
	docker image inspect "$n" > /dev/null 2>&1 && return 0
	( flock -w 3600 9 || true
	  docker image inspect "$n" > /dev/null 2>&1 \
		|| docker build -q "$@" --build-arg SUITE="$SUITE" -t "$n" "$R" > /dev/null ) 9>> "$O/.image.lock"
}
images() { bild "$BAUIMG" --platform linux/arm64; bild "$REPOIMG"; }

lade_conf() {   # lade_conf <quelle>: Variablen aus <quelle>/paket.conf
	local q=$1
	[ -f "$R/$q/paket.conf" ] || fehler "unbekanntes Paket $q ($R/$q/paket.conf fehlt)"
	QUELLE= DEBIAN= DSC_SHA256= REVISION= OPTIONEN=nocheck PROFILE= BAUART=source,any IMAGE= IMAGE_AN=0 STATUS=aktiv DATEIEN_KOPF= CHANGELOG= PRUEFEN= FEHLT_ERLAUBT=
	. "$R/$q/paket.conf"
	[ "$QUELLE" = "$q" ] || fehler "$q/paket.conf: QUELLE=$QUELLE passt nicht zum Ordner"
	[ -n "$REVISION" ] || fehler "$q/paket.conf: REVISION fehlt"
	OHNE_EPOCHE=${DEBIAN#*:}
	FASSUNG=$DEBIAN+$VERSION_TAG$REVISION
	FASSUNG_DATEI=${FASSUNG#*:}
	export QUELLE DEBIAN FASSUNG OPTIONEN PROFILE BAUART MAINTAINER SUITE CHANGELOG DATEIEN_KOPF FEHLT_ERLAUBT
	POOL=$(pool "$QUELLE")
}
pool() { case $1 in lib?*) echo "main/${1:0:4}/$1" ;; *) echo "main/${1:0:1}/$1" ;; esac; }

# Zusaetzliche Dateien eines Pakets: <quelle>/dateien/ bildet den Quellbaum ab (<quelle>/dateien/a/b.c -> a/b.c),
# bau-innen.sh macht daraus den Patch debian/patches/pocket-debs/0000-pocket-debs-files.patch
dateien() { [ -d "$R/$QUELLE/dateien" ] && (cd "$R/$QUELLE/dateien" && find . -type f | sed 's|^\./||' | LC_ALL=C sort) || true; }
dateien_kopieren() {   # dateien_kopieren <ziel>
	local f
	dateien | while read -r f; do install -D -m 644 "$R/$QUELLE/dateien/$f" "$1/$f"; done
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
# Alles, was das Ergebnis bestimmt: Suite/Spiegel/Snapshot, Rezept (pakete.conf, Dockerfile, bau-innen.sh), paket.conf
# (Debian-Fassung, .dsc-Pruefsumme, Revision, Profile), Patches, zusaetzliche Dateien. Haengt nur von Dateien im Repo
# ab (kein Docker noetig), deshalb auf jedem Rechner und in der CI derselbe Schluessel.
# Nicht enthalten: bau.sh (Aufrufschicht), der Stand des Bau-Images und der Bauabhaengigkeiten im Spiegel zum
# Bauzeitpunkt (fest nur mit SNAPSHOT); nach einem neuen Bau-Image mit --neu bauen.
schluessel_teile() {
	local f
	echo "suite=$SUITE snapshot=${SNAPSHOT:--} spiegel=$MIRROR"
	(cd "$R" && sha256sum pakete.conf Dockerfile bau-innen.sh "$QUELLE/paket.conf" && find "$QUELLE/patches" "$QUELLE/debian-patches" -maxdepth 1 -type f -name '*.patch' 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum)
	dateien | while read -r f; do echo "$(sha256sum < "$R/$QUELLE/dateien/$f" | cut -d' ' -f1)  $f"; done
}
schluessel() { schluessel_teile | sha256sum | cut -c1-16; }

# Datum des Changelog-Eintrags: Commit-Zeit des Rezepts (reproduzierbar, braucht die Historie: in der CI volle
# Tiefe auschecken), bei lokalen Aenderungen die aktuelle Zeit
datum() {
	if [ -n "$(git -C "$R" status --porcelain -- "$QUELLE" 2>/dev/null)" ] || ! git -C "$R" log -1 --format=%cD -- "$QUELLE" 2>/dev/null | grep -q .; then
		date -R; return
	fi
	git -C "$R" log -1 --format=%cD -- "$QUELLE"
}

# ---------------- Repo (reprepro) ----------------
repo() {   # repo <ordner> <reprepro-argumente...>: <ordner> ist im Container /ein
	local ein=$1 sign= g=${PAKETE_GNUPGHOME:-${GNUPGHOME:-$HOME/.gnupg}}
	shift
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
	flock -w 600 "$O/.repo.lock" docker run --rm -u "$(id -u):$(id -g)" -v "$O/repo:/repo" -v "$ein:/ein:ro" \
		${sign:+-v "$(cd "$g" && pwd):/gnupg" -e GNUPGHOME=/gnupg} "$REPOIMG" reprepro -b /repo "$@"
}
stand_wert() { sed -n "s/^$1=//p" "$2" 2>/dev/null || true; }   # stand_wert <feld> <datei>
im_repo() {   # im_repo <schluessel>: Quelle in unserer Fassung im Repo und mit diesem Schluessel gebaut?
	[ -f "$O/repo/pool/$POOL/${QUELLE}_$FASSUNG_DATEI.dsc" ] \
		&& [ "$(stand_wert fassung "$O/repo/stand/$QUELLE")" = "$FASSUNG" ] \
		&& [ "$(stand_wert schluessel "$O/repo/stand/$QUELLE")" = "$1" ]
}

# Ergebnisordner eines Baus: .deb, .dsc mit den Dateien daraus, STAND (quelle/fassung/schluessel), BUILDINFO,
# SHA256SUMS ueber alle Paketdateien, patches.txt, vergleich.txt. ins_repo legt ihn ins Repo (auch Ergebnisse aus
# der CI: ./bau.sh einlegen bzw. holen).
dsc_dateien() { awk '/^Checksums-Sha256:/ {s=1; next} /^[^ ]/ {s=0} s && NF == 3 {print $3}' "$1"; }
ins_repo() {   # ins_repo <ordner>
	local d q f k dsc p alt debs= e
	d=$(cd "$1" && pwd)
	q=$(stand_wert quelle "$d/STAND") f=$(stand_wert fassung "$d/STAND") k=$(stand_wert schluessel "$d/STAND")
	[ -n "$q" ] && [ -n "$f" ] && [ -n "$k" ] || fehler "$d/STAND fehlt oder ist unvollstaendig"
	(cd "$d" && sha256sum -c --quiet SHA256SUMS) || fehler "$d: Pruefsummen passen nicht (SHA256SUMS)"
	dsc=${q}_${f#*:}.dsc p=$(pool "$q")
	[ -f "$d/$dsc" ] || fehler "$d/$dsc fehlt"
	# gleiche Fassung mit anderem Inhalt wird ersetzt (lokal) bzw. abgelehnt (PAKETE_STRENG=1)
	alt=$(stand_wert schluessel "$O/repo/stand/$q")
	if [ -f "$O/repo/pool/$p/$dsc" ] && [ "$alt" != "$k" ]; then
		[ "${PAKETE_STRENG:-0}" != 1 ] || fehler "$q $f liegt mit anderem Inhalt im Repo: REVISION in $q/paket.conf erhoehen"
		echo "WARNUNG: $q $f lag mit anderen Eingaben im Repo und wird ersetzt (vor einer Veroeffentlichung REVISION erhoehen)" >&2
	fi
	repo "$d" removesrc "$SUITE" "$q" > /dev/null 2>&1 || true
	repo "$d" -C "$REPO_COMPONENT" -P optional includedsc "$SUITE" "/ein/$dsc"
	for e in "$d"/*.deb; do debs="$debs /ein/$(basename "$e")"; done
	repo "$d" -C "$REPO_COMPONENT" includedeb "$SUITE" $debs
	mkdir -p "$O/repo/stand"
	cp "$d/STAND" "$O/repo/stand/$q"
	log "$q $f: im Repo (Schluessel $k)"
}

# ---------------- Bau ----------------
bau() {   # bau <quelle> <neu 0|1>
	lade_conf "$1"
	local K W E rc f
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
	dateien_kopieren "$W/dateien"
	schluessel_teile > "$W/EINGABEN"
	local t0=$SECONDS
	rc=0
	timeout "$TIMEOUT" docker run --rm --platform linux/arm64 \
		-e QUELLE -e DEBIAN -e FASSUNG -e MODUS=bau -e OPTIONEN -e PROFILE -e BAUART -e MAINTAINER -e SUITE -e CHANGELOG -e DATEIEN_KOPF -e FEHLT_ERLAUBT \
		-e DATUM="$(datum)" -e APT_QUELLE="deb $APT_OPT$APT_BASIS $SUITE main" -e HUID="$(id -u)" -e HGID="$(id -g)" \
		-v "$R:/pakete:ro" -v "$R/$QUELLE:/rezept:ro" -v "$D:/dl:ro" -v "$W/dateien:/dateien:ro" -v "$W/out:/out" \
		"$BAUIMG" $NI sh /pakete/bau-innen.sh || rc=$?
	[ $rc = 0 ] || fehler "$QUELLE: Bau fehlgeschlagen (rc $rc, Logs in $W/out/log)"
	local min=$(( (SECONDS - t0) / 60 ))
	echo "Bauzeit $min min"
	# Pruefung aus paket.conf (Shell, laeuft im Ergebnisordner mit den .deb)
	if [ -n "$PRUEFEN" ]; then
		(cd "$W/out" && eval "$PRUEFEN") > "$W/pruefung.log" 2>&1 || { cat "$W/pruefung.log"; fehler "$QUELLE: PRUEFEN fehlgeschlagen"; }
		cat "$W/pruefung.log"
	fi
	# Ergebnisordner: Binaerpakete, Quellpaket (.dsc und die Dateien, die sie nennt), Stand, Bauinfo, Pruefsummen
	E=$W/ergebnis
	mkdir -p "$E"
	mv "$W"/out/*.deb "$W/out/${QUELLE}_$FASSUNG_DATEI.dsc" "$E/"
	for f in $(dsc_dateien "$E/${QUELLE}_$FASSUNG_DATEI.dsc"); do mv "$W/out/$f" "$E/"; done
	printf 'quelle=%s\nfassung=%s\nschluessel=%s\n' "$QUELLE" "$FASSUNG" "$K" > "$E/STAND"
	(cd "$E" && sha256sum -- *.deb *.dsc $(dsc_dateien ./*.dsc)) > "$E/SHA256SUMS"
	{
		echo "# $QUELLE $FASSUNG, gebaut $(date -u '+%F %T') UTC mit bau.sh auf $(uname -m)"
		echo "schluessel=$K"
		echo "pakete_commit=$(git -C "$R" describe --always --dirty 2>/dev/null || echo -)"
		echo "bauimage=$BAUIMG $(docker image inspect -f '{{.Id}}' "$BAUIMG")"
		echo "bauzeit_min=$min"
	} > "$E/BUILDINFO"
	cp "$W/out/patches.txt" "$E/"
	cp "$W/out/log/vergleich.txt" "$E/" 2>/dev/null || true
	[ ! -f "$W/pruefung.log" ] || cp "$W/pruefung.log" "$E/"
	ins_repo "$E"
	cat "$E/patches.txt"
	grep '\.deb$' "$E/SHA256SUMS"
	# Platz: Pakete und Quellen liegen jetzt im Repo-Pool (mit PAKETE_ERGEBNIS auch dort); im Bauordner bleiben
	# Logs, .buildinfo, .changes, EINGABEN, STAND, BUILDINFO, SHA256SUMS. Aeltere Bauordner dieser Quelle entfallen.
	if [ -n "${PAKETE_ERGEBNIS:-}" ]; then
		mkdir -p "$PAKETE_ERGEBNIS/$QUELLE"
		find "$PAKETE_ERGEBNIS/$QUELLE" -mindepth 1 -delete
		cp -a "$E"/. "$PAKETE_ERGEBNIS/$QUELLE/"
	fi
	cp "$E/STAND" "$E/BUILDINFO" "$E/SHA256SUMS" "$W/"
	find "$E" "$W/dateien" -delete
	find "$W/out" -maxdepth 1 -type f \( -name '*.orig.tar.*' -o -name '*.orig-*.tar.*' -o -name '*.debian.tar.*' \) -delete
	find "$O/bau/$QUELLE" -mindepth 1 -maxdepth 1 -type d ! -name "$FASSUNG_DATEI" -exec rm -rf {} +
}

# ---------------- Fertige Ergebnisse aus der CI holen (GitHub Actions, ein Artefakt je Paket) ----------------
# Artefakt <quelle>_<fassung ohne epoche>, Inhalt wie der Ergebnisordner. Genommen wird das neueste nicht
# abgelaufene Artefakt dieses Namens aus einem Lauf auf main; sein Schluessel muss zum Rezept hier passen.
# Ist keins mehr da (Artefakte verfallen nach 90 Tagen): CI-Lauf anstossen oder lokal bauen.
holen() {   # holen <quelle> <trotzdem 0|1>
	lade_conf "$1"
	local K name z run art ck
	K=$(schluessel)
	name=${QUELLE}_$FASSUNG_DATEI
	z=$(cd "$R" && gh api -X GET "repos/{owner}/{repo}/actions/artifacts" -f name="$name" -f per_page=100 --jq \
		'[.artifacts[] | select(.expired | not) | select(.workflow_run.head_branch == "main")] | sort_by(.created_at) | last | "\(.workflow_run.id) \(.id)"') \
		|| fehler "gh api: Artefakte nicht abfragbar (gh angemeldet, Remote auf GitHub?)"
	run=${z%% *} art=${z#* }
	[ -n "$run" ] && [ "$run" != null ] || fehler "$name: kein gueltiges Artefakt auf main (abgelaufen oder nie gebaut): CI-Lauf anstossen oder lokal bauen"
	mkdir -p "$O/ci/$name"
	find "$O/ci/$name" -mindepth 1 -delete
	(cd "$R" && gh run download "$run" -n "$name" -D "$O/ci/$name") || fehler "$name: Download aus Lauf $run fehlgeschlagen"
	ck=$(stand_wert schluessel "$O/ci/$name/STAND")
	if [ "$ck" != "$K" ]; then
		echo "$name: Schluessel in der CI $ck, Rezept hier $K (lokale Aenderungen, oder die CI hat diesen Stand noch nicht gebaut)" >&2
		[ "$2" = 1 ] || fehler "$name: Stand passt nicht zum Rezept (--trotzdem uebernimmt ihn dennoch)"
	fi
	log "$name: aus Lauf $run (Artefakt $art)"
	ins_repo "$O/ci/$name"
	find "$O/ci/$name" -delete
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
	dateien_kopieren "$N/dateien"
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
	[ -n "$(ls "$N"/out/patches-neu/ 2>/dev/null)" ] || [ -n "$(dateien)" ] \
		|| echo "HINWEIS: keine Patches mehr noetig, das Paket kann entfallen (Debian-Fassung nehmen)"
	if [ $ueb = 1 ]; then
		for p in "$R/$q"/patches/*.patch; do
			[ -f "$p" ] || continue
			n=$(basename "$p")
			if [ -f "$N/out/patches-neu/$n" ]; then cp "$N/out/patches-neu/$n" "$p"; else git -C "$R" rm -q "$p" 2>/dev/null || rm -f "$p"; fi
		done
		sed -i -e "s|^DEBIAN=.*|DEBIAN=$ziel|" -e "s|^DSC_SHA256=.*|DSC_SHA256=$neu_sum|" -e "s|^REVISION=.*|REVISION=1|" "$R/$q/paket.conf"
		echo "uebernommen in $R/$q (pruefen mit git -C $R diff, dann ./bau.sh bau $q)"
	else
		rm -rf "$O/dl/$q/$oe"
		echo "trocken: nichts geaendert. Uebernehmen mit: ./bau.sh nachziehen $q $ziel --suite $s --uebernehmen"
		echo "  (DEBIAN=$ziel DSC_SHA256=$neu_sum REVISION=1)"
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
		"DSC_SHA256=$(sha256sum < "$O/dl/$q/$oe/${q}_$oe.dsc" | cut -d' ' -f1)" REVISION=1 STATUS=aktiv 'IMAGE=""' IMAGE_AN=0 \
		'CHANGELOG=""' > "$R/$q/paket.conf"
	echo "angelegt: $R/$q/paket.conf (Patches im DEP-3-Format nach $R/$q/patches/, Dateien nach $R/$q/dateien/)"
}

liste() {
	local f st
	printf '%-14s %-26s %-7s %-6s %s\n' QUELLE FASSUNG STATUS IMAGE "REPO (Schluessel)"
	for f in "$R"/*/paket.conf; do
		lade_conf "$(basename "$(dirname "$f")")"
		st=$(stand_wert fassung "$O/repo/stand/$QUELLE")
		[ -z "$st" ] && st="nicht gebaut" || st="$st ($(stand_wert schluessel "$O/repo/stand/$QUELLE"))"
		printf '%-14s %-26s %-7s %-6s %s\n' "$QUELLE" "$FASSUNG" "$STATUS" "$IMAGE_AN" "$st"
	done
}

hilfe() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 2; }
waehle() {   # waehle <argumente...>: Paketnamen aus Namen, alle und image; setzt qs und opt
	local a
	qs= opt=
	for a in "$@"; do
		case $a in alle|image) qs="$qs $(alle_pakete "$a" | tr '\n' ' ')" ;; -*) opt="$opt $a" ;; *) qs="$qs $a" ;; esac
	done
}
CMD=${1:-}
[ $# -gt 0 ] && shift
case "$CMD" in
	bau)
		waehle "$@"
		neu=0
		for a in $opt; do case $a in --neu) neu=1 ;; *) fehler "unbekannte Option $a" ;; esac; done
		[ -n "${qs// /}" ] || { [ "$*" = image ] || [ "$*" = alle ] || hilfe; echo "keine Pakete fuer $*"; exit 0; }
		images
		for q in $qs; do ( bau "$q" "$neu" ); done
		;;
	holen)
		waehle "$@"
		trotzdem=0
		for a in $opt; do case $a in --trotzdem) trotzdem=1 ;; *) fehler "unbekannte Option $a" ;; esac; done
		[ -n "${qs// /}" ] || hilfe
		command -v gh > /dev/null || fehler "holen braucht die GitHub-CLI gh (angemeldet)"
		images
		for q in $qs; do ( holen "$q" "$trotzdem" ); done
		;;
	einlegen)
		[ $# -ge 1 ] || hilfe
		images
		for d in "$@"; do ( ins_repo "$d" ); done
		;;
	pruefen) pruefen ;;
	nachziehen) [ $# -ge 1 ] || hilfe; nachziehen "$@" ;;
	liste) liste ;;
	anlegen) [ $# -ge 1 ] || hilfe; anlegen "$@" ;;
	namen) [ $# = 1 ] || hilfe; alle_pakete "$1" ;;
	schluessel) lade_conf "${1:?quelle}"; schluessel_teile; echo "fassung=$FASSUNG"; echo "schluessel=$(schluessel)" ;;
	*) hilfe ;;
esac
exit
}
