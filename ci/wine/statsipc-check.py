# statsipc-check.py <file> <lines> <tabs> <build>: the /stats output is <lines> JSON lines, seq
# consecutive, one pid, the build, a window whose tab count is <tabs>, a real grid.
import json, sys
path, want, tabs, build = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
def fail(m): print("FAIL", m); sys.exit(1)
if len(rows) != want: fail(f"{len(rows)} lines, want {want}")
seqs = [r["seq"] for r in rows]
if any(b != a + 1 for a, b in zip(seqs, seqs[1:])): fail(f"seq not consecutive: {seqs}")
if len({r["pid"] for r in rows}) != 1: fail("several pids")
if rows[-1]["build"] != build: fail(f"build {rows[-1]['build']}, want {build}")
w = rows[-1]["windows"]
if len(w) != 1 or len(w[0]["tabs"]) != tabs: fail(f"windows/tabs: {[len(x['tabs']) for x in w]}, want 1 window of {tabs}")
t = [x for x in w[0]["tabs"] if x["selected"]][0]
if t["grid"][0] < 10 or t["grid"][1] < 5: fail(f"grid {t['grid']}")
print(f"ok   {want} lines, seq {seqs[0]}..{seqs[-1]}, pid {rows[0]['pid']}, {tabs} tab(s), grid {t['grid']}, fps {t['fps']}, period {rows[-1]['period_ms']} ms, cpu {rows[-1]['cpu_pct']}%")
