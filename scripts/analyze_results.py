import csv, os

ROOT = "/home/qiupf/experiments/voltronbench/benchmark/experiment-runs"
runs = sorted(os.listdir(ROOT))
print(f"{'run_id':<28} {'dur':<6} {'rows':<6} {'span_s':<10} {'fuzzer(s)':<22} {'subjects'}")
for r in runs:
    rdir = os.path.join(ROOT, r)
    if not os.path.isdir(rdir):
        continue
    params = os.path.join(rdir, "experiment_parameters.txt")
    if not os.path.exists(params):
        continue
    p = {}
    for line in open(params):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            p[k] = v
    csvs = []
    for d in os.listdir(rdir):
        if d.startswith("results-"):
            rc = os.path.join(rdir, d, "results.csv")
            if os.path.exists(rc):
                csvs.append(rc)
    if not csvs:
        continue
    rows = []
    for rc in csvs:
        try:
            rows.extend(list(csv.DictReader(open(rc))))
        except Exception as e:
            print(f"  error reading {rc}: {e}")
    if not rows:
        print(f"{r:<28} {p.get('duration_minutes','?'):<6} {'0':<6}")
        continue
    ts = sorted(set(int(x["time"]) for x in rows))
    span = ts[-1] - ts[0] if len(ts) > 1 else 0
    fuzzers = ",".join(sorted(set(x["fuzzer"] for x in rows)))
    subs = ",".join(sorted(set(x["subject"] for x in rows)))
    print(f"{r:<28} {p.get('duration_minutes','?'):<6} {len(rows):<6} {span:<10} {fuzzers:<22} {subs}")
