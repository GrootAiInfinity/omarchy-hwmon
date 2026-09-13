#!/bin/bash
# The grid folds threads into cores in QML, which is the one piece of real logic
# on that side. The binding is lifted out of hwmon.qml verbatim and run against
# synthetic machines, so this checks the shipped expression rather than a copy.
set -u
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null 2>&1 || { echo "== cpu grid: skipped (no node)"; exit 0; }
echo "== cpu grid"
QML=$(dirname "$0")/../hwmon.qml
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 - "$QML" "$TMP/cells.js" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
start = src.index('readonly property var cpuCells: {')
body = src[src.index('{', start):]
depth = 0
for i, ch in enumerate(body):
    if ch == '{': depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            body = body[:i + 1]; break
open(sys.argv[2], 'w').write(
    "function cpuCells(root) " + body + "\nmodule.exports = cpuCells;\n")
PY

cat > "$TMP/run.cjs" <<'JS'
const cpuCells = require(process.argv[2]);
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const cases = [];

// 16 threads on 8 SMT cores: pairs average into one block each.
const smt = { stats: { cpu_cores: [0,100, 50,50, 10,30, 0,0, 100,100, 25,75, 1,3, 99,1],
                       cpu_core_of: [0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7] }, cpuView: "cores" };
const cores = cpuCells(smt);
cases.push(["8 cores from 16 threads", cores.length, 8]);
cases.push(["labelled 0..7", cores.map(c => c.label).join(","), "0,1,2,3,4,5,6,7"]);
cases.push(["each is the average of its pair", cores.map(c => c.pct).join(","), "50,50,20,0,100,50,2,50"]);

// Same machine, thread view: every thread kept, in order.
const threads = cpuCells(Object.assign({}, smt, { cpuView: "threads" }));
cases.push(["16 threads in thread view", threads.length, 16]);
cases.push(["labelled 0..15", threads.map(t => t.label).join(","), [...Array(16).keys()].join(",")]);
cases.push(["values untouched", threads.map(t => t.pct).join(","), smt.stats.cpu_cores.join(",")]);

// No SMT: one thread per core, so both views agree.
const flat = { stats: { cpu_cores: [10,20,30,40], cpu_core_of: [0,1,2,3] }, cpuView: "cores" };
cases.push(["no-SMT machine is unchanged", cpuCells(flat).map(c => c.pct).join(","), "10,20,30,40"]);

// No topology at all (some VMs, some ARM): fall back to threads.
const bare = { stats: { cpu_cores: [5,15,25] }, cpuView: "cores" };
cases.push(["falls back to threads without a map", cpuCells(bare).length, 3]);
const short = { stats: { cpu_cores: [5,15,25], cpu_core_of: [0,0] }, cpuView: "cores" };
cases.push(["and when the map does not line up", cpuCells(short).length, 3]);

// Nothing sampled yet.
cases.push(["empty before the first sample", cpuCells({ stats: {}, cpuView: "cores" }).length, 0]);

// Cores numbered out of order still come back sorted and renumbered by key.
const odd = { stats: { cpu_cores: [1,2,3,4], cpu_core_of: [3,1,3,1] }, cpuView: "cores" };
cases.push(["sorted by core number", cpuCells(odd).map(c => c.label).join(","), "1,3"]);

let bad = 0;
for (const [name, got, want] of cases) {
  if (eq(got, want)) console.log("  ok   " + name);
  else { console.log(`  FAIL ${name}: got [${got}] want [${want}]`); bad++; }
}
process.exit(bad ? 1 : 0);
JS
node "$TMP/run.cjs" "$TMP/cells.js"; rc=$?
[ $rc = 0 ] && PASS=11 || FAIL=1
summary
