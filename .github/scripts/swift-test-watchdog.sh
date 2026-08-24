#!/usr/bin/env bash
#
# Run `swift test` with a stall watchdog.
#
# The suite intermittently hangs: the test binary stays alive producing no
# output at all, and the job sits until `timeout-minutes` kills it without a
# stack trace, leaving nothing to debug. Typical healthy runtimes are ~50s
# (debug) and ~1m45s (release), so a stall is unambiguous well before then.
#
# If no result appears within TEST_STALL_TIMEOUT seconds this samples every
# surviving test process, prints the backtraces, and kills the run so the job
# fails fast with something actionable instead of timing out silently.
#
# Usage: swift-test-watchdog.sh <debug|release>

set -uo pipefail

configuration="${1:-debug}"
timeout="${TEST_STALL_TIMEOUT:-420}"

# Validate up front, then launch with hardcoded arguments per mode so nothing
# from the caller reaches the command line. Each branch backgrounds the swift
# process directly -- backgrounding a `case` block instead would make $! a
# wrapper subshell, so the sample would show bash and the kill would leave the
# real test process orphaned.
case "$configuration" in
    debug | release) ;;
    *)
        echo "usage: $(basename "$0") <debug|release>" >&2
        exit 2
        ;;
esac

if [ "$configuration" = "release" ]; then
    swift test --configuration release &
else
    swift test &
fi
test_pid=$!

(
    sleep "$timeout"
    kill -0 "$test_pid" 2>/dev/null || exit 0

    echo "::error::swift test ($configuration) produced no result within ${timeout}s - capturing stack traces"
    echo "::group::Stalled test processes"
    ps -Ao pid,ppid,stat,etime,comm | grep -iE "xctest|swift-test" | grep -v grep

    # Match `xctest` by exact process name: the test bundle is loaded by the
    # xctest host rather than exec'd, and matching on the full command line
    # also catches compiler processes that merely mention the bundle path.
    # The swift-test driver is sampled too, in case the stall is upstream of
    # the test host ever launching.
    for pid in $(pgrep -x xctest 2>/dev/null) "$test_pid"; do
        echo "--- sample $pid ---"
        sample "$pid" 3 -mayDie 2>&1 | head -150
    done
    echo "::endgroup::"

    pkill -9 -x xctest 2>/dev/null
    kill -9 "$test_pid" 2>/dev/null
) &
watchdog_pid=$!

# Preserve the real exit status so genuine test failures still fail the job.
wait "$test_pid"
status=$?

kill "$watchdog_pid" 2>/dev/null
wait "$watchdog_pid" 2>/dev/null

exit "$status"
