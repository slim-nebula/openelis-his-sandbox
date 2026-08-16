#!/usr/bin/env bash
# Waits for a command to succeed. Used instead of sleeps so startup ordering is
# based on readiness rather than guesswork.
#
#   wait-for.sh "<label>" "<command>" [timeout-seconds]
set -uo pipefail

label="$1"
command="$2"
timeout="${3:-120}"
elapsed=0

printf '    waiting for %s' "$label"
while (( elapsed < timeout )); do
    if eval "$command" >/dev/null 2>&1; then
        printf ' ready (%ss)\n' "$elapsed"
        exit 0
    fi
    printf '.'
    sleep 3
    elapsed=$(( elapsed + 3 ))
done

printf ' TIMED OUT after %ss\n' "$timeout" >&2
exit 1
