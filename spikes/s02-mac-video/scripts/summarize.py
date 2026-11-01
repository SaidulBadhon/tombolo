#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Spike S2: tabulate measure.sh / loopback.sh run directories (harness summary, Mac-side pipeline stats,
Mac and phone CPU / energy samples, conditions) as Markdown, plus a JSON digest.

usage: python3 -I scripts/summarize.py RUN_DIR... [--json OUT.json]
"""
import json
import os
import re
import statistics
import sys


def mean(xs):
    return statistics.fmean(xs) if xs else float("nan")


def mac_top(path):
    """Mean %CPU and POWER per command over `top -l` samples (the first sample has no delta and is skipped)."""
    if not os.path.exists(path):
        return {}
    blocks, cur = [], None
    for line in open(path, errors="replace"):
        if line.startswith("PID"):
            cur = []
            blocks.append(cur)
        elif cur is not None and re.match(r"^\s*\d+\s", line):
            parts = line.split()
            # PID COMMAND… %CPU POWER #TH — the command may contain spaces; take numbers from the right.
            try:
                th, power, cpu = parts[-1], float(parts[-2]), float(parts[-3])
                cmd = " ".join(parts[1:-3])
            except ValueError:
                continue
            cur.append((cmd, cpu, power))
    out = {}
    for b in blocks[1:]:
        for cmd, cpu, power in b:
            key = "WindowServer" if cmd.startswith("WindowServer") else "adb" if cmd.startswith("adb") else cmd
            out.setdefault(key, {"cpu": [], "power": []})
            out[key]["cpu"].append(cpu)
            out[key]["power"].append(power)
    return {k: {"cpu_mean": mean(v["cpu"]), "power_mean": mean(v["power"]), "n": len(v["cpu"])} for k, v in out.items()}


def phone_top(path):
    """Mean %CPU per process group over `top -b -d 1` iterations (first iteration skipped)."""
    if not os.path.exists(path):
        return {}
    groups = {"scrcpy-server": r"app_process", "encoder (media.hwcodec)": r"media\.hwcodec",
              "surfaceflinger": r"surfaceflinger", "chrome (all)": r"com\.android\.chrome"}
    iters, cur = [], None
    for line in open(path, errors="replace"):
        if re.match(r"^\s*PID\s", line):
            cur = {g: 0.0 for g in groups}
            iters.append(cur)
            continue
        if cur is None:
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        try:
            cpu = float(parts[2])
        except ValueError:
            continue
        name = " ".join(parts[4:])
        for g, rx in groups.items():
            if re.search(rx, name):
                cur[g] += cpu
    iters = iters[1:]
    return {g: {"cpu_mean": mean([i[g] for i in iters]), "n": len(iters)} for g in groups}


def phone_battery(path):
    if not os.path.exists(path):
        return {}
    cur, volt, temp = [], [], []
    for line in open(path):
        p = line.split()
        if len(p) == 4 and all(re.match(r"^-?\d+$", x) for x in p):
            cur.append(int(p[1]) / 1000.0)    # mA (sign convention is the driver's)
            volt.append(int(p[2]) / 1e6)
            temp.append(int(p[3]) / 10.0)
    if not cur:
        return {}
    return {"current_mA_mean": mean(cur), "voltage_V_mean": mean(volt),
            "power_W_mean": mean([c * v / 1000 for c, v in zip(cur, volt)]), "temp_C_first": temp[0], "temp_C_last": temp[-1], "n": len(cur)}


def conditions(path):
    d = {}
    if not os.path.exists(path):
        return d
    for line in open(path, errors="replace"):
        if ":" in line and not line.startswith("#"):
            k, v = line.split(":", 1)
            d.setdefault(k.strip(), v.strip())
    return d


def run(rd):
    name = os.path.basename(os.path.normpath(rd))
    r = {"run": name}
    try:
        s = json.load(open(os.path.join(rd, "summary.json")))
        k = s["kinds"][0]
        L = k["latencyMs"]
        r.update(frames=s["framesTotal"], decode_rate=s["decodeRate"], samples=k["samples"], kind=k["kind"],
                 p50=L["p50"], p50ci=L["p50CI"], p95=L["p95"], p95ci=L["p95CI"], p99=L["p99"], p99ci=L["p99CI"],
                 min=L["min"], max=L["max"], sd=L["sd"], sys_unc=k.get("systematicUncertaintyMs"),
                 capture_interval_ms=s.get("captureIntervalMedianMs"), source_interval_ms=k.get("sourceIntervalMedianMs"),
                 source_skipped=k.get("sourceFramesSkipped"), repeats=k.get("repeats"), negative=k.get("negativeSamples"))
    except (OSError, KeyError, IndexError, ValueError) as e:
        r["error"] = "no harness summary (%s)" % e.__class__.__name__
    try:
        m = json.load(open(os.path.join(rd, "mirror-stats.json")))
        st = m["stats"]
        num = lambda x: float(x) if not isinstance(x, str) else float("nan")
        r.update(presenter=m["presenter"], video=m.get("video"), fps=st["receivedFps"], mbps=st["megabitsPerSecond"],
                 recv_decoded_p50=num(st["receiveToDecodedMs"]["p50"]), recv_decoded_p95=num(st["receiveToDecodedMs"]["p95"]),
                 recv_presented_p50=num(st["receiveToPresentedMs"]["p50"]), recv_presented_p95=num(st["receiveToPresentedMs"]["p95"]),
                 superseded=st["superseded"], decoded=st["decoded"], decode_errors=st["decodeErrors"],
                 jitter_p95=num(st["arrivalJitterMs"]["p95"]), mirror_cpu_cores=st["processCPUCores"],
                 server_args=m.get("serverArguments"))
    except (OSError, KeyError, ValueError):
        pass
    r["mac_top"] = mac_top(os.path.join(rd, "mac-top.txt"))
    r["phone_top"] = phone_top(os.path.join(rd, "phone-top.txt"))
    r["phone_battery"] = phone_battery(os.path.join(rd, "phone-battery.csv"))
    c = conditions(os.path.join(rd, "conditions-before.txt"))
    ca = conditions(os.path.join(rd, "conditions-after.txt"))
    r["conditions"] = {"loadavg": c.get("mac_loadavg"), "battery_level": c.get("phone_battery_level"),
                       "battery_status": c.get("phone_battery_status"), "battery_temp": c.get("phone_battery_temperature"),
                       "battery_level_after": ca.get("phone_battery_level"), "battery_temp_after": ca.get("phone_battery_temperature"),
                       "ac": c.get("phone_battery_AC powered"), "display": c.get("phone_display"),
                       "mac_therm": c.get("mac_therm")}
    return r


def fmt(x, nd=2):
    return "–" if x is None or (isinstance(x, float) and x != x) else ("%.*f" % (nd, x))


def main():
    args = sys.argv[1:]
    out_json = None
    if "--json" in args:
        i = args.index("--json")
        out_json = args[i + 1]
        del args[i:i + 2]
    runs = [run(a) for a in args]
    print("| Run | Presenter | n | decoded | p50 [95 % CI] | p95 [CI] | p99 | min–max | ± sys | recv→decoded p50/p95 | recv→presented p50/p95 | fps | Mb/s |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in runs:
        if "p50" not in r:
            print("| %s | %s | %s |" % (r["run"], r.get("presenter", "?"), r.get("error")))
            continue
        print("| %s | %s | %d | %.1f %% | %s [%s, %s] | %s [%s, %s] | %s | %s–%s | %s | %s / %s | %s / %s | %s | %s |" % (
            r["run"], r.get("presenter", "?"), r["samples"], 100 * r["decode_rate"],
            fmt(r["p50"]), fmt(r["p50ci"][0]), fmt(r["p50ci"][1]), fmt(r["p95"]), fmt(r["p95ci"][0]), fmt(r["p95ci"][1]),
            fmt(r["p99"]), fmt(r["min"], 1), fmt(r["max"], 1), fmt(r["sys_unc"]),
            fmt(r.get("recv_decoded_p50")), fmt(r.get("recv_decoded_p95")), fmt(r.get("recv_presented_p50")), fmt(r.get("recv_presented_p95")),
            fmt(r.get("fps"), 1), fmt(r.get("mbps"))))
    print()
    print("| Run | Mac: mirror %CPU / energy impact | adb server %CPU / EI | WindowServer %CPU / EI | other | phone: scrcpy-server / encoder HAL / SurfaceFlinger / Chrome %CPU | battery net W | load avg | phone battery |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in runs:
        mt, pt, pb, c = r["mac_top"], r["phone_top"], r["phone_battery"], r["conditions"]
        mirror = next((v for k, v in mt.items() if k.startswith("s02-mirror")), None)
        other = "; ".join("%s %s / %s" % (k, fmt(v["cpu_mean"], 1), fmt(v["power_mean"], 1)) for k, v in mt.items()
                          if not k.startswith(("s02-mirror", "adb", "WindowServer")))
        g = lambda d, k: fmt(d.get(k, {}).get("cpu_mean"), 1) if d else "–"
        print("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["run"], ("%s / %s" % (fmt(mirror["cpu_mean"], 1), fmt(mirror["power_mean"], 1))) if mirror else "–",
            ("%s / %s" % (fmt(mt["adb"]["cpu_mean"], 1), fmt(mt["adb"]["power_mean"], 1))) if "adb" in mt else "–",
            ("%s / %s" % (fmt(mt["WindowServer"]["cpu_mean"], 1), fmt(mt["WindowServer"]["power_mean"], 1))) if "WindowServer" in mt else "–",
            other or "–",
            " / ".join(g(pt, k) for k in ("scrcpy-server", "encoder (media.hwcodec)", "surfaceflinger", "chrome (all)")) if pt else "–",
            fmt(pb.get("power_W_mean")) if pb else "–", (c.get("loadavg") or "–"),
            ("%s %% %s, %s→%s (tenths °C)" % (c.get("battery_level"), "charging" if c.get("battery_status") == "2" else "status " + str(c.get("battery_status")),
                                             c.get("battery_temp"), c.get("battery_temp_after"))) if c.get("battery_level") else "–"))
    if out_json:
        with open(out_json, "w") as f:
            json.dump(runs, f, indent=1, default=str)


if __name__ == "__main__":
    main()
