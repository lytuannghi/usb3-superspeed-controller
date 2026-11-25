#!/usr/bin/env python3
"""Portable Icarus Verilog Simulation Runner (-Wall -g2005)."""
import glob
import os
import shutil
import subprocess
import sys


def find_tool(name):
    found = shutil.which(name)
    if found:
        return found
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    candidate = os.path.normpath(os.path.join(root, "..", "iverilog", "bin", f"usb3-superspeed-controller.exe"))
    if os.path.isfile(candidate):
        return candidate
    raise FileNotFoundError(f"Could not locate usb3-superspeed-controller in PATH or sibling iverilog/bin")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    os.chdir(root)
    os.makedirs("sim", exist_ok=True)

    rtl_files = sorted(glob.glob(os.path.join("rtl", "**", "*.v"), recursive=True))
    tb_files = sorted(glob.glob(os.path.join("tb", "**", "*.v"), recursive=True))
    sources = rtl_files + tb_files

    iverilog = find_tool("iverilog")
    vvp = find_tool("vvp")
    vvp_out = "sim/usb3_sim.vvp"

    cmd = [iverilog, "-Wall", "-g2005", "-s", "tb_usb3_controller", "-o", vvp_out] + sources
    comp = subprocess.run(cmd, capture_output=True, text=True)
    if comp.stdout:
        print(comp.stdout, end="")
    if comp.stderr:
        print(comp.stderr, end="", file=sys.stderr)
    if comp.returncode != 0 or comp.stderr.strip():
        print("[ERROR] Compilation failed or emitted warnings under -Wall.")
        return 1

    sim = subprocess.run([vvp, vvp_out], capture_output=True, text=True)
    print(sim.stdout, end="")
    if sim.stderr:
        print(sim.stderr, end="", file=sys.stderr)
    if sim.returncode != 0:
        return sim.returncode
    if "FAIL" in sim.stdout and "Tests Failed:         0" not in sim.stdout and "0 FAILED" not in sim.stdout:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
