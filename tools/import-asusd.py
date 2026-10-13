#!/usr/bin/env python3
"""Converts a Linux asusctl/asusd setup into a RogControl config.json.

usage: import-asusd.py DIR > config.json
DIR holds copies of /etc/asusd/asusd.ron, fan_curves.ron, aura_*.ron and, if you cap clocks
with systemd units, any *.service files running `cpupower frequency-set -u` / `nvidia-smi -lgc`.
"""
import glob
import json
import os
import re
import sys


class Ron:
    """Just enough RON for asusd's files: structs, tuples, lists, maps, enums, Some(x)."""

    TOKEN = re.compile(r'\s*(?://[^\n]*\n\s*)*(r#[A-Za-z_]\w*|[A-Za-z_]\w*|-?\d+(?:\.\d+)?|"(?:[^"\\]|\\.)*"|[(){}\[\]:,])')

    def __init__(self, text):
        self.tokens = self.TOKEN.findall(text)
        self.i = 0

    def peek(self, k=0):
        return self.tokens[self.i + k] if self.i + k < len(self.tokens) else None

    def take(self, expected=None):
        tok = self.tokens[self.i]
        self.i += 1
        if expected and tok != expected:
            raise ValueError(f"expected {expected}, got {tok}")
        return tok

    def value(self):
        tok = self.peek()
        if tok == "(":
            self.take()
            if re.fullmatch(r"r?#?[A-Za-z_]\w*", self.peek() or "") and self.peek(1) == ":":
                return self.fields(")")
            return self.items(")")
        if tok == "[":
            self.take()
            return self.items("]")
        if tok == "{":
            self.take()
            out = {}
            while self.peek() != "}":
                key = self.value()
                self.take(":")
                out[str(key)] = self.value()
                if self.peek() == ",":
                    self.take()
            self.take("}")
            return out
        self.take()
        if tok.startswith('"'):
            return json.loads(tok)
        if re.fullmatch(r"-?\d+", tok):
            return int(tok)
        if re.fullmatch(r"-?\d+\.\d+", tok):
            return float(tok)
        if tok in ("true", "false"):
            return tok == "true"
        name = tok[2:] if tok.startswith("r#") else tok
        if self.peek() == "(":            # enum variant with a payload, e.g. Some(x)
            self.take()
            inner = self.items(")")
            return inner[0] if name == "Some" and len(inner) == 1 else {name: inner}
        return None if name == "None" else name

    def fields(self, close):
        out = {}
        while self.peek() != close:
            key = self.take()
            self.take(":")
            out[key[2:] if key.startswith("r#") else key] = self.value()
            if self.peek() == ",":
                self.take()
        self.take(close)
        return out

    def items(self, close):
        out = []
        while self.peek() != close:
            out.append(self.value())
            if self.peek() == ",":
                self.take()
        self.take(close)
        return out


def load_ron(path):
    with open(path) as f:
        return Ron(f.read()).value()


PROFILES = {"Quiet": "quiet", "Balanced": "balanced", "Performance": "performance"}
EPP = {"Performance": "performance", "BalancePerformance": "balance_performance",
       "BalancePower": "balance_power", "Power": "power"}
TUNING = {"PptPl1Spl": "pl1", "PptPl2Sppt": "pl2", "PptPl3Fppt": "fppt",
          "NvDynamicBoost": "gpu_dynamic_boost", "NvTempTarget": "gpu_temp_target"}


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "."
    cfg = {"version": 1, "profiles": {}}
    notes = []
    prof = lambda name: cfg["profiles"].setdefault(name, {})

    path = os.path.join(src, "fan_curves.ron")
    if os.path.exists(path):
        for name, fans in load_ron(path)["profiles"].items():
            if name not in PROFILES.values() or not fans:
                continue
            curves = {"enabled": all(f.get("enabled") for f in fans)}
            for f in fans:
                # asus-wmi turns pwm (0-255) into percent with integer division
                curves[f["fan"].lower()] = [[t, p * 100 // 255] for t, p in zip(f["temp"], f["pwm"])]
            prof(name)["fan_curves"] = curves

    path = os.path.join(src, "asusd.ron")
    if os.path.exists(path):
        a = load_ron(path)
        if a.get("charge_control_end_threshold"):
            cfg["charge_limit"] = a["charge_control_end_threshold"]
        if a.get("change_platform_profile_on_ac") or a.get("change_platform_profile_on_battery"):
            cfg["auto_profile"] = {"enabled": True,
                                   "on_ac": PROFILES.get(a.get("platform_profile_on_ac"), "balanced"),
                                   "on_battery": PROFILES.get(a.get("platform_profile_on_battery"), "quiet")}
        if a.get("platform_profile_linked_epp"):
            for asusd_name, name in PROFILES.items():
                epp = EPP.get(a.get(f"profile_{name}_epp"))
                if epp:
                    prof(name)["epp"] = epp
        for key, power in (("ac_profile_tunings", "ac"), ("dc_profile_tunings", "battery")):
            for asusd_name, t in (a.get(key) or {}).items():
                if asusd_name not in PROFILES:
                    notes.append(f"{key}.{asusd_name}: no matching ASUS performance mode, skipped")
                    continue
                tuning = {"enabled": bool(t.get("enabled"))}
                for k, v in (t.get("group") or {}).items():
                    if k in TUNING:
                        tuning[TUNING[k]] = v
                prof(PROFILES[asusd_name]).setdefault("tunings", {})[power] = tuning
        armoury = a.get("armoury_settings") or {}
        if "PanelOverdrive" in armoury:
            cfg["panel_overdrive"] = bool(armoury["PanelOverdrive"])

    for path in glob.glob(os.path.join(src, "*.service")):
        text = open(path).read()
        m = re.search(r"cpupower\s+frequency-set\s+.*?-u\s+(\d+(?:\.\d+)?)\s*([kKMG]?)", text)
        if m:
            value, unit = float(m.group(1)), m.group(2).upper()
            mhz = value / 1000 if unit in ("", "K") else value if unit == "M" else value * 1000
            cfg["cpu_max_mhz"] = int(mhz)
        m = re.search(r"nvidia-smi\s+.*?-lgc\s+(\d+),(\d+)", text)
        if m:
            cfg["gpu_clock_mhz"] = [int(m.group(1)), int(m.group(2))]

    for path in glob.glob(os.path.join(src, "aura_*.ron")):
        aura = load_ron(path)
        mode = aura.get("current_mode")
        effect = (aura.get("builtins") or {}).get(mode) or {}
        c = effect.get("colour1") or {}
        cfg["aura"] = {"mode": str(mode).lower(), "brightness": str(aura.get("brightness", "")).lower(),
                       "colour": "%02x%02x%02x" % (c.get("r", 0), c.get("g", 0), c.get("b", 0))}

    json.dump(cfg, sys.stdout, indent=2, sort_keys=True)
    print()
    for n in notes:
        print(f"note: {n}", file=sys.stderr)


if __name__ == "__main__":
    main()
