#!/usr/bin/env bash
# Reproducible AArch64 build for the public multi-firmware runtime.
# Debian Buster supplies libc; the current NextOS sysroot supplies API headers
# only.  No library from the newer sysroot is linked into the result.
set -euo pipefail
umask 022

PORT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# NC_BENCH_BUILD=1 compila a VARIANTE DE BANCADA (-DNC_BENCH: pad virtual,
# sonda de diagnóstico, captura sob demanda) em build/bench/. Nunca entra no
# ZIP: a build pública não compila esses caminhos e o gate abaixo prova que as
# strings não existem no ELF público.
NC_BENCH_BUILD=${NC_BENCH_BUILD:-0}
if [[ $NC_BENCH_BUILD == 1 ]]; then
  OUTPUT=${NC_OUTPUT:-build/bench/namelesscat-nextos}
  BENCH_CFLAGS=(-DNC_BENCH=1)
else
  OUTPUT=${NC_OUTPUT:-build/namelesscat-nextos}
  BENCH_CFLAGS=()
fi
BUILDER_IMAGE=playfetch-builder:buster
BUILDER_IMAGE_ID=sha256:036c7910ea53bc78cc213452afa92fa83d55de1c51ae54f315af58b5a41a45cf
export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1786233600}

fail() {
  printf 'namelesscat universal build error: %s\n' "$*" >&2
  exit 1
}

case $OUTPUT in
  build/*) ;;
  *) fail "NC_OUTPUT must be a relative child of build/" ;;
esac

if [[ ${NC_BUSTER_IN_CONTAINER:-0} != 1 ]]; then
  NEXTOS_ROOT=${NEXTOS_ROOT:-/mnt/ARQUIVOS/NextOS-Elite-Edition}
  NXSR=
  while IFS= read -r candidate; do
    [[ -d $candidate/aarch64-libreelec-linux-gnu/sysroot/usr/include/SDL2 ]] || continue
    NXSR=$candidate/aarch64-libreelec-linux-gnu/sysroot
  done < <(
    find -H "$NEXTOS_ROOT" -maxdepth 2 -type d \
      -path '*/build.NextOS-Retro-Elite-Edition-Amlogic-old.aarch64-*/toolchain' \
      -print | sort -V
  )
  [[ -n $NXSR ]] || fail "NextOS API-header sysroot was not found"
  command -v docker >/dev/null 2>&1 || fail "docker is required"
  ACTUAL_IMAGE_ID=$(docker image inspect "$BUILDER_IMAGE" \
    --format '{{.Id}}' 2>/dev/null) || fail "offline builder image is missing"
  [[ $ACTUAL_IMAGE_ID == "$BUILDER_IMAGE_ID" ]] ||
    fail "builder image identity changed: $ACTUAL_IMAGE_ID"
  exec docker run --rm --network none \
    -e NC_BUSTER_IN_CONTAINER=1 \
    -e NC_OUTPUT="$OUTPUT" \
    -e NC_BENCH_BUILD="$NC_BENCH_BUILD" \
    -e NC_HOST_UID="$(id -u)" \
    -e NC_HOST_GID="$(id -g)" \
    -e LC_ALL=C -e TZ=UTC -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -v "$PORT_DIR":/repo \
    -v "$NXSR":/nxsr:ro \
    "$BUILDER_IMAGE_ID" bash /repo/build_universal.sh
fi

for tool in aarch64-linux-gnu-gcc aarch64-linux-gnu-nm \
            aarch64-linux-gnu-readelf aarch64-linux-gnu-strip file strings; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing builder tool: $tool"
done

CC=aarch64-linux-gnu-gcc
NM=aarch64-linux-gnu-nm
READELF=aarch64-linux-gnu-readelf
STRIP=aarch64-linux-gnu-strip
cd /repo
mkdir -p build

OBJDIR=$(mktemp -d)
STUBDIR=$(mktemp -d)
cleanup() {
  find "$OBJDIR" "$STUBDIR" -type f -delete 2>/dev/null || true
  rmdir "$OBJDIR" "$STUBDIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# The port's own sources plus the vendored nxinput seam and nxgl frame-proof
# adapter, each pinned byte-for-byte against its framework authority.
python3 - vendor/nxinput vendor/nxgl <<'PY'
import hashlib, json, os, sys
for root in sys.argv[1:]:
    pins = json.load(open(os.path.join(root, "PINS.json")))
    for rel, digest in pins["files"].items():
        if hashlib.sha256(open(os.path.join(root, rel), "rb").read()).hexdigest() != digest:
            raise SystemExit("vendored framework file drifted from PINS.json: %s/%s" % (root, rel))
PY
mapfile -t SOURCES < <(
  { find src -maxdepth 1 -type f -name '*.c' -print
    find vendor/nxinput/src -maxdepth 1 -type f -name '*.c' -print
    find vendor/nxinput/engine-glue -maxdepth 1 -type f -name '*.c' -print
    printf '%s\n' vendor/nxgl/adapters/nxgl_frame_proof_adapter.c; } | sort)
[[ ${#SOURCES[@]} -gt 0 ]] || fail "no C sources found"
OBJS=()
for source in "${SOURCES[@]}"; do
  object=$OBJDIR/$(basename "${source%.c}").o
  "$CC" -std=gnu11 -I src -I vendor/nxinput/include -I vendor/nxinput/engine-glue \
    -I vendor/nxgl/adapters \
    -idirafter /nxsr/usr/include -idirafter /nxsr/usr/include/SDL2 \
    -O2 -fPIE -fno-strict-aliasing -fno-omit-frame-pointer "${BENCH_CFLAGS[@]}" \
    -ffile-prefix-map=/repo=. -fdebug-prefix-map=/repo=. \
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
    -c "$source" -o "$object"
  OBJS+=("$object")
done

# Record the stable firmware SDL2 SONAME without importing a newer firmware
# libc through its SDL binary.
UNDEFINED=$(
  "$NM" --undefined-only "${OBJS[@]}" 2>/dev/null |
    awk '{print $NF}' | sort -u
)
: > "$STUBDIR/sdl.c"
while IFS= read -r symbol; do
  [[ $symbol == SDL_* ]] || continue
  printf 'void %s(void) {}\n' "$symbol" >> "$STUBDIR/sdl.c"
done <<< "$UNDEFINED"
"$CC" -shared -fPIC -nostdlib -Wl,-soname,libSDL2-2.0.so.0 \
  "$STUBDIR/sdl.c" -o "$STUBDIR/libSDL2.so"

mkdir -p "$(dirname -- "$OUTPUT")"
"$CC" -fPIE -pie -rdynamic -o "$OUTPUT" "${OBJS[@]}" \
  -L"$STUBDIR" -Wl,--no-as-needed -lSDL2 -Wl,--as-needed \
  -ldl -lm -lpthread -lz -lgcc_s \
  -Wl,--build-id=sha1 -Wl,-z,relro,-z,now,-z,noexecstack
"$STRIP" --strip-unneeded "$OUTPUT"
chmod 0755 "$OUTPUT"

MAX_GLIBC=$(
  "$READELF" --version-info "$OUTPUT" |
    grep -oE 'GLIBC_[0-9]+([.][0-9]+)*' | sort -Vu | tail -1
)
[[ -n $MAX_GLIBC ]] || fail "could not determine GLIBC requirement"
version=${MAX_GLIBC#GLIBC_}
major=${version%%.*}
minor=${version#*.}
minor=${minor%%.*}
if (( major > 2 || (major == 2 && minor > 30) )); then
  fail "$OUTPUT requires $MAX_GLIBC (limit GLIBC_2.30)"
fi

MACHINE=$("$READELF" -h "$OUTPUT" |
  sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')
[[ $MACHINE == AArch64 ]] || fail "unexpected ELF machine: $MACHINE"
INTERPRETER=$("$READELF" -lW "$OUTPUT" |
  sed -n 's/.*Requesting program interpreter: \([^]]*\)].*/\1/p')
[[ $INTERPRETER == /lib/ld-linux-aarch64.so.1 ]] ||
  fail "unexpected PT_INTERP: $INTERPRETER"
if "$READELF" -lW "$OUTPUT" |
    awk '$1 == "LOAD" && $0 ~ /RWE/ {bad=1} END {exit !bad}'; then
  fail "RWX PT_LOAD is forbidden"
fi
if "$READELF" -dW "$OUTPUT" | grep -Eq '\((RPATH|RUNPATH)\)'; then
  fail "DT_RPATH/DT_RUNPATH is forbidden"
fi

# Identidade do runtime vivo de controles (nxinput 0.10.1, GPTK V3): o
# nxrelease casa estas strings exatas no ELF; a família de fallback genérico
# em quarentena e o marcador /2 jamais podem reaparecer.  `strings | grep -c`
# consome o stream inteiro (grep -q sob pipefail mataria o strings com SIGPIPE).
STRINGS_OUT=$(strings -a "$OUTPUT")
for required in "nxinput-gptk-runtime/3" "nxinput-gptk-event-evidence/1" \
                "nxinput-gptk-load-evidence/1" "NXC6-DOMAIN" \
                "/usr/lib/gamecontrollerdb.txt"; do
  [[ $(printf '%s\n' "$STRINGS_OUT" | grep -Fc -- "$required") -gt 0 ]] ||
    fail "live GPTK identity missing from the ELF: $required"
done
# A build pública não pode conter NENHUM caminho de injeção de bancada.
if [[ $NC_BENCH_BUILD != 1 ]]; then
  for forbidden in NC_VPAD NC_VPAD_FILE NC_INPUT_DIAG /tmp/namelesscat-vpad \
                   "[nc/vpad]" shot_req_ "[nc/diag]"; do
    [[ $(printf '%s\n' "$STRINGS_OUT" | grep -Fc -- "$forbidden") -eq 0 ]] ||
      fail "bench-only injection path present in the public ELF: $forbidden"
  done
fi
for forbidden in "nxinput-gptk-runtime/2" "nxinput-gptk-runtime/1" \
                 "nx_add_generic_gamepad_mappings" "Generic Xbox Fallback" \
                 "Microsoft X-Box 360 pad" "/dev/input/event" \
                 "gptokeyb"; do
  [[ $(printf '%s\n' "$STRINGS_OUT" | grep -Fc -- "$forbidden") -eq 0 ]] ||
    fail "forbidden identity present in the ELF: $forbidden"
done
DYNSYMS=$("$READELF" --dyn-syms -W "$OUTPUT" | awk '$4 == "FUNC" && $5 == "GLOBAL" {print $8}')
for symbol in nxinput_gptk_load_at nxinput_gptk_load_receipt_json \
              nxinput_gptk_parse nxinput_gptk_decide nxinput_gptk_live_init \
              nxinput_gptk_live_register nxinput_gptk_live_register_vector \
              nxinput_gptk_live_seal nxinput_gptk_live_set_context \
              nxinput_gptk_live_clear_context nxinput_gptk_live_should_consume \
              nxinput_gptk_live_feed nxinput_gptk_live_feed_vector \
              nxinput_gptk_runtime_marker nxinput_gptk_event_evidence_schema \
              nc_sink_engine_input_jump nc_sink_engine_input_interact \
              nc_sink_engine_input_down nc_sink_engine_ui_accept \
              nc_sink_engine_input_pause nc_sink_adapter_system_quit \
              nc_sink_adapter_pointer_click nc_sink_engine_input_move \
              nc_sink_adapter_pointer_move; do
  [[ $(printf '%s\n' "$DYNSYMS" | grep -Fcx -- "$symbol") -gt 0 ]] ||
    fail "live GPTK boundary symbol not defined/exported: $symbol"
done

PAD_LAYOUT=$("$READELF" -sW "$OUTPUT" |
  awk '$4 == "TLS" && $8 == "g_bionic_guard_pad" {
    value = $2 ":" $3
  } END { print value }')
[[ $PAD_LAYOUT == 0000000000000000:256 ]] ||
  fail "Bionic guard-pad TLS layout changed: $PAD_LAYOUT"

if [[ -n ${NC_HOST_UID:-} && -n ${NC_HOST_GID:-} ]]; then
  chown "$NC_HOST_UID:$NC_HOST_GID" "$OUTPUT" 2>/dev/null || true
fi

printf 'NAMELESS CAT UNIVERSAL BUILD OK -> %s\n' "$OUTPUT"
printf 'maximum glibc: %s (limit GLIBC_2.30)\n' "$MAX_GLIBC"
printf 'Bionic TLS guard pad: %s\n' "$PAD_LAYOUT"
file "$OUTPUT"
sha256sum "$OUTPUT"
