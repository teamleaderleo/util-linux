#!/usr/bin/env bash
set -euo pipefail

candidate=
outdir=
while (($#)); do
  case "$1" in
    --candidate) candidate=$2; shift 2 ;;
    --output-dir) outdir=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$candidate" && -x "$candidate" ]] || {
  echo "candidate is not executable: $candidate" >&2
  exit 2
}
[[ -n "$outdir" ]] || { echo "--output-dir is required" >&2; exit 2; }
mkdir -p "$outdir"

work=$(mktemp -d /tmp/lf-unit23-util-linux.XXXXXX)
trap 'rm -rf "$work"' EXIT

make_root() {
  local root=$1
  mkdir -p \
    "$root/proc" \
    "$root/sys/devices/system/cpu" \
    "$root/sys/devices/system/node/node0"
  cp /proc/cpuinfo "$root/proc/cpuinfo"
  printf '15\n' >"$root/sys/devices/system/cpu/kernel_max"
  printf '0-15\n' >"$root/sys/devices/system/cpu/possible"
  printf '0-15\n' >"$root/sys/devices/system/cpu/present"
  printf '0-15\n' >"$root/sys/devices/system/cpu/online"
  printf '0000ffff\n' >"$root/sys/devices/system/node/node0/cpumap"
}

run_case() {
  local pass=$1 case_name=$2 mode=$3 malformed=$4
  local root="$work/pass-${pass}-${case_name}-${mode}"
  make_root "$root"
  if [[ "$malformed" == yes ]]; then
    printf '5,12-%%\n' >"$root/sys/devices/system/cpu/online"
  fi

  local stdout="$outdir/pass-${pass}-${case_name}-${mode}.stdout"
  local stderr="$outdir/pass-${pass}-${case_name}-${mode}.stderr"
  local -a args=("$candidate" --sysroot "$root")
  [[ "$mode" == text ]] || args+=(--json)

  set +e
  (ulimit -c 0; LC_ALL=C TERM=dumb timeout 15s "${args[@]}") >"$stdout" 2>"$stderr"
  local rc=$?
  set -e

  printf 'pass=%s case=%s mode=%s rc=%d stdout_sha256=%s stderr_sha256=%s\n' \
    "$pass" "$case_name" "$mode" "$rc" \
    "$(sha256sum "$stdout" | cut -d' ' -f1)" \
    "$(sha256sum "$stderr" | cut -d' ' -f1)" >>"$outdir/results.txt"

  [[ $rc -eq 0 ]] || {
    echo "$case_name $mode pass $pass exited $rc" >&2
    cat "$stderr" >&2
    return 1
  }
  ! grep -Eqi 'double free|invalid pointer|aborted' "$stderr"
  if [[ "$mode" == json ]]; then
    python3 -m json.tool "$stdout" >/dev/null
  fi
}

: >"$outdir/results.txt"
{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "kernel=$(uname -srvmo)"
  echo "candidate=$candidate"
  echo "candidate_sha256=$(sha256sum "$candidate" | cut -d' ' -f1)"
  "$candidate" --version | head -1 | sed 's/^/candidate_version=/'
  echo "source_head=$(git rev-parse HEAD)"
  echo "path_blob=$(git hash-object lib/path.c)"
} >"$outdir/identity.txt"

for pass in 1 2; do
  run_case "$pass" valid text no
  run_case "$pass" valid json no
  run_case "$pass" malformed-online text yes
  run_case "$pass" malformed-online json yes
done

cat "$outdir/identity.txt"
cat "$outdir/results.txt"
