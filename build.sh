#!/usr/bin/env bash
# Builds the OpenWrt image for the Sipeed LicheeRV Nano WE. See README.md.
#
#   ./build.sh                 run every stage that hasn't finished yet
#   ./build.sh --redo STAGE    rerun STAGE and every stage after it
#   ./build.sh --status        show which stages have finished
#
# Environment: JOBS (default: nproc), WIFI_KEY (default: random, 16 letters).

set -euo pipefail

TOP=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
STATE=$TOP/.build
OUT=$TOP/output
WRT=$TOP/openwrt
JOBS=${JOBS:-$(nproc)}
STAGES=(submodules patches feeds config wifi-key image)
KEYFILE=$WRT/files/etc/licheewrt-wifi-key

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

stage_submodules() {
	git -C "$TOP" submodule sync --quiet
	git -C "$TOP" submodule update --init --depth 1
}

# Puts openwrt on a local branch at the pinned commit, then applies the port.
# Local changes to files OpenWrt tracks are discarded. Untracked files, such as
# dl/, build_dir/ and files/, are kept.
stage_patches() {
	local pin
	# The pin comes from the index, so `git add openwrt` after
	# `git submodule update --remote` is enough to build on a newer OpenWrt.
	pin=$(git -C "$TOP" ls-files -s openwrt | awk '{print $2}')
	[ -n "$pin" ] || die "openwrt is not a submodule of this repository"
	git -C "$WRT" am --abort >/dev/null 2>&1 || true
	git -C "$WRT" checkout --quiet --force -B licheervnano "$pin"
	# --keep-cr: the AIC8800 package carries patches for CRLF source files.
	git -C "$WRT" -c user.name=licheervnano-build -c user.email=build@localhost \
		am --quiet --keep-cr "$TOP"/patches/openwrt/*.patch
	git -C "$WRT" log --oneline "$pin"..HEAD
}

stage_feeds() {
	local f
	: > "$WRT/feeds.conf"
	for f in packages luci routing telephony video; do
		echo "src-link $f $TOP/feeds/$f" >> "$WRT/feeds.conf"
	done
	(cd "$WRT" && ./scripts/feeds update -a && ./scripts/feeds install -a) >/dev/null
	echo "feeds installed from $TOP/feeds"
}

stage_config() {
	cp "$TOP/configs/licheervnano.seed" "$WRT/.config"
	make -C "$WRT" defconfig >/dev/null
	echo "config loaded from configs/licheervnano.seed"
}

stage_wifi-key() {
	local key=${WIFI_KEY:-}
	# head runs first, so tr never writes into a closed pipe under pipefail.
	if [ -z "$key" ]; then
		while [ ${#key} -lt 16 ]; do
			key+=$(head -c 64 /dev/urandom | LC_ALL=C tr -dc 'a-z')
		done
		key=${key:0:16}
	fi
	[ ${#key} -ge 8 ] && [ ${#key} -le 63 ] || die "WIFI_KEY must be 8 to 63 characters"
	mkdir -p "$(dirname "$KEYFILE")"
	printf '%s\n' "$key" > "$KEYFILE"
	chmod 600 "$KEYFILE"
	echo "Wi-Fi password for this build: $key"
}

stage_image() {
	local img name
	make -C "$WRT" -j"$JOBS" download
	if ! make -C "$WRT" -j"$JOBS"; then
		die "build failed. For the error, run: make -C openwrt -j1 V=s"
	fi
	img=$(ls "$WRT"/bin/targets/sophgo/generic/*-squashfs-sdcard.img.gz)
	name=licheervnano-openwrt-$(date +%F)-sdcard.img.gz
	mkdir -p "$OUT"
	cp "$img" "$OUT/$name"
	cp "$KEYFILE" "$OUT/wifi-password.txt"
	(cd "$OUT" && sha256sum "$name" > "$name.sha256")
	echo "image: output/$name"
	echo "Wi-Fi password: $(cat "$OUT/wifi-password.txt")"
}

done_marker() { echo "$STATE/$1.done"; }

case "${1:-}" in
	--redo)
		[ -n "${2:-}" ] || die "--redo needs a stage: ${STAGES[*]}"
		found=0
		for s in "${STAGES[@]}"; do
			[ "$s" = "$2" ] && found=1
			[ $found = 1 ] && rm -f "$(done_marker "$s")"
		done
		[ $found = 1 ] || die "unknown stage '$2'. Stages: ${STAGES[*]}"
		;;
	--status)
		for s in "${STAGES[@]}"; do
			[ -f "$(done_marker "$s")" ] && echo "done     $s" || echo "pending  $s"
		done
		exit 0
		;;
	"") ;;
	*) die "unknown option '$1'. See the top of $0" ;;
esac

case "$TOP" in *' '*) die "the path $TOP has a space in it, which breaks the OpenWrt build" ;; esac
mkdir -p "$STATE"
for s in "${STAGES[@]}"; do
	if [ -f "$(done_marker "$s")" ]; then
		echo "skip     $s (done)"
		continue
	fi
	log "$s"
	"stage_$s"
	touch "$(done_marker "$s")"
done
