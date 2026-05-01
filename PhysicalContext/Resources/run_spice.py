#!/usr/bin/env python3
"""
run_spice.py — Physical Context simulation bridge v3
Accepts both .asc (LTSpice schematic) and .net (SPICE netlist from kicad-cli).
Does NOT require Altium Designer.

Supported input formats:
  .asc   — LTSpice schematic (AscEditor parses, creates netlist, runs)
  .net   — Plain SPICE netlist (from kicad-cli, our parser, or Claude)
  .cir   — SPICE circuit file (treated same as .net)
  .sp    — SPICE file (treated same as .net)

Simulator: LTSpice (or ngspice as fallback if LTSpice not installed)
"""

import sys, os, json, time, argparse, tempfile, shutil, re
from pathlib import Path

# ── Dependency check ──────────────────────────────────────────────────────────

def check_pyltspice():
    try:
        import PyLTSpice
        return True, None
    except ImportError as e:
        return False, str(e)

# ── Simulator discovery ───────────────────────────────────────────────────────

LTSPICE_PATHS = [
    "/Applications/LTspice.app/Contents/MacOS/LTspice",
    "/Applications/LTSpiceXVII.app/Contents/MacOS/LTSpiceXVII",
    # Wine-based installs (Intel Mac)
    os.path.expanduser("~/.wine/drive_c/Program Files/LTC/LTspiceXVII/XVIIx64.exe"),
]

NGSPICE_PATHS = [
    "/opt/homebrew/bin/ngspice",   # Homebrew Apple Silicon
    "/usr/local/bin/ngspice",      # Homebrew Intel
    "/usr/bin/ngspice",
]

def find_ltspice(override=None):
    if override and os.path.exists(override):
        return override, "ltspice"
    for p in LTSPICE_PATHS:
        if os.path.exists(p):
            return p, "ltspice"
    # Fallback: ngspice can run plain SPICE netlists
    for p in NGSPICE_PATHS:
        if os.path.exists(p):
            return p, "ngspice"
    return None, None

# ── Netlist inspection ────────────────────────────────────────────────────────
# Read the SPICE text to understand what's in the circuit before injecting
# measurements. Works for both kicad-cli output and our own generated netlists.

def inspect_netlist(text):
    info = {
        "has_resistors":   False,
        "has_capacitors":  False,
        "has_inductors":   False,
        "voltage_sources": [],
        "output_nodes":    [],
        "supply_nodes":    [],
        "all_nodes":       set(),
        "sim_cmds":        [],
    }

    sim_re    = re.compile(r"^\.(TRAN|AC|DC|OP)\b", re.IGNORECASE)
    node_skip = {"0", "GND", "gnd", ""}

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("*") or line.startswith(";"):
            continue

        first = line[0].upper()
        parts = line.split()

        if first == "R":
            info["has_resistors"]  = True
        elif first == "C":
            info["has_capacitors"] = True
        elif first == "L":
            info["has_inductors"]  = True
        elif first == "V" and len(parts) >= 3:
            info["voltage_sources"].append({
                "ref":   parts[0],
                "nplus": parts[1],
                "nminus": parts[2],
            })

        # Collect node names from component lines (positions 1 and 2)
        if first in "RCLVIMQDX" and len(parts) >= 3:
            for node in parts[1:3]:
                if node not in node_skip and not node.startswith("."):
                    info["all_nodes"].add(node)
                    nl = node.lower()
                    if any(t in nl for t in ["out", "vout", "output"]):
                        info["output_nodes"].append(node)
                    if any(t in nl for t in ["vcc","vdd","5v","3v3","3.3","supply","pwr","vin"]):
                        info["supply_nodes"].append(node)

        # Track existing simulation commands
        m = sim_re.match(line)
        if m:
            info["sim_cmds"].append(line)

    info["all_nodes"]    = list(info["all_nodes"])
    info["output_nodes"] = list(dict.fromkeys(info["output_nodes"]))  # dedupe
    info["supply_nodes"] = list(dict.fromkeys(info["supply_nodes"]))
    return info

# ── Simulation command injection ──────────────────────────────────────────────
# Only inject a .TRAN/.AC/.OP if the netlist doesn't already have one.
# kicad-cli output from KiCad 7+ may already include the right command.

def ensure_sim_command(text, info):
    if info["sim_cmds"]:
        return text   # Already has simulation command — leave it alone

    # Choose based on circuit type
    if info["has_capacitors"] or info["has_inductors"]:
        cmd = ".TRAN 1n 1u"
    elif info["voltage_sources"]:
        cmd = ".OP"
    else:
        cmd = ".OP"

    lines = text.splitlines()
    end_i = next((i for i, l in enumerate(lines) if l.strip().upper() == ".END"), None)
    note  = f"* Physical Context: auto-added simulation command"
    if end_i is not None:
        lines.insert(end_i, note)
        lines.insert(end_i + 1, cmd)
    else:
        lines.extend([note, cmd, ".END"])
    return "\n".join(lines)

# ── .MEAS injection ───────────────────────────────────────────────────────────

def build_meas_block(info):
    sim = "TRAN"
    if info["sim_cmds"]:
        first_cmd = info["sim_cmds"][0].upper()
        if first_cmd.startswith(".AC"): sim = "AC"
        elif first_cmd.startswith(".DC"): sim = "DC"

    lines = ["", "* ── Physical Context DRC measurements ──────────────────────"]

    # Output nodes
    for node in info["output_nodes"][:4]:
        s = node.replace("/", "_").replace("\\", "_")
        lines += [
            f".MEAS {sim} {s}_max MAX V({node})",
            f".MEAS {sim} {s}_min MIN V({node})",
            f".MEAS {sim} {s}_avg AVG V({node})",
        ]

    # Supply nodes
    for node in info["supply_nodes"][:3]:
        s = node.replace("/","_")
        lines.append(f".MEAS {sim} {s}_max MAX V({node})")

    # Voltage source currents (power budget)
    for vs in info["voltage_sources"][:4]:
        ref = vs["ref"]
        lines += [
            f".MEAS {sim} I_{ref}_avg AVG I({ref})",
            f".MEAS {sim} I_{ref}_max MAX I({ref})",
        ]

    # General node voltages (catch any runaway node)
    measured = set(info["output_nodes"] + info["supply_nodes"])
    for node in info["all_nodes"][:6]:
        if node in measured: continue
        s = node.replace("/","_")
        lines.append(f".MEAS {sim} node_{s}_max MAX V({node})")

    lines.append("* ── End Physical Context measurements ──────────────────────")
    return "\n".join(lines)

def inject_meas(text, info):
    meas  = build_meas_block(info)
    lines = text.splitlines()
    end_i = next((i for i, l in enumerate(lines) if l.strip().upper() == ".END"), None)
    if end_i is not None:
        lines.insert(end_i, meas)
    else:
        lines.append(meas)
        lines.append(".END")
    return "\n".join(lines)

# ── DRC rules ─────────────────────────────────────────────────────────────────

DRC = [
    {"contains": "out",  "suffix": "_max",  "op": "gt",      "lim": 3.465,  "sev": "moderate",
     "msg": "Output voltage >3.465V (+5% of 3.3V rail)"},
    {"contains": "out",  "suffix": "_min",  "op": "lt",      "lim": 3.135,  "sev": "moderate",
     "msg": "Output voltage <3.135V (−5% of 3.3V rail)"},
    {"contains": "vcc",  "suffix": "_max",  "op": "gt",      "lim": 5.25,   "sev": "major",
     "msg": "VCC >5.25V — component overvoltage risk"},
    {"contains": "vdd",  "suffix": "_max",  "op": "gt",      "lim": 5.25,   "sev": "major",
     "msg": "VDD >5.25V — component overvoltage risk"},
    {"contains": "i_v",  "suffix": "_max",  "op": "abs_gt",  "lim": 2.0,    "sev": "major",
     "msg": "Peak supply current >2A — check trace widths"},
    {"contains": "i_v",  "suffix": "_avg",  "op": "abs_gt",  "lim": 1.0,    "sev": "moderate",
     "msg": "Average supply current >1A — sustained thermal risk"},
]

def apply_drc(meas):
    violations = []
    for rule in DRC:
        for k, v in meas.items():
            kl = k.lower()
            if rule["contains"] not in kl: continue
            if rule["suffix"]   not in kl: continue
            try: fv = float(v)
            except: continue
            hit = (rule["op"] == "gt"      and fv  > rule["lim"]) or \
                  (rule["op"] == "lt"      and fv  < rule["lim"]) or \
                  (rule["op"] == "abs_gt"  and abs(fv) > rule["lim"])
            if hit:
                violations.append({
                    "type": k, "value": round(fv,6), "limit": rule["lim"],
                    "severity": rule["sev"], "message": rule["msg"],
                })
    # Any node > 20V is suspicious regardless of naming
    for k, v in meas.items():
        if "_max" in k.lower() and "i_" not in k.lower():
            try:
                fv = float(v)
                if abs(fv) > 20:
                    violations.append({
                        "type": k, "value": round(fv,6), "limit": 20.0,
                        "severity": "major",
                        "message": f"Node {k} exceeds 20V — check power supply design",
                    })
            except: pass
    return violations

# ── Runner ────────────────────────────────────────────────────────────────────

def run_ltspice(net_path, ltspice_path, work_dir):
    from PyLTSpice import SimRunner, RawRead
    from PyLTSpice.log.ltsteps import LTSpiceLogReader

    runner = SimRunner(output_folder=work_dir, simulator=ltspice_path)
    t0     = time.time()
    try:
        runner.run(net_path)
    except Exception as e:
        return None, None, f"LTSpice run failed: {e}"
    elapsed = round(time.time() - t0, 2)

    raw_f = log_f = None
    for r, l in runner:
        raw_f, log_f = r, l; break

    return raw_f, log_f, None

def run_ngspice(net_path, ngspice_path, work_dir):
    """Run ngspice as a fallback simulator."""
    import subprocess
    out_csv = os.path.join(work_dir, "output.csv")
    t0      = time.time()
    result  = subprocess.run(
        [ngspice_path, "-b", "-o", os.path.join(work_dir, "ng.log"), net_path],
        capture_output=True, text=True, cwd=work_dir, timeout=120
    )
    elapsed = round(time.time() - t0, 2)
    # ngspice doesn't produce .raw in batch mode by default
    return None, os.path.join(work_dir, "ng.log"), None

def parse_results(raw_file, log_file):
    from PyLTSpice import RawRead
    from PyLTSpice.log.ltsteps import LTSpiceLogReader

    measurements, raw_traces, warnings = {}, {}, []

    if raw_file and os.path.exists(str(raw_file)):
        try:
            raw = RawRead(str(raw_file))
            for tname in raw.get_trace_names():
                trace = raw.get_trace(tname)
                steps = raw.get_steps() or [0]
                vals  = []
                for s in range(len(steps)):
                    w = trace.get_wave(s)
                    if w is not None and len(w) > 0:
                        vals.extend(w.real.tolist())
                if vals:
                    raw_traces[tname] = {
                        "max": round(max(vals), 6),
                        "min": round(min(vals), 6),
                        "avg": round(sum(vals)/len(vals), 6),
                    }
        except Exception as e:
            warnings.append(f"Raw parse error: {e}")

    if log_file and os.path.exists(str(log_file)):
        try:
            log = LTSpiceLogReader(str(log_file))
            for name in log.get_measure_names():
                vals = log[name]
                if vals: measurements[name] = vals[0]
        except Exception as e:
            warnings.append(f"Log parse error: {e}")

    return measurements, raw_traces, warnings

# ── Main simulation dispatch ──────────────────────────────────────────────────

def simulate(input_path, sim_path, sim_type, work_dir):
    from PyLTSpice import AscEditor

    suffix = Path(input_path).suffix.lower()

    # ── .asc: LTSpice schematic — use AscEditor to generate netlist ───────────
    if suffix == ".asc":
        work_asc = Path(work_dir) / Path(input_path).name
        shutil.copy2(input_path, work_asc)
        try:
            editor   = AscEditor(str(work_asc))
            net_text = work_asc.read_text(encoding="utf-8", errors="replace")
            info     = inspect_netlist(net_text)
            meas     = build_meas_block(info)
            for line in meas.splitlines():
                l = line.strip()
                if l and not l.startswith("*"):
                    editor.add_instructions(l)
            editor.save_netlist(str(work_asc))
        except Exception as e:
            sys.stderr.write(f"[PC] AscEditor note: {e}\n")
        net_path = str(work_asc).replace(".asc", ".net")
        try:
            from PyLTSpice import SimRunner
            runner = SimRunner(output_folder=work_dir, simulator=sim_path)
            runner.create_netlist(str(work_asc))
        except Exception as e:
            return error_out(f"Failed to create netlist from .asc: {e}")

    # ── .net / .cir / .sp: plain SPICE netlist (kicad-cli output, etc.) ───────
    else:
        raw_text = Path(input_path).read_text(encoding="utf-8", errors="replace")
        info     = inspect_netlist(raw_text)

        # Ensure there's a simulation command
        patched = ensure_sim_command(raw_text, info)
        # Inject measurements
        patched = inject_meas(patched, info)

        net_path = os.path.join(work_dir, Path(input_path).stem + "_pc.net")
        Path(net_path).write_text(patched, encoding="utf-8")

    if not os.path.exists(net_path):
        return error_out(f"Netlist not found after preprocessing: {net_path}")

    # Run the simulator
    t0 = time.time()
    if sim_type == "ltspice":
        raw_f, log_f, err = run_ltspice(net_path, sim_path, work_dir)
    else:
        raw_f, log_f, err = run_ngspice(net_path, sim_path, work_dir)
    elapsed = round(time.time() - t0, 2)

    if err:
        return error_out(err)

    measurements, raw_traces, warnings = parse_results(raw_f, log_f)
    all_meas = {**measurements, **{k: v["max"] for k, v in raw_traces.items()}}
    violations = apply_drc(all_meas)

    sev_order = {"major": 3, "moderate": 2, "minor": 1}
    overall   = "ok"
    if violations:
        worst   = max(violations, key=lambda v: sev_order.get(v["severity"], 0))
        overall = worst["severity"]

    sim_label = "LTSpice" if sim_type == "ltspice" else "ngspice"
    if not violations:
        summary = f"✅ {sim_label} simulation passed ({elapsed}s) — no DRC violations."
    else:
        bullets  = [f"• [{v['severity'].upper()}] {v['message']}" for v in violations]
        summary  = f"⚡ {len(violations)} violation(s) detected by {sim_label} ({elapsed}s):\n" \
                   + "\n".join(bullets)

    return {
        "status":       overall,
        "file":         Path(input_path).name,
        "simulator":    sim_label,
        "elapsed_s":    elapsed,
        "measurements": {k: round(float(v), 6) if isinstance(v, (int, float)) else v
                         for k, v in measurements.items()},
        "raw_traces":   raw_traces,
        "violations":   violations,
        "warnings":     warnings,
        "summary":      summary,
    }

def error_out(msg):
    return {"status": "error", "error": msg, "violations": [],
            "measurements": {}, "raw_traces": {}, "warnings": [msg],
            "summary": f"Simulation error: {msg}"}

# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Physical Context simulation bridge")
    ap.add_argument("input_file",
                    help="Path to .asc (LTSpice schematic) or .net/.cir/.sp (SPICE netlist)")
    ap.add_argument("--simulator", default=None,
                    help="Override simulator executable path")
    args = ap.parse_args()

    ok, err = check_pyltspice()
    if not ok:
        print(json.dumps({
            "status": "setup_required",
            "summary": "PyLTSpice not installed. Run: pip install PyLTSpice",
            "violations": [], "measurements": {}, "raw_traces": {}, "warnings": [],
        })); return

    sim_path, sim_type = find_ltspice(args.simulator)
    if not sim_path:
        print(json.dumps({
            "status": "setup_required",
            "summary": (
                "No simulator found. Install LTSpice from "
                "https://www.analog.com/en/resources/design-tools-and-calculators/ltspice-simulator.html"
                "\nExpected at /Applications/LTspice.app"
                "\nOr install ngspice: brew install ngspice"
            ),
            "violations": [], "measurements": {}, "raw_traces": {}, "warnings": [],
        })); return

    with tempfile.TemporaryDirectory(prefix="pc_spice_") as wd:
        result = simulate(args.input_file, sim_path, sim_type, wd)

    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
