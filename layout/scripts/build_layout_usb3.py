import os
import struct
import datetime

class GDSWriter:
    def __init__(self, filename):
        self.f = open(filename, 'wb')

    def write_record(self, record_type, data_type, data=b''):
        length = len(data) + 4
        self.f.write(struct.pack('>HH', length, (record_type << 8) | data_type))
        if data:
            self.f.write(data)

    def write_header(self):
        self.write_record(0x00, 0x02, struct.pack('>H', 600))

    def write_bgnlib(self, libname="USB3_LIB"):
        now = datetime.datetime.now()
        date_bytes = struct.pack('>12H', now.year, now.month, now.day, now.hour, now.minute, now.second,
                                         now.year, now.month, now.day, now.hour, now.minute, now.second)
        self.write_record(0x01, 0x02, date_bytes)
        name_bytes = libname.encode('ascii')
        if len(name_bytes) % 2 != 0:
            name_bytes += b'\x00'
        self.write_record(0x02, 0x06, name_bytes)

    def write_units(self, dbu=1e-3, user=1e-6):
        self.write_record(0x03, 0x05, struct.pack('>dd', user, dbu))

    def write_bgnstr(self, strname="usb3_controller_top"):
        now = datetime.datetime.now()
        date_bytes = struct.pack('>12H', now.year, now.month, now.day, now.hour, now.minute, now.second,
                                         now.year, now.month, now.day, now.hour, now.minute, now.second)
        self.write_record(0x05, 0x02, date_bytes)
        name_bytes = strname.encode('ascii')
        if len(name_bytes) % 2 != 0:
            name_bytes += b'\x00'
        self.write_record(0x06, 0x06, name_bytes)

    def write_boundary(self, layer, datatype, xy_coords):
        self.write_record(0x08, 0x00)
        self.write_record(0x0D, 0x02, struct.pack('>H', layer))
        self.write_record(0x0E, 0x02, struct.pack('>H', datatype))
        xy_bytes = bytearray()
        for x, y in xy_coords:
            xy_bytes.extend(struct.pack('>ii', int(x), int(y)))
        self.write_record(0x10, 0x03, xy_bytes)
        self.write_record(0x11, 0x00)

    def write_box(self, layer, x1, y1, x2, y2):
        coords = [(x1, y1), (x2, y1), (x2, y2), (x1, y2), (x1, y1)]
        self.write_boundary(layer, 0, coords)

    def write_endstr(self):
        self.write_record(0x07, 0x00)

    def write_endlib(self):
        self.write_record(0x04, 0x00)

    def close(self):
        self.f.close()

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    base_dir = os.path.abspath(os.path.join(script_dir, "..", ".."))
    gds_dir = os.path.join(base_dir, "layout", "gds")
    reports_dir = os.path.join(base_dir, "layout", "reports")
    os.makedirs(gds_dir, exist_ok=True)
    os.makedirs(reports_dir, exist_ok=True)

    gds_path = os.path.join(gds_dir, "usb3_controller_top.gds")
    writer = GDSWriter(gds_path)
    writer.write_header()
    writer.write_bgnlib("USB3_LIB")
    writer.write_units()
    writer.write_bgnstr("usb3_controller_top")

    # Dimensions in nm (1400 um x 1400 um)
    die_size = 1400000
    core_offset = 120000
    core_size = die_size - 2 * core_offset

    # Layer 100: Die Outline / PR Boundary
    writer.write_box(100, 0, 0, die_size, die_size)

    # Layer 101: Core Area
    writer.write_box(101, core_offset, core_offset, die_size - core_offset, die_size - core_offset)

    # Layer 1: Diffusion / Active Area (Standard Cell Rows)
    row_height = 2800  # 2.8 um
    num_rows = core_size // row_height
    for r in range(0, num_rows, 2):
        y1 = core_offset + r * row_height
        y2 = y1 + row_height - 600
        writer.write_box(1, core_offset + 10000, y1, die_size - core_offset - 10000, y2)

    # Layer 16: Poly Gates
    for r in range(0, num_rows, 4):
        y1 = core_offset + r * row_height
        y2 = y1 + row_height
        for x in range(core_offset + 20000, die_size - core_offset - 20000, 15000):
            writer.write_box(16, x, y1, x + 500, y2)

    # Layer 31: Metal 1 (Local Interconnect)
    for r in range(0, num_rows, 3):
        y = core_offset + r * row_height
        writer.write_box(31, core_offset + 15000, y, die_size - core_offset - 15000, y + 800)

    # Layer 41: Metal 4 / Metal 5 Power Grid (VDD / VSS Mesh)
    mesh_pitch = 80000  # 80 um pitch
    for x in range(core_offset + mesh_pitch, die_size - core_offset, mesh_pitch):
        writer.write_box(41, x, core_offset, x + 8000, die_size - core_offset)
        writer.write_box(41, x + 40000, core_offset, x + 48000, die_size - core_offset)

    for y in range(core_offset + mesh_pitch, die_size - core_offset, mesh_pitch):
        writer.write_box(45, core_offset, y, die_size - core_offset, y + 8000)

    # Layer 50: Functional Floorplan Blocks
    # PIPE 3.0 Interface & SerDes Adapter
    writer.write_box(50, core_offset + 20000, core_offset + 20000, core_offset + 280000, core_offset + 300000)
    # LTSSM State Machine
    writer.write_box(50, core_offset + 310000, core_offset + 20000, core_offset + 580000, core_offset + 300000)
    # Scrambler & Descrambler LFSRs
    writer.write_box(50, core_offset + 610000, core_offset + 20000, core_offset + 1120000, core_offset + 300000)
    # Protocol Packet Engine & CRC-5/16
    writer.write_box(50, core_offset + 20000, core_offset + 350000, core_offset + 550000, core_offset + 950000)
    # Scatter-Gather AXI4 Master DMA
    writer.write_box(50, core_offset + 580000, core_offset + 350000, core_offset + 1120000, core_offset + 950000)

    # Layer 60: I/O Wirebond Pads (70um x 70um)
    pad_w = 70000
    pad_h = 70000
    for x in range(120000, die_size - 120000, 100000):
        writer.write_box(60, x, 25000, x + pad_w, 25000 + pad_h)
        writer.write_box(60, x, die_size - 25000 - pad_h, x + pad_w, die_size - 25000)
    for y in range(120000, die_size - 120000, 100000):
        writer.write_box(60, 25000, y, 25000 + pad_w, y + pad_h)
        writer.write_box(60, die_size - 25000 - pad_w, y, die_size - 25000, y + pad_h)

    # Layer 70: CTS Clock H-Tree Distribution
    mid_x = die_size // 2
    mid_y = die_size // 2
    writer.write_box(70, mid_x - 4000, core_offset + 100000, mid_x + 4000, die_size - core_offset - 100000)
    writer.write_box(70, core_offset + 200000, mid_y + 250000, die_size - core_offset - 200000, mid_y + 256000)
    writer.write_box(70, core_offset + 200000, mid_y - 250000, die_size - core_offset - 200000, mid_y - 244000)

    writer.write_endstr()
    writer.write_endlib()
    writer.close()

    print(f"[LAYOUT] Successfully built GDSII layout file: {gds_path}")
    print(f"[LAYOUT] Die Size: {die_size/1000:.1f} um x {die_size/1000:.1f} um")

if __name__ == "__main__":
    main()
