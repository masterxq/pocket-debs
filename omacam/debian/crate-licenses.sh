#!/bin/sh
# crate-licenses.sh <vendor dir>: license field and license files of every vendored crate, for
# /usr/share/doc/omacam/crate-licenses.txt (the binary links the crates statically).
set -eu
for d in "$1"/*/; do
	d=${d%/}
	l=$(sed -n '/^\[package\]/,/^\[/s/^license = "\(.*\)"$/\1/p' "$d/Cargo.toml" | sed -n 1p)
	printf '==== %s (%s)\n' "$(basename "$d")" "${l:-see license file}"
	found=0
	for f in "$d"/LICENSE* "$d"/LICENCE* "$d"/COPYING* "$d"/UNLICENSE* "$d"/license* "$d"/NOTICE*; do
		[ -f "$f" ] || continue
		printf -- '---- %s\n' "${f#"$d"/}"
		cat "$f"
		found=1
	done
	[ $found = 1 ] || echo "(no license file in the crate)"
	echo
done
