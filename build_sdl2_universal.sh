#!/usr/bin/env bash
# Reproducible SDL2 C6 audit fixture. It is never a release/package input.
#
# This optional tool reproduces the nxinput C6 seam inside a pinned SDL build
# for provenance/compatibility experiments. The public port itself links the
# system SDL SONAME and ships no libSDL*.so; its in-process adapter performs
# admission before SDL_IsGameController/SDL_GameControllerOpen.
#
# Upstream SDL release-2.32.10 + the pinned seam patch + the vendored nxinput
# sources (vendor/nxinput, PINS.json) are built inside the offline Debian
# Buster container, so the result requires at most GLIBC_2.30 like every ELF
# in the public ZIP.  Video (KMSDRM/EGL/GLES2), audio (ALSA and PulseAudio,
# both dlopen'd at run time) and udev (dlopen'd) match what the firmware SDL
# offered on the proven devices; nothing is linked against the newer sysroot.
set -euo pipefail
umask 022

PORT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
BUILDER_IMAGE=playfetch-builder:buster
BUILDER_IMAGE_ID=sha256:036c7910ea53bc78cc213452afa92fa83d55de1c51ae54f315af58b5a41a45cf
SDL_VERSION=2.32.10
SDL_TARBALL_SHA256=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1786233600}

fail() {
  printf 'namelesscat sdl2 build error: %s\n' "$*" >&2
  exit 1
}

if [[ ${NC_BUSTER_IN_CONTAINER:-0} != 1 ]]; then
  TARBALL=${NC_SDL2_TARBALL:-}
  [[ -n $TARBALL && -f $TARBALL ]] ||
    fail "set NC_SDL2_TARBALL to the SDL2-$SDL_VERSION.tar.gz file"
  actual=$(sha256sum -- "$TARBALL" | cut -c1-64)
  [[ $actual == "$SDL_TARBALL_SHA256" ]] ||
    fail "SDL tarball SHA-256 mismatch: $actual"
  NEXTOS_ROOT=${NEXTOS_ROOT:-/mnt/ARQUIVOS/NextOS-Elite-Edition}
  NXSR=
  while IFS= read -r candidate; do
    [[ -f $candidate/aarch64-libreelec-linux-gnu/sysroot/usr/lib/pkgconfig/libpulse-simple.pc ]] || continue
    NXSR=$candidate/aarch64-libreelec-linux-gnu/sysroot
  done < <(
    find -H "$NEXTOS_ROOT" -maxdepth 2 -type d \
      -path '*/build.NextOS-Retro-Elite-Edition-Amlogic-old.aarch64-*/toolchain' \
      -print | sort -V
  )
  # PulseAudio API HEADERS only (SDL dlopens libpulse-simple at run time);
  # no library from that sysroot is ever linked.
  [[ -n $NXSR ]] || fail "NextOS API-header sysroot with PulseAudio headers was not found"
  command -v docker >/dev/null 2>&1 || fail "docker is required"
  ACTUAL_IMAGE_ID=$(docker image inspect "$BUILDER_IMAGE" \
    --format '{{.Id}}' 2>/dev/null) || fail "offline builder image is missing"
  [[ $ACTUAL_IMAGE_ID == "$BUILDER_IMAGE_ID" ]] ||
    fail "builder image identity changed: $ACTUAL_IMAGE_ID"
  exec docker run --rm --network none \
    -e NC_BUSTER_IN_CONTAINER=1 \
    -e NC_HOST_UID="$(id -u)" \
    -e NC_HOST_GID="$(id -g)" \
    -e LC_ALL=C -e TZ=UTC -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -v "$PORT_DIR":/repo \
    -v "$TARBALL":/sdl2.tar.gz:ro \
    -v "$NXSR":/nxsr:ro \
    "$BUILDER_IMAGE_ID" bash /repo/build_sdl2_universal.sh
fi

for tool in aarch64-linux-gnu-gcc aarch64-linux-gnu-readelf aarch64-linux-gnu-strip \
            cmake patch tar strings; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing builder tool: $tool"
done
READELF=aarch64-linux-gnu-readelf
STRIP=aarch64-linux-gnu-strip
cd /repo
mkdir -p build/lib build/sdl2-provenance

WORK=$(mktemp -d)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

actual=$(sha256sum /sdl2.tar.gz | cut -c1-64)
[[ $actual == "$SDL_TARBALL_SHA256" ]] || fail "tarball drifted inside the container"
tar -xzf /sdl2.tar.gz -C "$WORK"
TREE=$WORK/SDL2-$SDL_VERSION
[[ -d $TREE/src/joystick/linux ]] || fail "unexpected tarball layout"

# --- the seam: pinned patch + vendored nxinput sources (PINS.json) --------
python3 - /repo/vendor/nxinput <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
pins = json.load(open(os.path.join(root, "PINS.json")))
for rel, digest in pins["files"].items():
    actual = hashlib.sha256(open(os.path.join(root, rel), "rb").read()).hexdigest()
    if actual != digest:
        raise SystemExit("vendored nxinput file drifted from PINS.json: %s" % rel)
print("vendored nxinput %s from framework %s: %d files verified" %
      (pins["nxinput_version"], pins["framework_commit"][:12], len(pins["files"])))
PY
PATCH=/repo/vendor/nxinput/engine-patches/sdl2-$SDL_VERSION-nxc6-seam.patch
PRISTINE_SHA=$(sha256sum "$TREE/src/joystick/linux/SDL_sysjoystick.c" | cut -c1-64)
patch -p1 -d "$TREE" --forward --silent < "$PATCH" || fail "seam patch did not apply"
PATCHED_SHA=$(sha256sum "$TREE/src/joystick/linux/SDL_sysjoystick.c" | cut -c1-64)
python3 - /repo/vendor/nxinput/engine-patches/C6-SDL-PROVENANCE.json "$PRISTINE_SHA" "$PATCHED_SHA" <<'PY'
import json, sys
prov = json.load(open(sys.argv[1]))["sdl"]["sdl2-2.32.10"]
if prov["pristine_sha256"] != sys.argv[2]:
    raise SystemExit("pristine SDL_sysjoystick.c does not match the C6 provenance pin")
if prov["patched_sha256"] != sys.argv[3]:
    raise SystemExit("patched SDL_sysjoystick.c does not match the C6 provenance pin")
print("seam patch chain matches framework C6 provenance (pristine and patched)")
PY
for f in engine-glue/nxc6_glue.c engine-glue/nxc6_glue.h \
         src/nxinput_sdl_seam.c include/nxinput_sdl_seam.h \
         src/nxinput_portmaster.c include/nxinput_portmaster.h \
         src/nxinput_sdl.c include/nxinput_sdl.h \
         src/nxinput_godot.c include/nxinput_godot.h \
         src/nxinput_sovereign.c include/nxinput_sovereign.h \
         src/nxinput_authority.c include/nxinput_authority.h; do
  cp -f "/repo/vendor/nxinput/$f" "$TREE/src/joystick/linux/$(basename "$f")"
done

# --- PulseAudio headers only: a private pkg-config view of the sysroot -----
# Only the pulse/ header tree is exposed, copied into a private directory:
# pointing includedir at the whole sysroot would put its newer glibc headers
# ahead of Buster's for every SDL source (vsscanf -> __isoc23_vsscanf, a
# GLIBC_2.38 symbol) and break the low-glibc contract.
PKG=$WORK/pkgconfig
INC=$WORK/pulse-include
mkdir -p "$PKG" "$INC"
[[ -d /nxsr/usr/include/pulse ]] || fail "missing pulse/ headers in the header sysroot"
cp -r /nxsr/usr/include/pulse "$INC/pulse"
# SDL's dynamic-pulse mode only READS the SONAME of libpulse-simple/libpulse
# (FindLibraryAndSONAME) to know what to dlopen at run time; the DT_NEEDED
# audit below proves nothing was linked against them.
mkdir -p "$INC/lib"
cp -P /nxsr/usr/lib/libpulse-simple.so* /nxsr/usr/lib/libpulse.so* "$INC/lib/"
for pc in libpulse-simple.pc libpulse.pc; do
  [[ -f /nxsr/usr/lib/pkgconfig/$pc ]] || fail "missing $pc in the header sysroot"
  sed -e "s|^prefix=.*|prefix=$INC|" -e "s|^exec_prefix=.*|exec_prefix=$INC|" \
      -e "s|^libdir=.*|libdir=$INC/lib|" -e "s|^includedir=.*|includedir=$INC|" \
      -e 's|^Requires.private:.*|Requires.private:|' \
      "/nxsr/usr/lib/pkgconfig/$pc" > "$PKG/$pc"
done

# --- build --------------------------------------------------------------------
BUILD=$TREE/build
PREFIX=$WORK/prefix
nice -n 10 env PKG_CONFIG_PATH="$PKG:/usr/lib/aarch64-linux-gnu/pkgconfig" \
  cmake -S "$TREE" -B "$BUILD" \
  -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=$TREE=SDL2-$SDL_VERSION -fdebug-prefix-map=$TREE=SDL2-$SDL_VERSION" \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF \
  -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_VULKAN=OFF -DSDL_OPENGL=OFF \
  -DSDL_KMSDRM=ON -DSDL_KMSDRM_SHARED=ON -DSDL_OPENGLES=ON \
  -DSDL_ALSA=ON -DSDL_ALSA_SHARED=ON \
  -DSDL_PULSEAUDIO=ON -DSDL_PULSEAUDIO_SHARED=ON \
  -DSDL_PIPEWIRE=OFF -DSDL_JACK=OFF -DSDL_SNDIO=OFF -DSDL_DBUS=OFF -DSDL_IBUS=OFF \
  -DSDL_HIDAPI=OFF -DSDL_LIBUDEV=ON \
  > build/sdl2-provenance/cmake.log 2>&1 || {
  tail -40 build/sdl2-provenance/cmake.log >&2
  fail "cmake configuration failed"
}
nice -n 10 cmake --build "$BUILD" -j2 > build/sdl2-provenance/build.log 2>&1 || {
  tail -40 build/sdl2-provenance/build.log >&2
  fail "SDL build failed"
}
cmake --install "$BUILD" > build/sdl2-provenance/install.log 2>&1 || fail "install failed"

LIB=$(ls "$PREFIX"/lib/libSDL2-2.0.so.0.*.* | head -1)
[[ -f $LIB ]] || fail "shared library was not produced"
OUT=build/lib/libSDL2-2.0.so.0
# The seam symbols are internal (hidden visibility): prove the linkage on the
# UNSTRIPPED library, then strip.  The stripped binary still carries the
# NXC6-SEAM receipt format string, checked below.
# grep -q would SIGPIPE readelf under pipefail on the first match; capture
# the table once instead.
"$READELF" -sW "$LIB" > "$WORK/symtab.txt"
grep -q 'nxc6_admit_before_announce' "$WORK/symtab.txt" || fail "seam entry point is not linked"
grep -q 'nxinput_sdl_seam_admit' "$WORK/symtab.txt" || fail "nxinput_sdl_seam_admit is not linked"
"$STRIP" --strip-unneeded "$LIB"
cp -f "$LIB" "$OUT"
chmod 0644 "$OUT"

# --- audits ---------------------------------------------------------------------
MAX_GLIBC=$("$READELF" --version-info "$OUT" |
  grep -oE 'GLIBC_[0-9]+([.][0-9]+)*' | sort -Vu | tail -1)
version=${MAX_GLIBC#GLIBC_}; major=${version%%.*}; minor=${version#*.}; minor=${minor%%.*}
if (( major > 2 || (major == 2 && minor > 30) )); then
  fail "$OUT requires $MAX_GLIBC (limit GLIBC_2.30)"
fi
NEEDED=$("$READELF" -dW "$OUT" | sed -n 's/.*NEEDED.*\[\(.*\)\].*/\1/p' | tr '\n' ' ')
for forbidden in libudev libpulse libasound libdrm libgbm libEGL libGLES; do
  case " $NEEDED " in *" $forbidden"*) fail "DT_NEEDED on $forbidden is forbidden (must stay dlopen): $NEEDED" ;; esac
done
SONAME=$("$READELF" -dW "$OUT" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')
[[ $SONAME == libSDL2-2.0.so.0 ]] || fail "unexpected SONAME: $SONAME"
strings "$OUT" | grep -q 'NXC6-SEAM' || fail "the seam receipt format string is not in the binary"
strings "$OUT" | grep -qx "SDL-$SDL_VERSION" ||
  strings "$OUT" | grep -q "release-$SDL_VERSION" || true

cat > build/sdl2-provenance/PROVENANCE.json <<JSON
{
  "schema": "namelesscat-private-sdl2-provenance/1",
  "sdl_version": "$SDL_VERSION",
  "tarball_sha256": "$SDL_TARBALL_SHA256",
  "seam_patch_sha256": "$(sha256sum "$PATCH" | cut -c1-64)",
  "pristine_sysjoystick_sha256": "$PRISTINE_SHA",
  "patched_sysjoystick_sha256": "$PATCHED_SHA",
  "vendored_nxinput": $(python3 -c 'import json;d=json.load(open("/repo/vendor/nxinput/PINS.json"));print(json.dumps({"framework_commit":d["framework_commit"],"nxinput_version":d["nxinput_version"]}))'),
  "builder_image": "$BUILDER_IMAGE_ID",
  "compiler": "$(aarch64-linux-gnu-gcc --version | head -1)",
  "max_glibc": "$MAX_GLIBC",
  "dt_needed": "$NEEDED",
  "output": "$OUT",
  "output_bytes": $(stat -c %s "$OUT"),
  "output_sha256": "$(sha256sum "$OUT" | cut -c1-64)"
}
JSON
if [[ -n ${NC_HOST_UID:-} && -n ${NC_HOST_GID:-} ]]; then
  chown -R "$NC_HOST_UID:$NC_HOST_GID" build/lib build/sdl2-provenance 2>/dev/null || true
fi
printf 'NAMELESS CAT PRIVATE SDL2 BUILD OK -> %s\n' "$OUT"
printf 'maximum glibc: %s (limit GLIBC_2.30)\nDT_NEEDED: %s\n' "$MAX_GLIBC" "$NEEDED"
sha256sum "$OUT"
