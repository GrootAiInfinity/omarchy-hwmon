#!/bin/bash
# Every check in this directory. Run it from anywhere:
#
#   tests/run-tests.sh
#
# test-widget.sh needs Quickshell and skips itself without one, so this is
# runnable on a machine that has no desktop.
set -u
cd "$(dirname "$0")"
failed=0
for check in test-repo.sh test-backend.sh test-reaper.sh test-widget.sh; do
  ./"$check" || failed=$((failed + 1))
  echo
done
if [ "$failed" = 0 ]; then echo "all checks passed"; else echo "$failed check file(s) failed"; fi
exit $([ "$failed" = 0 ] && echo 0 || echo 1)
