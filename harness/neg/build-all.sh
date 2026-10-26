#!/bin/bash
# Builds the production child, the reason-file test child and every test-build
# variant (45 besides these two before the R7-T3 builds, 63 since them,
# 2026-10-22; 68 with the T2C builds, 70 with the dense-KV builds, 71 with
# the chunked-KV notes build and 73 with the S1 builds, 2026-10-23)
# the negative suite needs, then the launcher and the test spawner.
# Usage: neg/build-all.sh   (prints one line per build; exit 1 on any failure)
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun -sdk macosx metal --version >/dev/null 2>&1   # mounts the Metal toolchain
R='-DSEALED_TEST_REASON_FILE=\"/tmp/sealed-reason.log\"'
# S-1 builds use their own reason file: their driver can then run beside a
# suite run without either one truncating the other's record.
R1='-DSEALED_TEST_REASON_FILE=\"/tmp/sealed-reason-s1.log\"'
# Read-sweep locations for the TEE probe builds (this user, this Mac).
UTMP=$(getconf DARWIN_USER_TEMP_DIR); UTMP=${UTMP%/}
SW="-DSEALED_TEST_SWEEP_HOME='\"$HOME\"' -DSEALED_TEST_SWEEP_UTMP='\"$UTMP\"' -DSEALED_TEST_SWEEP_PKG='\"$PWD/pkg/qwen38-27b\"'"
# S3 (2026-10-21): a hard link of target/head.bin outside the package (the
# Hugging Face blob the package links to), for the descriptor case.
BLOB=$(find ~/.cache/huggingface/hub/models--audreyt--Qwen3.8-27B-Splash-abliterated/blobs -inum "$(stat -f %i pkg/qwen38-27b/target/head.bin)" 2>/dev/null | head -1)
[ -n "$BLOB" ] || { echo "FAILED: no hard link of target/head.bin outside the package"; exit 1; }
KF() { echo "-DSEALED_TEST_KEEP_FD_PATH='\"$1\"'"; }
# name|defines (the reason file is added to every test build)
VARIANTS=(
  "build|-DSPLASH_SEALED"
  "build-reason|-DSPLASH_SEALED $R"
  "build-t1|-DSPLASH_SEALED $R -DSEALED_TEST_REOPEN_AFTER_LATCH"
  "build-t2|-DSPLASH_SEALED $R -DSEALED_TEST_PLANT_MAPPING"
  "build-t3|-DSPLASH_SEALED $R -DSEALED_TEST_REREAD"
  "build-pl-caches|-DSPLASH_SEALED $R -DSEALED_TEST_PLANT_MAPPING -DSEALED_TEST_PLANT_PATH='\"/System/Library/Caches/com.apple.IntlDataCache.le\"'"
  "build-pl-snmp|-DSPLASH_SEALED $R -DSEALED_TEST_PLANT_MAPPING -DSEALED_TEST_PLANT_PATH='\"/usr/share/snmp/SensorDat.xml\"'"
  "build-pl-coretypes|-DSPLASH_SEALED $R -DSEALED_TEST_PLANT_MAPPING -DSEALED_TEST_PLANT_PATH='\"/System/Library/CoreServices/CoreTypes.bundle/Contents/Library/CoreTypes-0031.bundle/Contents/Info.plist\"'"
  "build-m-ALLOW_WRITE|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_ALLOW_WRITE"
  "build-m-ALLOW_NET|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_ALLOW_NET"
  "build-m-ALLOW_LOOKUP|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_ALLOW_LOOKUP"
  "build-nosb|-DSPLASH_SEALED $R -DSEALED_TEST_NO_SANDBOX"
  "build-early|-DSPLASH_SEALED $R -DSEALED_TEST_REPORT_EARLY"
  "build-skipsb|-DSPLASH_SEALED $R -DSEALED_TEST_SKIP_SB_REPORT"
  "build-cap|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_CAP=4096"
  "build-tee|-DSPLASH_SEALED $R -DSEALED_TEST_TEE_PROBES -DSEALED_TEST_TAG='\"sandboxed\"' $SW"
  "build-tee-nosb|-DSPLASH_SEALED $R -DSEALED_TEST_TEE_PROBES -DSEALED_TEST_NO_SANDBOX -DSEALED_TEST_TAG='\"control\"' $SW"
  "build-tee-ext|-DSPLASH_SEALED $R -DSEALED_TEST_TEE_PROBES -DSEALED_TEST_PROFILE_ALLOW_EXTENSION -DSEALED_TEST_TAG='\"extctl\"' $SW"
  "build-nocomp|-DSPLASH_SEALED $R -DSEALED_TEST_NO_COMPILER_LOOKUP"
  "build-crash|-DSPLASH_SEALED $R -DSEALED_TEST_CRASH_CANARY"
  "build-crash-nor1|-DSPLASH_SEALED $R -DSEALED_TEST_CRASH_CANARY -DSEALED_TEST_NO_R1"
  "build-s3-rwalias|-DSPLASH_SEALED $R -DSEALED_TEST_RW_ALIAS"
  "build-s3-rwalias-drop|-DSPLASH_SEALED $R -DSEALED_TEST_RW_ALIAS -DSEALED_TEST_RW_ALIAS_DROP"
  "build-s3-share|-DSPLASH_SEALED $R -DSEALED_TEST_SHARE_ENTRY"
  "build-s3-share-ctl|-DSPLASH_SEALED $R -DSEALED_TEST_SHARE_ENTRY_CTL"
  "build-s3-fd-blob|-DSPLASH_SEALED $R $(KF "$BLOB")"
  "build-s3-fd-root|-DSPLASH_SEALED $R $(KF "$PWD/pkg/qwen38-27b/target")"
  "build-s3-fd-under|-DSPLASH_SEALED $R $(KF "$PWD/pkg/qwen38-27b/tokenizer/vocab.json")"
  "build-s3-fd-hosts|-DSPLASH_SEALED $R $(KF /private/etc/hosts)"
  "build-s3-fd-sys|-DSPLASH_SEALED $R $(KF /System/Library/CoreServices/SystemVersion.plist)"
  "build-s3-bypass|-DSPLASH_SEALED $R -DSEALED_TEST_BYPASS_OPEN"
  "build-s3-bypass-close|-DSPLASH_SEALED $R -DSEALED_TEST_BYPASS_OPEN -DSEALED_TEST_BYPASS_CLOSE"
  # S3 mutation builds (2026-10-22): one S3 check compiled out each. The plain
  # mutants have no planted hazard; the others add the hazard hook of one S3
  # case, so that case must load on its mutant.
  "build-noshar|-DSPLASH_SEALED $R -DSEALED_TEST_NO_SHAREMODE"
  "build-nofd|-DSPLASH_SEALED $R -DSEALED_TEST_NO_FDCHECK"
  "build-noopen|-DSPLASH_SEALED $R -DSEALED_TEST_NO_OPENLOG"
  "build-noshar-rwalias|-DSPLASH_SEALED $R -DSEALED_TEST_NO_SHAREMODE -DSEALED_TEST_RW_ALIAS"
  "build-noshar-share|-DSPLASH_SEALED $R -DSEALED_TEST_NO_SHAREMODE -DSEALED_TEST_SHARE_ENTRY"
  "build-nofd-blob|-DSPLASH_SEALED $R -DSEALED_TEST_NO_FDCHECK $(KF "$BLOB")"
  "build-nofd-root|-DSPLASH_SEALED $R -DSEALED_TEST_NO_FDCHECK $(KF "$PWD/pkg/qwen38-27b/target")"
  "build-nofd-under|-DSPLASH_SEALED $R -DSEALED_TEST_NO_FDCHECK $(KF "$PWD/pkg/qwen38-27b/tokenizer/vocab.json")"
  "build-nofd-hosts|-DSPLASH_SEALED $R -DSEALED_TEST_NO_FDCHECK $(KF /private/etc/hosts)"
  "build-nofd-bypass|-DSPLASH_SEALED $R -DSEALED_TEST_NO_FDCHECK -DSEALED_TEST_BYPASS_OPEN"
  # T2 (2026-10-22): global and non-global IOSurface with a canary, after the
  # "sandboxed" report and after the load; the control has no sandbox.
  "build-t2-publish|-DSPLASH_SEALED $R -DSEALED_TEST_IOSURFACE_PUBLISH"
  "build-t2-publish-nosb|-DSPLASH_SEALED $R -DSEALED_TEST_IOSURFACE_PUBLISH -DSEALED_TEST_NO_SANDBOX"
  # T2 follow-up (2026-10-22): profile variants for the IOSurfaceRootUserClient
  # method filter. Two carry the T2F probe; the chat build has no probe, so the
  # load timing matches a normal chat request.
  "build-t2f-filter|-DSPLASH_SEALED $R -DSEALED_TEST_T2F_PROBE -DSEALED_TEST_PROFILE_IOSURFACE_FILTER"
  "build-t2f-noiosurface|-DSPLASH_SEALED $R -DSEALED_TEST_T2F_PROBE -DSEALED_TEST_PROFILE_NO_IOSURFACE"
  "build-t2f-noiosurface-chat|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_NO_IOSURFACE"
  # R7-T3 (2026-10-22): read-back of the start state after the load, around
  # each request and in a 1 ms busy-poll thread; seeded controls (after the
  # load, and during or after the first request); the static-initializer
  # control; the interposer arm; the crash arm after the load and after the
  # first request. See review/R7T3-2026-10-22.md.
  "build-r7|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK $SW"
  "build-r7-static|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_STATIC_INIT $SW"
  "build-r7-seed-signal|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=1 $SW"
  "build-r7-seed-taskport|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=2 $SW"
  "build-r7-seed-threadport|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=3 $SW"
  "build-r7-seed-ext|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=4 -DSEALED_TEST_PROFILE_ALLOW_EXTENSION $SW"
  "build-r7-seed-setid|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=5 $SW"
  "build-r7-rseed-signal|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=1 -DSEALED_TEST_R7_SEED_AT_REQUEST $SW"
  "build-r7-rseed-taskport|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=2 -DSEALED_TEST_R7_SEED_AT_REQUEST $SW"
  "build-r7-rseed-threadport|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=3 -DSEALED_TEST_R7_SEED_AT_REQUEST $SW"
  "build-r7-rseed-ext|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=4 -DSEALED_TEST_R7_SEED_AT_REQUEST -DSEALED_TEST_PROFILE_ALLOW_EXTENSION $SW"
  "build-r7-rseed-setid|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_SEED=5 -DSEALED_TEST_R7_SEED_AT_REQUEST $SW"
  "build-r7-noshar|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_NO_SHAREMODE $SW"
  "build-r7-interpose|-DSPLASH_SEALED $R -DSEALED_TEST_R7_READBACK -DSEALED_TEST_R7_INTERPOSE $SW -Wno-unused-command-line-argument -L$PWD/neg/R7 -lr7interpose"
  "build-r7-crash-postload|-DSPLASH_SEALED $R -DSEALED_TEST_CRASH_CANARY -DSEALED_TEST_CRASH_PHASE='\"postload\"'"
  "build-r7-crash-postload-nor1|-DSPLASH_SEALED $R -DSEALED_TEST_CRASH_CANARY -DSEALED_TEST_CRASH_PHASE='\"postload\"' -DSEALED_TEST_NO_R1"
  "build-r7-crash-request|-DSPLASH_SEALED $R -DSEALED_TEST_CRASH_CANARY -DSEALED_TEST_CRASH_PHASE='\"after-request\"'"
  "build-r7-crash-request-nor1|-DSPLASH_SEALED $R -DSEALED_TEST_CRASH_CANARY -DSEALED_TEST_CRASH_PHASE='\"after-request\"' -DSEALED_TEST_NO_R1"
  # T2 client-need check (2026-10-23, review/T2-CLIENT-NEED-2026-10-23.md):
  # Metal without IOSurfaceRootUserClient under the class deny. v1 legacy
  # queue and MTLEvent, v2 no placement-sparse probe, v2b dense KV (no MTL4
  # queue, no shared event), its production-profile control, and v2b with
  # the T2F surface probe for the outside reader.
  "build-t2c-v1-legacy|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_NO_IOSURFACE -DSEALED_TEST_METAL_LEGACY_SYNC"
  "build-t2c-v2-noprobe|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_NO_IOSURFACE -DSEALED_TEST_NO_SPARSE_PROBE"
  "build-t2c-v2b-dense|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_NO_IOSURFACE -DSEALED_TEST_DENSE_KV"
  "build-t2c-v2b-dense-allow|-DSPLASH_SEALED $R -DSEALED_TEST_DENSE_KV"
  "build-t2c-v2b-dense-t2f|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_NO_IOSURFACE -DSEALED_TEST_DENSE_KV -DSEALED_TEST_T2F_PROBE"
  # Dense KV in production (2026-10-23, review/DENSE-KV-2026-10-23.md): every
  # sealed build now has dense KV and no IOSurfaceRootUserClient rule, so
  # SEALED_TEST_DENSE_KV and SEALED_TEST_PROFILE_NO_IOSURFACE above only add
  # the t2c notes, and v2b-dense-allow has the class deny too. The mutant
  # restores the old class rule (the self-test arm iosurface-open must
  # refuse it); the T2F probe build is the production profile and backend.
  "build-m-ALLOW_IOSURFACE|-DSPLASH_SEALED $R -DSEALED_TEST_PROFILE_ALLOW_IOSURFACE"
  "build-dkv-t2f|-DSPLASH_SEALED $R -DSEALED_TEST_T2F_PROBE"
  # Chunked KV (2026-10-23, review/CHUNKED-KV-2026-10-23.md): the production
  # backend with chunk allocate and release timings in the reason file.
  "build-ckv-notes|-DSPLASH_SEALED $R -DSEALED_TEST_CKV_NOTES"
  # S-1 (2026-10-23, review/S1-IOGPU-2026-10-23.md): can code in the child
  # share memory with another process through the GPU client the profile
  # allows? Shared texture and shared event, handles archived to the reason
  # file, held for an outside reader; the control has no sandbox.
  "build-s1-share|-DSPLASH_SEALED $R1 -DSEALED_TEST_S1_SHARE"
  "build-s1-share-nosb|-DSPLASH_SEALED $R1 -DSEALED_TEST_S1_SHARE -DSEALED_TEST_NO_SANDBOX"
)
mkdir -p logs/build
fail=0
# --check: build nothing; recompute each variant's build ID from the current
# source and its own flags, and compare it with its stamp and its binary
# (audit R3-G1). Prints one line per variant; exit 1 on any mismatch.
if [ "${1:-}" = "--check" ]; then
  bad=0
  for v in "${VARIANTS[@]}"; do
    name=${v%%|*}; defs=${v#*|}
    if out=$(cd splash && make -s check-build-identity BUILD=$name SEALED_DEFS="$defs" 2>&1); then
      echo "current $name $(echo "$out" | sed -n 's/.*"build_id": "\([^"]*\)".*/\1/p')"
    else
      echo "STALE $name: $(echo "$out" | tail -1)"; bad=1
    fi
  done
  exit $bad
fi
. tools/suite-lock.sh && suite_lock neg/build-all.sh
build_one() {
  local name=${1%%|*} defs=${1#*|}
  [ -d splash/$name ] || cp -Rp splash/build-reason splash/$name
  if (cd splash && BENCH_OK=1 nice -n 10 make -j3 BUILD=$name SEALED_DEFS="$defs" > ../logs/build/$name.log 2>&1); then
    echo "built $name"
  else
    echo "FAILED $name (logs/build/$name.log)"; return 1
  fi
}
# R7-T3 interposer library: build-r7-interpose links it (SEALED_DEFS above).
if clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations -Isplash/runtime -dynamiclib \
     -install_name @executable_path/libr7interpose.dylib -o neg/R7/libr7interpose.dylib neg/R7/r7interpose.c &&
   codesign -f -s - neg/R7/libr7interpose.dylib 2>/dev/null; then echo "built libr7interpose"; else echo "FAILED libr7interpose"; exit 1; fi
# build-reason first: the other test folders start as copies of it.
build_one "${VARIANTS[1]}" || exit 1
pids=()
for v in "${VARIANTS[@]}"; do
  case ${v%%|*} in build-reason) continue ;; esac
  build_one "$v" & pids+=($!)
  while [ "$(jobs -rp | wc -l)" -ge 4 ]; do sleep 1; done
done
for p in "${pids[@]}"; do wait $p || fail=1; done
# The launcher compiles the spawn module and the R1 guard from the engine's
# own sources, so the test launcher runs the engine's code (audit R4-H2).
# The guard copy in splash/ is byte-identical; accept.sh checks that.
S=$HOME/projects/morpheus-pnode/sealed-engine-v2/Sources/SealedSpawnC
G=$S/sealed_guard.c
if clang -std=c17 -O2 -Wall -Wextra -Werror -I $S/include launcher/sealed-launch.c $S/sealed_spawn.c $G -o launcher/sealed-launch &&
   codesign -f -s - --options runtime launcher/sealed-launch 2>/dev/null; then echo "built launcher"; else echo "FAILED launcher"; fail=1; fi
# R7-T3: a launcher copy whose pinned status word is the one measured for a
# child signed with disable-library-validation (0x22011301: CS_FORCED_LV off),
# for the interposer build only. The production launcher is unchanged.
# The spawn module's required flags drop CS_FORCED_LV the same way, in a
# copy of its header under neg/R7/include.
sed 's/0x22011311u/0x22011301u/g' launcher/sealed-launch.c > neg/R7/sealed-launch-dlv.c
mkdir -p neg/R7/include
sed 's/ | SEALED_CS_ENFORCEMENT | SEALED_CS_FORCED_LV)/ | SEALED_CS_ENFORCEMENT)/' $S/include/sealed_spawn.h > neg/R7/include/sealed_spawn.h
if grep -q 0x22011301u neg/R7/sealed-launch-dlv.c && ! grep -q 'SEALED_CS_ENFORCEMENT | SEALED_CS_FORCED_LV)' neg/R7/include/sealed_spawn.h &&
   clang -std=c17 -O2 -Wall -Wextra -Werror -I neg/R7/include -I $S/include neg/R7/sealed-launch-dlv.c $S/sealed_spawn.c $G -o neg/R7/sealed-launch-dlv &&
   codesign -f -s - --options runtime neg/R7/sealed-launch-dlv 2>/dev/null; then echo "built sealed-launch-dlv"; else echo "FAILED sealed-launch-dlv"; fail=1; fi
if clang -O2 -Wno-incompatible-pointer-types-discards-qualifiers -o neg/B/r2neg neg/B/r2neg.c; then echo "built r2neg"; else echo "FAILED r2neg"; fail=1; fi
if clang -O2 -fobjc-arc -framework Foundation -framework IOSurface -o neg/T2/t2-reader neg/T2/t2-reader.m; then echo "built t2-reader"; else echo "FAILED t2-reader"; fail=1; fi
# T2 client-need check (2026-10-23): the Metal screen probe and its IOServiceOpen tracer.
if clang++ -std=c++20 -O1 -fobjc-arc -framework Foundation -framework Metal -o neg/T2C/client-probe neg/T2C/client-probe.mm &&
   codesign -f -s - neg/T2C/client-probe 2>/dev/null &&
   clang -dynamiclib -O1 -framework IOKit -o neg/T2C/open-trace.dylib neg/T2C/open-trace.c; then echo "built t2c probe"; else echo "FAILED t2c probe"; fail=1; fi
# S-1 (2026-10-23): the outside reader for the shared-texture and shared-event
# builds. It runs as the same user, not sandboxed.
if clang++ -std=c++20 -O2 -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Metal \
     -framework IOSurface -framework IOKit -o neg/S1/s1-reader neg/S1/s1-reader.mm; then echo "built s1-reader"; else echo "FAILED s1-reader"; fail=1; fi
exit $fail
