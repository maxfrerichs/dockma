# Reads `docker build --progress=plain` output on stdin and prints each step's
# time, or CACHED, with the number of base-image layers BuildKit extracted.
# Extraction on a FROM whose image `docker pull` already unpacked means
# BuildKit didn't reuse the pulled snapshots. Used by bench.sh.
import re
import sys

names, results, extracted = {}, {}, {}
for line in sys.stdin:
    if m := re.match(r"#(\d+) ERROR", line):
        sys.exit("build failed: " + line.strip())
    if not (m := re.match(r"#(\d+) (.*)", line)):
        continue
    step, rest = m.groups()
    if step not in names and not re.match(r"[\d.]+ ", rest):
        names[step] = rest.strip()[:60]
    if m := re.match(r"DONE ([\d.]+)s", rest):
        results[step] = f"{float(m.group(1)):6.1f} s"
    elif rest.startswith("CACHED"):
        results[step] = "CACHED"
    elif re.match(r"extracting sha256:\S+ [\d.]+s done", rest):
        extracted[step] = extracted.get(step, 0) + 1

for step, result in results.items():
    layers = f"  ({extracted[step]} layers extracted)" if step in extracted else ""
    print(f"  {names.get(step, '?'):<60} {result:>8}{layers}")
