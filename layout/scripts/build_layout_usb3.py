#!/usr/bin/env python3
"""
SkyWater 130nm Multi-Layer Physical GDSII Layout Generator for usb3_controller_top.
Produces a DRC-clean macro floorplan, dual M4/M5 power ring, standard-cell rails,
I/O pad ring, and verifies all geometric rules with verify_gds_drc.py.
"""
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from verify_gds_drc import GDSWriter, verify_gds


def build_layout():
    layout_dir = os.path.dirname(SCRIPT_DIR)
    gds_path = os.path.join(layout_dir, "gds", "usb3_controller_top.gds")
    report_path = os.path.join(layout_dir, "reports", "drc_report.txt")
    os.makedirs(os.path.dirname(gds_path), exist_ok=True)
    os.makedirs(os.path.dirname(report_path), exist_ok=True)

    die_w = 360000
    die_h = 360000
    macro_cols = 4
    macro_rows = 4
    pad_count = 10

    L_DIE_AREA = 235
    L_NWELL = 64
    L_DIFF = 65
    L_POLY = 66
    L_CONTACT = 67
    L_MET1 = 68
    L_VIA1 = 69
    L_MET2 = 70
    L_VIA2 = 71
    L_MET3 = 72
    L_VIA3 = 73
    L_MET4 = 74
    L_VIA4 = 75
    L_MET5 = 76
    L_PAD = 108

    gds = GDSWriter(gds_path, "USB3_LIB")
    gds.start_structure("usb3_controller_top")
    gds.add_box(L_DIE_AREA, 0, 0, 0, die_w, die_h)

    RING_M = 28000
    RING_W = 5000
    CORE_X1 = RING_M + RING_W + 10000
    CORE_Y1 = RING_M + RING_W + 10000
    CORE_X2 = die_w - RING_M - RING_W - 10000
    CORE_Y2 = die_h - RING_M - RING_W - 10000

    # Top & Bottom M5 rings; Left & Right M4 rings (bridged at corners via VIA4)
    gds.add_box(L_MET5, 0, RING_M, RING_M, die_w - RING_M, RING_M + RING_W)
    gds.add_box(L_MET5, 0, RING_M, die_h - RING_M - RING_W, die_w - RING_M, die_h - RING_M)
    gds.add_box(L_MET4, 0, RING_M, RING_M, RING_M + RING_W, die_h - RING_M)
    gds.add_box(L_MET4, 0, die_w - RING_M - RING_W, RING_M, die_w - RING_M, die_h - RING_M)

    for vx in (RING_M + 1000, die_w - RING_M - RING_W + 1000):
        for vy in (RING_M + 1000, die_h - RING_M - RING_W + 1000):
            gds.add_box(L_VIA4, 0, vx, vy, vx + 3000, vy + 3000)

    # Perimeter Wirebond Pads
    PAD_W, PAD_H = 12000, 12000
    span_x = (CORE_X2 - CORE_X1) // pad_count
    span_y = (CORE_Y2 - CORE_Y1) // pad_count
    for i in range(pad_count):
        px = CORE_X1 + i * span_x + (span_x - PAD_W) // 2
        gds.add_box(L_PAD, 0, px, 6000, px + PAD_W, 6000 + PAD_H)
        gds.add_box(L_PAD, 0, px, die_h - 6000 - PAD_H, px + PAD_W, die_h - 6000)
        py = CORE_Y1 + i * span_y + (span_y - PAD_H) // 2
        gds.add_box(L_PAD, 0, 6000, py, 6000 + PAD_W, py + PAD_H)
        gds.add_box(L_PAD, 0, die_w - 6000 - PAD_W, py, die_w - 6000, py + PAD_H)

    # Non-overlapping Subsystem Macro Grid
    mw = (CORE_X2 - CORE_X1 - (macro_cols - 1) * 14000) // macro_cols
    mh = (CORE_Y2 - CORE_Y1 - (macro_rows - 1) * 14000) // macro_rows
    for r in range(macro_rows):
        for c in range(macro_cols):
            mx1 = CORE_X1 + c * (mw + 14000)
            my1 = CORE_Y1 + r * (mh + 14000)
            mx2 = mx1 + mw
            my2 = my1 + mh
            gds.add_box(L_NWELL, 0, mx1 + 2000, my1 + 2000, mx2 - 2000, my1 + mh // 2)
            gds.add_box(L_DIFF, 0, mx1 + 3500, my1 + 3500, mx2 - 3500, my1 + 11500)
            gds.add_box(L_POLY, 0, mx1 + 5000, my1 + 2800, mx1 + 6500, my1 + 12500)
            gds.add_box(L_CONTACT, 0, mx1 + 8500, my1 + 5500, mx1 + 10000, my1 + 7000)
            # Horizontal M1 rail strips (spacing >= 1200nm)
            for ry in range(my1 + 15000, my2 - 6000, 4000):
                gds.add_box(L_MET1, 0, mx1 + 3000, ry, mx2 - 3000, ry + 1500)
            # Vertical M2 local buses (non-overlapping with adjacent columns)
            for bx in range(mx1 + 12000, mx2 - 12000, 12000):
                gds.add_box(L_MET2, 0, bx, my1 + 14000, bx + 2000, my2 - 6000)

    # Global M3 Interconnect Channels strictly between macro columns
    for c in range(1, macro_cols):
        cx = CORE_X1 + c * (mw + 14000) - 9000
        gds.add_box(L_MET3, 0, cx, CORE_Y1, cx + 3000, CORE_Y2)
        gds.add_box(L_MET3, 0, cx + 6000, CORE_Y1, cx + 9000, CORE_Y2)

    gds.end_structure()
    gds.close()

    total_v = verify_gds(
        gds_path=gds_path,
        report_path=report_path,
        top_name="usb3_controller_top",
        tech_name="SkyWater 130nm",
    )
    print(f"[OK] Generated {gds_path} ({os.path.getsize(gds_path)} bytes), DRC violations={total_v}")
    return 0 if total_v == 0 else 1


if __name__ == "__main__":
    sys.exit(build_layout())
