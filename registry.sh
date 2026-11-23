#!/bin/sh
# Veroeffentlicht die gebauten Pakete in der APT-Registry (Forgejo, codeberg.org/moblix) und haelt sie sauber.
#
#   ./registry.sh hochladen <ordner>            alle *.deb unter <ordner> hochladen (ohne *-dbgsym)
#   ./registry.sh pruefen <ordner>              Index der Registry gegen die Dateien unter <ordner> pruefen (sha256)
#   ./registry.sh aufraeumen <ordner> [--probe] aeltere Fassungen unserer Quellpakete aus der Registry loeschen
#
# <ordner> ist der Ergebnisordner eines Laufs (CI: alle Artefakte <quelle>_<fassung>), er muss ALLE Pakete des
# Laufs enthalten. Umgebung: CODEBERG_TOKEN (hochladen, aufraeumen), REGISTRY, REG_SUITE, REG_KOMPONENTE.
#
# Signatur: Den Index (InRelease) signiert die Registry mit ihrem eigenen Schluessel, apt prueft ihn und ueber die
# sha256 im Index jede Datei. Die Pakete selbst werden nicht signiert (wie bei Debian). "pruefen" stellt sicher,
# dass der signierte Index genau die Dateien dieses Laufs beschreibt.
#
# aufraeumen: wie im Debian-Archiv bleibt je Paket nur die aktuelle Fassung. Geloescht wird ein Eintrag der
# Registry, wenn er zu einem Quellpaket dieses Laufs gehoert (Feld Source) und aelter ist als die Fassung dieses
# Laufs: eine aeltere Fassung desselben Pakets, oder ein Paket, das die Quelle nicht mehr baut (z. B. nach einem
# Wechsel des Bibliotheksnamens). Neuere Fassungen und Pakete anderer Quellen (andere Repos, die in dieselbe
# Registry liefern) bleiben unberuehrt. Ein Quellpaket, das es hier gar nicht mehr gibt, raeumt niemand auf.
set -eu

REGISTRY=${REGISTRY:-https://codeberg.org/api/packages/moblix/debian}
REG_SUITE=${REG_SUITE:-testing}
REG_KOMPONENTE=${REG_KOMPONENTE:-main}

ende() { echo "registry.sh: $*" >&2; exit 1; }
zeile() { [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "$*" >> "$GITHUB_STEP_SUMMARY"; }
meldung() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::$1::$2"; else echo "$1: $2" >&2; fi; }

debs() { find "$1" -name '*.deb' ! -name '*-dbgsym_*' | sort; }

# Dateien des Laufs: <paket> <fassung> <architektur> <quelle> <sha256> <datei>
stand() {
	debs "$1" | while read -r d; do
		dpkg-deb -W --showformat='${Package}\t${Version}\t${Architecture}\t${Source}\n' "$d" \
			| awk -F'\t' -v s="$(sha256sum "$d" | cut -d' ' -f1)" -v d="$d" \
				'{q = $4; sub(/ .*/, "", q); if (q == "") q = $1; print $1, $2, $3, q, s, d}'
	done
}

# Index der Registry: <paket> <fassung> <architektur> <quelle> <sha256>
index() {
	rel=$(curl -fsS -m 60 "$REGISTRY/dists/$REG_SUITE/Release") || ende "Release der Registry nicht lesbar"
	for a in $(printf '%s\n' "$rel" | sed -n 's/^Architectures: //p'); do
		curl -fsS -m 120 "$REGISTRY/dists/$REG_SUITE/$REG_KOMPONENTE/binary-$a/Packages" || ende "Packages ($a) nicht lesbar"
		echo
	done | awk '
		function aus() { if (p != "") print p, v, a, (q == "" ? p : q), h; p = v = a = q = h = "" }
		/^$/ { aus(); next }
		/^Package: / { p = $2 } /^Version: / { v = $2 } /^Architecture: / { a = $2 }
		/^Source: / { q = $2 } /^SHA256: / { h = $2 }
		END { aus() }'
}

[ $# -ge 2 ] || ende "Aufruf: registry.sh hochladen|pruefen|aufraeumen <ordner> [--probe]"
B=$1 O=$2 PROBE=${3:-}
[ -d "$O" ] || ende "$O ist kein Ordner"
[ -n "$(debs "$O")" ] || ende "keine Pakete unter $O"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

case $B in
hochladen)
	[ -n "${CODEBERG_TOKEN:-}" ] || ende "CODEBERG_TOKEN ist nicht gesetzt"
	zeile '| package | upload |'; zeile '|---|---|'
	fehler=0
	for d in $(debs "$O"); do
		code=$(curl -sS -m 600 --retry 3 -o /dev/null -w '%{http_code}' -H "Authorization: token $CODEBERG_TOKEN" \
			--upload-file "$d" "$REGISTRY/pool/$REG_SUITE/$REG_KOMPONENTE/upload") || code=000
		case $code in
		201) erg=published ;;
		409) erg='already there' ;;
		*) erg="failed (HTTP $code)"; fehler=1; meldung error "$(basename "$d"): upload HTTP $code" ;;
		esac
		echo "$(basename "$d"): $erg"; zeile "| $(basename "$d") | $erg |"
	done
	exit $fehler
	;;
pruefen)
	stand "$O" > "$T/lauf"; index > "$T/index"
	fehler=0
	while read -r p v a q s d; do
		h=$(awk -v p="$p" -v v="$v" -v a="$a" '$1 == p && $2 == v && $3 == a {print $5}' "$T/index")
		if [ -z "$h" ]; then
			fehler=1; meldung error "$p $v $a fehlt im Index der Registry"
		elif [ "$h" != "$s" ]; then
			# gleiche Fassung, anderer Inhalt: die Registry behaelt den ersten Upload (z. B. Neubau nach Cache-Verlust)
			meldung warning "$p $v $a: die Registry hat einen anderen Bau dieser Fassung (sha256 $h, dieser Lauf $s)"
		fi
	done < "$T/lauf"
	[ $fehler = 0 ] && echo "Index der Registry passt zu $(wc -l < "$T/lauf") Paketen"
	exit $fehler
	;;
aufraeumen)
	[ "$PROBE" = --probe ] || [ -n "${CODEBERG_TOKEN:-}" ] || ende "CODEBERG_TOKEN ist nicht gesetzt"
	stand "$O" > "$T/lauf"; index > "$T/index"
	# hoechste Fassung je Quelle in diesem Lauf (fuer Pakete, die die Quelle nicht mehr baut)
	cut -d' ' -f4 "$T/lauf" | sort -u | while read -r q; do
		m=
		for v in $(awk -v q="$q" '$4 == q {print $2}' "$T/lauf"); do
			if [ -z "$m" ] || dpkg --compare-versions "$v" gt "$m"; then m=$v; fi
		done
		echo "$q $m"
	done > "$T/quellen"
	zeile ''; zeile '| removed from the registry | version |'; zeile '|---|---|'
	fehler=0 n=0
	while read -r p v a q h; do
		grenze=$(awk -v p="$p" -v a="$a" '$1 == p && $3 == a {print $2}' "$T/lauf")
		[ -n "$grenze" ] || grenze=$(awk -v q="$q" '$1 == q {print $2}' "$T/quellen")
		[ -n "$grenze" ] || continue   # Quelle gehoert nicht zu diesem Lauf
		dpkg --compare-versions "$v" lt "$grenze" || continue
		n=$((n + 1))
		if [ "$PROBE" = --probe ]; then echo "wuerde loeschen: $p $v $a (aktuell $grenze)"; continue; fi
		code=$(curl -sS -m 120 -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: token $CODEBERG_TOKEN" \
			"$REGISTRY/pool/$REG_SUITE/$REG_KOMPONENTE/$p/$v/$a") || code=000
		if [ "$code" = 204 ]; then echo "geloescht: $p $v $a"; zeile "| $p ($a) | $v |"
		else fehler=1; meldung error "$p $v $a: loeschen HTTP $code"; fi
	done < "$T/index"
	[ $n != 0 ] || { echo "nichts aufzuraeumen"; zeile '| (nothing) | |'; }
	exit $fehler
	;;
*) ende "unbekannter Befehl $B" ;;
esac
