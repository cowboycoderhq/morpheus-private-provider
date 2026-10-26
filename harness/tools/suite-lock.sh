#!/bin/bash
# One shared lock for every suite that uses the sealed kit's shared state
# (/tmp/sealed-reason.log, neg/run, the :8199 and :29452 ports, the engine).
# Source this file, then call `suite_lock <name>`. The lock is a folder, so
# taking it is atomic. A run started by a holder (SEALED_SUITE_LOCK_HELD=1 in
# its environment) runs inside that holder's lock. A stale lock (its pid is
# gone) is removed. The watcher in accept.sh samples every 3 s and can miss a
# short process; this lock covers the suites that use it, not other programs
# (audit R4-4-04).
SUITE_LOCK=/tmp/sealed-suite.lock
suite_lock() {
  [ "${SEALED_SUITE_LOCK_HELD:-}" = 1 ] && return 0
  local who
  if ! mkdir "$SUITE_LOCK" 2>/dev/null; then
    who=$(cat "$SUITE_LOCK/pid" 2>/dev/null)
    if [ -n "$who" ] && ! kill -0 "$who" 2>/dev/null; then
      rm -rf "$SUITE_LOCK"; mkdir "$SUITE_LOCK" 2>/dev/null || { echo "suite lock $SUITE_LOCK: taken by another run" >&2; exit 75; }
    else
      echo "suite lock $SUITE_LOCK is held by pid ${who:-?} ($(cat "$SUITE_LOCK/name" 2>/dev/null)); stop" >&2; exit 75
    fi
  fi
  echo $$ > "$SUITE_LOCK/pid"; echo "$1" > "$SUITE_LOCK/name"
  export SEALED_SUITE_LOCK_HELD=1
  trap 'rm -rf "$SUITE_LOCK"' EXIT
}
