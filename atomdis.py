#!/usr/bin/env python3
"""ATOM BIOS bytecode disassembler for AMD GPU VBIOSes.

Based on the kernel's atom.c interpreter (drivers/gpu/drm/amd/amdgpu/atom.c).
Supports ATOM BIOS v1.x (atombios.h) and v2.x (atomfirmware.h) structures.

Usage: python3 atomdis.py <vbios.rom> [--table <index>] [--all] [--data]
"""

import struct
import sys
import argparse

# Argument types (lower 3 bits of attr)
ARG_REG = 0
ARG_PS  = 1
ARG_WS  = 2
ARG_FB  = 3
ARG_ID  = 4
ARG_IMM = 5
ARG_PLL = 6
ARG_MC  = 7

ARG_NAMES = ['REG', 'PS', 'WS', 'FB', 'ID', 'IMM', 'PLL', 'MC']

# Source alignment (bits[5:3] of attr)
SRC_DWORD  = 0
SRC_WORD0  = 1
SRC_WORD8  = 2
SRC_WORD16 = 3
SRC_BYTE0  = 4
SRC_BYTE8  = 5
SRC_BYTE16 = 6
SRC_BYTE24 = 7

ALIGN_NAMES = [
    '.[31:0]', '.[15:0]', '.[23:8]', '.[31:16]',
    '.[7:0]', '.[15:8]', '.[23:16]', '.[31:24]'
]

# Workspace special indices
WS_NAMES = {
    0x40: 'QUOTIENT', 0x41: 'REMAINDER', 0x42: 'DATAPTR',
    0x43: 'SHIFT', 0x44: 'OR_MASK', 0x45: 'AND_MASK',
    0x46: 'FB_WINDOW', 0x47: 'ATTRIBUTES', 0x48: 'REGPTR',
}

# Destination alignment translation (from atom.c atom_dst_to_src)
DST_TO_SRC = [
    [0, 0, 0, 0],
    [1, 2, 3, 0],
    [1, 2, 3, 0],
    [1, 2, 3, 0],
    [4, 5, 6, 7],
    [4, 5, 6, 7],
    [4, 5, 6, 7],
    [4, 5, 6, 7],
]

# Command table names (from atom-names.h / atomfirmware.h)
CMD_TABLE_NAMES = {
    0: 'ASIC_Init', 1: 'GetDisplaySurfaceSize', 2: 'ASIC_RegistersInit',
    3: 'VRAM_BlockVenderDetection', 4: 'DIGxEncoderControl',
    5: 'MemoryControllerInit', 6: 'EnableCRTCMemReq',
    7: 'MemoryParamAdjust', 8: 'DVOEncoderControl',
    9: 'GPIOPinControl', 10: 'SetEngineClock', 11: 'SetMemoryClock',
    12: 'SetPixelClock', 14: 'DynamicClockGating',
    15: 'ResetMemoryDLL', 16: 'ResetMemoryDevice',
    18: 'ShortTimeMemoryTest', 21: 'SelectCRTC_Source',
    22: 'EnableGraphSurfaces', 23: 'UpdateCRTC_DoubleBufferRegisters',
    24: 'LUT_AutoFill', 27: 'EnableHW_IconCursor',
    28: 'GetMemoryClock', 29: 'GetEngineClock',
    30: 'SetCRTC_UsingDTDTiming', 31: 'ExternalEncoderControl',
    33: 'EnableDispPowerGating', 34: 'SetUniphyInstance',
    36: 'BlankCRTC', 39: 'EnableCRTC', 40: 'GetPixelClock',
    41: 'EnableVGA_Render', 42: 'GetSCLKOverMCLKRatio',
    43: 'SetCRTC_Timing', 44: 'SetCRTC_Overscan',
    53: 'ReadEfuseValue', 54: 'ComputeMemoryEnginePLL',
    56: 'Gfx_Init',
}

# Data table names
DATA_TABLE_NAMES = {
    0: 'UtilityPipeLine', 1: 'MultimediaCapabilityInfo',
    2: 'MultimediaConfigInfo', 3: 'StandardVESA_Timing',
    4: 'FirmwareInfo', 5: 'PaletteData', 6: 'LCD_Info',
    7: 'DIGTransmitterInfo', 8: 'SMU_Info',
    9: 'SupportedDevicesInfo', 10: 'GPIO_I2C_Info',
    11: 'VRAM_UsageByFirmware', 12: 'GPIO_Pin_LUT',
    13: 'VESA_ToInternalModeLUT', 14: 'GFX_Info',
    15: 'PowerPlayInfo', 16: 'GPUVirtualizationInfo',
    17: 'SaveRestoreInfo', 18: 'PPLL_SS_Info',
    19: 'OemInfo', 20: 'XTMDS_Info', 21: 'MclkSS_Info',
    22: 'ObjectHeader', 23: 'IndirectIOAccess',
    24: 'MC_InitParameter', 25: 'ASIC_VDDC_Info',
    26: 'ASIC_InternalSS_Info', 27: 'TV_VideoMode',
    28: 'VRAM_Info', 29: 'MemoryTrainingInfo',
    30: 'IntegratedSystemInfo', 31: 'ASIC_ProfilingInfo',
    32: 'VoltageObjectInfo', 33: 'PowerSourceInfo',
    34: 'ServiceInfo',
}


def u8(data, off):
    return data[off] if off < len(data) else 0

def u16(data, off):
    return struct.unpack_from('<H', data, off)[0] if off + 1 < len(data) else 0

def u32(data, off):
    return struct.unpack_from('<I', data, off)[0] if off + 3 < len(data) else 0


def format_arg(arg_type, idx):
    if arg_type == ARG_WS and idx in WS_NAMES:
        return f'WS[{WS_NAMES[idx]}]'
    return f'{ARG_NAMES[arg_type]}[0x{idx:02X}]' if idx < 0x100 else f'{ARG_NAMES[arg_type]}[0x{idx:04X}]'


def src_operand_size(arg_type, align):
    """Return the number of bytes consumed by a source operand."""
    if arg_type == ARG_REG or arg_type == ARG_ID:
        return 2
    if arg_type in (ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC):
        return 1
    if arg_type == ARG_IMM:
        if align == SRC_DWORD:
            return 4
        if align in (SRC_WORD0, SRC_WORD8, SRC_WORD16):
            return 2
        return 1  # BYTE variants
    return 0


def read_src_operand(data, ptr, attr):
    """Read a source operand. Returns (string, new_ptr)."""
    arg = attr & 7
    align = (attr >> 3) & 7
    start = ptr

    if arg == ARG_REG:
        idx = u16(data, ptr); ptr += 2
        return f'REG[0x{idx:04X}]{ALIGN_NAMES[align]}', ptr
    elif arg == ARG_PS:
        idx = u8(data, ptr); ptr += 1
        return f'PS[0x{idx:02X}]{ALIGN_NAMES[align]}', ptr
    elif arg == ARG_WS:
        idx = u8(data, ptr); ptr += 1
        name = WS_NAMES.get(idx, f'0x{idx:02X}')
        return f'WS[{name}]{ALIGN_NAMES[align]}', ptr
    elif arg == ARG_FB:
        idx = u8(data, ptr); ptr += 1
        return f'FB[0x{idx:02X}]{ALIGN_NAMES[align]}', ptr
    elif arg == ARG_ID:
        idx = u16(data, ptr); ptr += 2
        return f'ID[0x{idx:04X}]{ALIGN_NAMES[align]}', ptr
    elif arg == ARG_IMM:
        if align == SRC_DWORD:
            val = u32(data, ptr); ptr += 4
            return f'0x{val:08X}', ptr
        elif align in (SRC_WORD0, SRC_WORD8, SRC_WORD16):
            val = u16(data, ptr); ptr += 2
            return f'0x{val:04X}', ptr
        else:
            val = u8(data, ptr); ptr += 1
            return f'0x{val:02X}', ptr
    elif arg == ARG_PLL:
        idx = u8(data, ptr); ptr += 1
        return f'PLL[0x{idx:02X}]{ALIGN_NAMES[align]}', ptr
    elif arg == ARG_MC:
        idx = u8(data, ptr); ptr += 1
        return f'MC[0x{idx:02X}]{ALIGN_NAMES[align]}', ptr

    return '???', ptr


def read_dst_operand(data, ptr, dst_arg, attr):
    """Read a destination operand. Returns (string, new_ptr)."""
    src_align_idx = (attr >> 3) & 7
    dst_align_sel = (attr >> 6) & 3
    align = DST_TO_SRC[src_align_idx][dst_align_sel]
    # Construct a synthetic attr for the dst
    synth_attr = dst_arg | (align << 3)
    return read_src_operand(data, ptr, synth_attr)


def skip_src(data, ptr, attr):
    """Skip a source operand without reading it. Returns new_ptr."""
    arg = attr & 7
    align = (attr >> 3) & 7
    return ptr + src_operand_size(arg, align)


def skip_dst(data, ptr, dst_arg, attr):
    """Skip a destination operand. Returns new_ptr."""
    src_align_idx = (attr >> 3) & 7
    dst_align_sel = (attr >> 6) & 3
    align = DST_TO_SRC[src_align_idx][dst_align_sel]
    synth_attr = dst_arg | (align << 3)
    return skip_src(data, ptr, synth_attr)


# Instruction disassembly functions

def dis_two_op(data, ptr, dst_arg, mnemonic):
    """Disassemble a two-operand instruction (dst op= src)."""
    attr = u8(data, ptr); ptr += 1
    dst_str, ptr = read_dst_operand(data, ptr, dst_arg, attr)
    src_str, ptr = read_src_operand(data, ptr, attr)
    return f'{mnemonic} {dst_str}, {src_str}', ptr


def dis_mask(data, ptr, dst_arg):
    """Disassemble MASK instruction (dst = (dst & mask) | src)."""
    attr = u8(data, ptr); ptr += 1
    dst_str, ptr2 = read_dst_operand(data, ptr, dst_arg, attr)
    ptr = ptr2
    # mask is a direct value with the same alignment as dst
    src_align = (attr >> 3) & 7
    if src_align == SRC_DWORD:
        mask = u32(data, ptr); ptr += 4
        mask_str = f'0x{mask:08X}'
    elif src_align in (SRC_WORD0, SRC_WORD8, SRC_WORD16):
        mask = u16(data, ptr); ptr += 2
        mask_str = f'0x{mask:04X}'
    else:
        mask = u8(data, ptr); ptr += 1
        mask_str = f'0x{mask:02X}'
    src_str, ptr = read_src_operand(data, ptr, attr)
    return f'MASK {dst_str}, {mask_str}, {src_str}', ptr


def dis_clear(data, ptr, dst_arg):
    """Disassemble CLEAR instruction."""
    attr = u8(data, ptr); ptr += 1
    attr_mod = attr & 0x38
    attr_mod |= ([0, 0, 1, 2, 0, 1, 2, 3][(attr_mod >> 3)]) << 6
    dst_str, ptr = read_dst_operand(data, ptr, dst_arg, attr_mod)
    return f'CLEAR {dst_str}', ptr


def dis_shift_const(data, ptr, dst_arg, mnemonic):
    """Disassemble shift with constant (SHIFT_LEFT/SHIFT_RIGHT)."""
    attr = u8(data, ptr); ptr += 1
    attr_mod = attr & 0x38
    attr_mod |= ([0, 0, 1, 2, 0, 1, 2, 3][(attr_mod >> 3)]) << 6
    dst_str, ptr = read_dst_operand(data, ptr, dst_arg, attr_mod)
    shift = u8(data, ptr); ptr += 1
    return f'{mnemonic} {dst_str}, {shift}', ptr


def dis_compare(data, ptr, dst_arg):
    """Disassemble COMPARE."""
    attr = u8(data, ptr); ptr += 1
    src1_str, ptr = read_dst_operand(data, ptr, dst_arg, attr)
    src2_str, ptr = read_src_operand(data, ptr, attr)
    return f'COMPARE {src1_str}, {src2_str}', ptr


def dis_test(data, ptr, dst_arg):
    """Disassemble TEST."""
    attr = u8(data, ptr); ptr += 1
    src1_str, ptr = read_dst_operand(data, ptr, dst_arg, attr)
    src2_str, ptr = read_src_operand(data, ptr, attr)
    return f'TEST {src1_str}, {src2_str}', ptr


def dis_setfbbase(data, ptr):
    """Disassemble SETFBBASE."""
    attr = u8(data, ptr); ptr += 1
    src_str, ptr = read_src_operand(data, ptr, attr)
    return f'SETFBBASE {src_str}', ptr


def dis_switch(data, ptr, base):
    """Disassemble SWITCH."""
    attr = u8(data, ptr); ptr += 1
    src_str, ptr = read_src_operand(data, ptr, attr)
    lines = [f'SWITCH {src_str}']
    while ptr + 1 < len(data) and u16(data, ptr) != 0x5A5A:
        if u8(data, ptr) == 0x63:  # CASE_MAGIC
            ptr += 1
            case_attr = (attr & 0x38) | ARG_IMM
            val_str, ptr = read_src_operand(data, ptr, case_attr)
            target = u16(data, ptr); ptr += 2
            lines.append(f'  CASE {val_str}: -> 0x{base + target:04X}')
        else:
            lines.append(f'  BAD_CASE at 0x{ptr:04X}')
            break
    if ptr + 1 < len(data):
        ptr += 2  # skip CASE_END
    return '\n'.join(lines), ptr


# Build the opcode table matching atom.c exactly
# (opcode_index, instruction_type, arg/subtype)
OPCODES = []

# 0x00: reserved/NOP
OPCODES.append(('NOP', None, None))

# 0x01-0x06: MOVE to REG/PS/WS/FB/PLL/MC
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('MOVE', 'two_op', dst))

# 0x07-0x0C: AND
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('AND', 'two_op', dst))

# 0x0D-0x12: OR
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('OR', 'two_op', dst))

# 0x13-0x18: SHIFT_LEFT (constant shift)
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('SHIFT_LEFT', 'shift_const', dst))

# 0x19-0x1E: SHIFT_RIGHT (constant shift)
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('SHIFT_RIGHT', 'shift_const', dst))

# 0x1F-0x24: MUL
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('MUL', 'two_op', dst))

# 0x25-0x2A: DIV
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('DIV', 'two_op', dst))

# 0x2B-0x30: ADD
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('ADD', 'two_op', dst))

# 0x31-0x36: SUB
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('SUB', 'two_op', dst))

# 0x37-0x39: SETPORT
OPCODES.append(('SETPORT_ATI', 'setport_ati', None))
OPCODES.append(('SETPORT_PCI', 'setport_pci', None))
OPCODES.append(('SETPORT_SYSIO', 'setport_sysio', None))

# 0x3A: SETREGBLOCK
OPCODES.append(('SETREGBLOCK', 'setregblock', None))

# 0x3B: SETFBBASE
OPCODES.append(('SETFBBASE', 'setfbbase', None))

# 0x3C-0x41: COMPARE
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('COMPARE', 'compare', dst))

# 0x42: SWITCH
OPCODES.append(('SWITCH', 'switch', None))

# 0x43-0x49: JUMP variants
OPCODES.append(('JMP', 'jump', 'ALWAYS'))
OPCODES.append(('JE', 'jump', 'EQUAL'))
OPCODES.append(('JB', 'jump', 'BELOW'))
OPCODES.append(('JA', 'jump', 'ABOVE'))
OPCODES.append(('JBE', 'jump', 'BELOWOREQUAL'))
OPCODES.append(('JAE', 'jump', 'ABOVEOREQUAL'))
OPCODES.append(('JNE', 'jump', 'NOTEQUAL'))

# 0x4A-0x4F: TEST
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('TEST', 'test', dst))

# 0x50-0x51: DELAY
OPCODES.append(('DELAY_MS', 'delay', None))
OPCODES.append(('DELAY_US', 'delay', None))

# 0x52: CALLTABLE
OPCODES.append(('CALLTABLE', 'calltable', None))

# 0x53: REPEAT
OPCODES.append(('REPEAT', 'nop', None))

# 0x54-0x59: CLEAR
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('CLEAR', 'clear', dst))

# 0x5A: NOP
OPCODES.append(('NOP', 'nop', None))

# 0x5B: EOT
OPCODES.append(('EOT', 'nop', None))

# 0x5C-0x61: MASK
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('MASK', 'mask', dst))

# 0x62: POSTCARD
OPCODES.append(('POSTCARD', 'postcard', None))

# 0x63: BEEP
OPCODES.append(('BEEP', 'nop', None))

# 0x64: SAVEREG
OPCODES.append(('SAVEREG', 'nop', None))

# 0x65: RESTOREREG
OPCODES.append(('RESTOREREG', 'nop', None))

# 0x66: SETDATABLOCK
OPCODES.append(('SETDATABLOCK', 'setdatablock', None))

# 0x67-0x6C: XOR
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('XOR', 'two_op', dst))

# 0x6D-0x72: SHL (variable shift from src)
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('SHL', 'two_op', dst))

# 0x73-0x78: SHR (variable shift from src)
for dst in [ARG_REG, ARG_PS, ARG_WS, ARG_FB, ARG_PLL, ARG_MC]:
    OPCODES.append(('SHR', 'two_op', dst))

# 0x79: DEBUG
OPCODES.append(('DEBUG', 'debug', None))

# 0x7A: PROCESSDS
OPCODES.append(('PROCESSDS', 'processds', None))

# 0x7B-0x7C: MUL32 PS/WS
OPCODES.append(('MUL32', 'two_op', ARG_PS))
OPCODES.append(('MUL32', 'two_op', ARG_WS))

# 0x7D-0x7E: DIV32 PS/WS
OPCODES.append(('DIV32', 'two_op', ARG_PS))
OPCODES.append(('DIV32', 'two_op', ARG_WS))

assert len(OPCODES) == 127, f"Expected 127 opcodes, got {len(OPCODES)}"


def disassemble_instruction(data, ptr, base):
    """Disassemble one instruction at ptr. Returns (text, new_ptr) or None if EOT."""
    if ptr >= len(data):
        return None, ptr

    op = u8(data, ptr)
    ptr += 1

    if op >= len(OPCODES):
        return f'UNKNOWN_OP 0x{op:02X}', ptr

    name, itype, arg = OPCODES[op]

    if itype is None or itype == 'nop':
        return name, ptr

    elif itype == 'two_op':
        return dis_two_op(data, ptr, arg, name)

    elif itype == 'shift_const':
        return dis_shift_const(data, ptr, arg, name)

    elif itype == 'compare':
        return dis_compare(data, ptr, arg)

    elif itype == 'test':
        return dis_test(data, ptr, arg)

    elif itype == 'mask':
        return dis_mask(data, ptr, arg)

    elif itype == 'clear':
        return dis_clear(data, ptr, arg)

    elif itype == 'jump':
        target = u16(data, ptr); ptr += 2
        return f'{name} 0x{base + target:04X}', ptr

    elif itype == 'delay':
        count = u8(data, ptr); ptr += 1
        unit = 'ms' if name == 'DELAY_MS' else 'us'
        return f'DELAY {count}{unit}', ptr

    elif itype == 'calltable':
        idx = u8(data, ptr); ptr += 1
        tname = CMD_TABLE_NAMES.get(idx, f'table_{idx}')
        return f'CALLTABLE {idx} ({tname})', ptr

    elif itype == 'setdatablock':
        idx = u8(data, ptr); ptr += 1
        if idx == 0:
            return 'SETDATABLOCK 0 (reset)', ptr
        elif idx == 255:
            return 'SETDATABLOCK 255 (this_table)', ptr
        else:
            tname = DATA_TABLE_NAMES.get(idx, f'data_{idx}')
            return f'SETDATABLOCK {idx} ({tname})', ptr

    elif itype == 'setregblock':
        val = u16(data, ptr); ptr += 2
        return f'SETREGBLOCK 0x{val:04X}', ptr

    elif itype == 'setfbbase':
        return dis_setfbbase(data, ptr)

    elif itype == 'setport_ati':
        port = u16(data, ptr); ptr += 2
        return f'SETPORT ATI 0x{port:04X}', ptr

    elif itype == 'setport_pci':
        port = u8(data, ptr); ptr += 1
        return f'SETPORT PCI 0x{port:02X}', ptr

    elif itype == 'setport_sysio':
        port = u8(data, ptr); ptr += 1
        return f'SETPORT SYSIO 0x{port:02X}', ptr

    elif itype == 'switch':
        return dis_switch(data, ptr, base)

    elif itype == 'postcard':
        val = u8(data, ptr); ptr += 1
        return f'POSTCARD 0x{val:02X}', ptr

    elif itype == 'debug':
        val = u8(data, ptr); ptr += 1
        return f'DEBUG 0x{val:02X}', ptr

    elif itype == 'processds':
        length = u16(data, ptr); ptr += length + 2
        return f'PROCESSDS len={length}', ptr

    return f'??? op=0x{op:02X}', ptr


def disassemble_table(data, base, table_offset, table_name='', max_len=None):
    """Disassemble a command table."""
    if table_offset == 0:
        return

    # Command table header
    size = u16(data, table_offset + 0)  # ATOM_CT_SIZE_PTR
    ws = u8(data, table_offset + 4)     # ATOM_CT_WS_PTR
    ps_raw = u8(data, table_offset + 5) # ATOM_CT_PS_PTR
    ps = ps_raw & 0x7F
    code_start = table_offset + 6       # ATOM_CT_CODE_PTR

    print(f'\n{"=" * 70}')
    print(f'Command Table: {table_name} (index in ROM)')
    print(f'  Offset: 0x{table_offset:04X}')
    print(f'  Size: {size} bytes')
    print(f'  Work Space: {ws} dwords')
    print(f'  Param Space: {ps} dwords')
    print(f'  Code starts: 0x{code_start:04X}')
    print(f'{"=" * 70}')

    ptr = code_start
    end = table_offset + size if max_len is None else min(table_offset + size, code_start + max_len)

    while ptr < end:
        addr = ptr
        text, ptr = disassemble_instruction(data, ptr, table_offset)
        if text is None:
            break

        # Print with address
        raw_bytes = data[addr:ptr]
        hex_str = ' '.join(f'{b:02X}' for b in raw_bytes[:8])
        if len(raw_bytes) > 8:
            hex_str += ' ...'
        print(f'  0x{addr:04X}  {hex_str:<26s}  {text}')

        if text == 'EOT':
            break


def find_atom_rom_header(data):
    """Find the ATOM ROM header in the VBIOS data."""
    # Check for PCI ROM signature
    if u16(data, 0) != 0xAA55:
        print("Error: Not a valid PCI ROM (missing 0xAA55 signature)")
        return None

    # Try atomfirmware.h path first (ATOM v2.x)
    rom_header_off = u16(data, 0x48)  # ATOM_ROM_TABLE_PTR
    if rom_header_off == 0 or rom_header_off >= len(data):
        print(f"Error: Invalid ROM header offset: 0x{rom_header_off:04X}")
        return None

    # Check for ATOM magic
    magic = data[rom_header_off + 4:rom_header_off + 8]
    if magic == b'ATOM':
        return rom_header_off

    # Fallback: search for ATOM magic
    for i in range(0, min(len(data), 0x10000), 2):
        if data[i:i+4] == b'ATOM':
            return i - 4

    print("Error: Could not find ATOM ROM header")
    return None


def parse_vbios(data, args):
    """Parse and disassemble a VBIOS."""
    rom_header = find_atom_rom_header(data)
    if rom_header is None:
        return

    print(f'ATOM ROM Header at: 0x{rom_header:04X}')

    # Read master table pointers from the ROM header
    # atomfirmware.h: struct atom_rom_header_v2_2
    # offset 0x00: struct atom_common_table_header (4 bytes)
    # offset 0x04: ATOM magic (4 bytes)
    # offset 0x08: bios_segment_address (2 bytes)
    # offset 0x0A: protectedmodeoffset (2 bytes)
    # offset 0x0C: configfilename_offset (2 bytes) - ATOM_ROM_CFG_PTR
    # ...
    # offset 0x1E: masterhwfunction_offset -> command table
    # offset 0x20: masterdatatable_offset -> data table

    # For v2.x, the ROM header has pointers at specific offsets
    # But the standard way from atom.h is:
    # cmd_table = *(u16*)(bios + rom_header + 0x1E)  -- ATOM_ROM_CMD_PTR
    # data_table = *(u16*)(bios + rom_header + 0x20) -- ATOM_ROM_DATA_PTR

    cmd_table_off = u16(data, rom_header + 0x1E)
    data_table_off = u16(data, rom_header + 0x20)

    # Read BIOS info string
    msg_off = u16(data, rom_header + 0x10)
    if msg_off and msg_off < len(data):
        msg_end = data.index(0, msg_off) if 0 in data[msg_off:msg_off+64] else msg_off+64
        bios_msg = data[msg_off:msg_end].decode('ascii', errors='replace').strip()
        print(f'BIOS Message: {bios_msg}')

    bios_name = data[rom_header + 8 + 2:rom_header + 8 + 2 + 32]
    # Try to read the name from the header
    name_bytes = bytes(b for b in bios_name if 32 <= b < 127)
    if name_bytes:
        print(f'BIOS Name (header area): {name_bytes.decode("ascii", errors="replace")}')

    print(f'\nMaster Command Table at: 0x{cmd_table_off:04X}')
    print(f'Master Data Table at:    0x{data_table_off:04X}')

    # Parse master command table
    # The table is: struct atom_master_list_of_command_functions_v2_1
    # First 4 bytes: struct atom_common_table_header
    # Then pairs of uint16_t offsets
    cmd_header_size = u16(data, cmd_table_off)
    cmd_header_rev_major = u8(data, cmd_table_off + 2)
    cmd_header_rev_minor = u8(data, cmd_table_off + 3)
    print(f'  Command table header: size={cmd_header_size}, rev={cmd_header_rev_major}.{cmd_header_rev_minor}')

    num_cmd_entries = (cmd_header_size - 4) // 2
    print(f'  Number of command entries: {num_cmd_entries}')

    cmd_entries = []
    for i in range(num_cmd_entries):
        off = u16(data, cmd_table_off + 4 + i * 2)
        if off:
            name = CMD_TABLE_NAMES.get(i, f'cmd_function{i}')
            cmd_entries.append((i, off, name))
            print(f'    [{i:2d}] 0x{off:04X}  {name}')
        elif args.verbose:
            print(f'    [{i:2d}] (empty)')

    # Parse master data table
    data_header_size = u16(data, data_table_off)
    data_header_rev_major = u8(data, data_table_off + 2)
    data_header_rev_minor = u8(data, data_table_off + 3)
    print(f'\n  Data table header: size={data_header_size}, rev={data_header_rev_major}.{data_header_rev_minor}')

    num_data_entries = (data_header_size - 4) // 2
    print(f'  Number of data entries: {num_data_entries}')

    if args.data:
        for i in range(num_data_entries):
            off = u16(data, data_table_off + 4 + i * 2)
            if off:
                name = DATA_TABLE_NAMES.get(i, f'data_{i}')
                dt_size = u16(data, off)
                dt_rev_major = u8(data, off + 2)
                dt_rev_minor = u8(data, off + 3)
                print(f'    [{i:2d}] 0x{off:04X}  {name}  (size={dt_size}, rev={dt_rev_major}.{dt_rev_minor})')

                # Hexdump first 64 bytes of data table content
                content_start = off + 4
                content_end = min(off + dt_size, off + 68)
                if content_end > content_start:
                    hex_lines = []
                    for row in range(content_start, content_end, 16):
                        row_data = data[row:min(row+16, content_end)]
                        hex_part = ' '.join(f'{b:02X}' for b in row_data)
                        ascii_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in row_data)
                        hex_lines.append(f'           0x{row:04X}: {hex_part:<48s} {ascii_part}')
                    print('\n'.join(hex_lines))
            elif args.verbose:
                print(f'    [{i:2d}] (empty)')

    # Disassemble command tables
    if args.table is not None:
        # Disassemble specific table
        for idx, off, name in cmd_entries:
            if idx == args.table:
                disassemble_table(data, 0, off, name)
                break
        else:
            print(f'\nError: Command table {args.table} not found or empty')
    elif args.all:
        # Disassemble all command tables
        for idx, off, name in cmd_entries:
            disassemble_table(data, 0, off, name)
    else:
        # Default: disassemble asic_init (table 0) if present
        for idx, off, name in cmd_entries:
            if idx == 0:
                disassemble_table(data, 0, off, name)
                break


def main():
    parser = argparse.ArgumentParser(description='ATOM BIOS bytecode disassembler')
    parser.add_argument('romfile', help='VBIOS ROM file')
    parser.add_argument('--table', '-t', type=int, help='Disassemble specific command table index')
    parser.add_argument('--all', '-a', action='store_true', help='Disassemble all command tables')
    parser.add_argument('--data', '-d', action='store_true', help='Show data tables with hexdump')
    parser.add_argument('--verbose', '-v', action='store_true', help='Show empty table entries')
    args = parser.parse_args()

    with open(args.romfile, 'rb') as f:
        data = f.read()

    # If this is a full IFWI image, try to find the ATOM BIOS within it
    if len(data) > 0x100000:
        # Search for 0xAA55 + ATOM magic
        for off in range(0, len(data) - 0x100, 0x1000):
            if u16(data, off) == 0xAA55:
                rom_ptr = u16(data, off + 0x48)
                if rom_ptr and off + rom_ptr + 8 < len(data):
                    if data[off + rom_ptr + 4:off + rom_ptr + 8] == b'ATOM':
                        print(f'Found ATOM BIOS at offset 0x{off:06X} in IFWI image')
                        data = data[off:]
                        break

    parse_vbios(data, args)


if __name__ == '__main__':
    main()
