#!/bin/sh
set -eu
probe_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
probe_stage=$(mktemp -d "${TMPDIR:-/tmp}/chickinfry-swift-s1-smoke-XXXXXX")
trap 'rm -rf "$probe_stage"' EXIT HUP INT TERM
df -k /System/Volumes/Data
probe_free=$(df -k /System/Volumes/Data | awk 'END {print $4}')
test "$probe_free" -ge 3145728
swift build --package-path "$probe_root" --swift-sdk swift-6.4.1-RELEASE_wasm --scratch-path "$probe_stage/build" -c release --product ServerProbe \
  -Xswiftc -warnings-as-errors -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor \
  -Xlinker --export=probe_boot -Xlinker --export=probe_handle -Xlinker --export=chik_run_job \
  -Xlinker --export=chik_allocate -Xlinker --export=chik_deallocate -Xlinker --export=_initialize -Xlinker --export-memory
probe_bin=$(swift build --package-path "$probe_root" --swift-sdk swift-6.4.1-RELEASE_wasm --scratch-path "$probe_stage/build" -c release --show-bin-path)
probe_module="$probe_bin/ServerProbe.wasm"
test -f "$probe_module"
node "$probe_root/run.mjs" "$probe_module"
