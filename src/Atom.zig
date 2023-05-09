//! Represents an input section found in an input object file.

/// Address allocated for this Atom.
value: u64 = 0,

/// Name of this Atom.
name: u32 = 0,

/// Index into linker's objects table.
object_id: u32 = 0,

/// Size of this atom
size: u32 = 0,

/// Alignment of this atom as a power of two.
alignment: u8 = 0,

/// Index of the input section.
shndx: u16 = 0,

/// Index of the output section.
out_shndx: u16 = 0,

/// Index of the input section containing this atom's relocs.
relocs_shndx: u16 = 0,

/// Index of this atom in the linker's atoms table.
atom_index: Index = 0,

/// Points to the previous and next neighbours
next: ?Index = null,
prev: ?Index = null,

pub const Index = u32;

pub fn getName(self: Atom, elf_file: *Elf) [:0]const u8 {
    return elf_file.string_intern.getAssumeExists(self.name);
}

pub fn getCode(self: Atom, elf_file: *Elf) []const u8 {
    const object = self.getObject(elf_file);
    return object.getShdrContents(self.shndx);
}

pub inline fn getObject(self: Atom, elf_file: *Elf) *Object {
    return &elf_file.objects.items[self.object_id];
}

pub fn getInputShdr(self: Atom, elf_file: *Elf) elf.Elf64_Shdr {
    const object = self.getObject(elf_file);
    return object.getShdrs()[self.shndx];
}

pub fn getRelocs(self: Atom, elf_file: *Elf) []align(1) const elf.Elf64_Rela {
    if (self.relocs_shndx == @bitCast(u16, @as(i16, -1))) return &[0]elf.Elf64_Rela{};
    const object = self.getObject(elf_file);
    const bytes = object.getShdrContents(self.relocs_shndx);
    const nrelocs = @divExact(bytes.len, @sizeOf(elf.Elf64_Rela));
    return @ptrCast([*]align(1) const elf.Elf64_Rela, bytes)[0..nrelocs];
}

pub fn initOutputSection(self: *Atom, elf_file: *Elf) !void {
    const shdr = self.getInputShdr(elf_file);
    const name = self.getName(elf_file);
    // TODO: To conserve the space, and minimise jump distance, we want to map input sections
    // to common output sections. For example, when compiled with `-ffunction-sections` flag,
    // the `.text` section may be split into more atomic sections such as `.text.main`, etc.
    // In other words, there may be as many as one section per symbol. We need to work out what
    // each input section should map into. For example, both `.text` and `.text.main` would map
    // into `.text`, while `.rodata.1` into `.rodata`.
    const opts: Elf.AddSectionOpts = switch (shdr.sh_type) {
        elf.SHT_NULL => unreachable,
        elf.SHT_PROGBITS => blk: {
            if (shdr.sh_flags & elf.SHF_ALLOC == 0) break :blk .{
                .name = name,
                .type = elf.SHT_PROGBITS,
                .flags = shdr.sh_flags,
            };
            break :blk .{
                .name = ".text",
                .type = elf.SHT_PROGBITS,
                .flags = elf.SHF_ALLOC | elf.SHF_EXECINSTR,
            };
        },
        else => .{
            .name = name,
            .type = shdr.sh_type,
            .flags = shdr.sh_flags,
        },
    };
    const out_shndx = elf_file.getSectionByName(opts.name) orelse try elf_file.addSection(opts);
    if (mem.eql(u8, ".text", opts.name)) {
        elf_file.text_sect_index = out_shndx;
    }
    self.out_shndx = out_shndx;
}

pub fn resolveRelocs(self: Atom, elf_file: *Elf, writer: anytype) !void {
    const gpa = elf_file.allocator;
    const code = try gpa.dupe(u8, self.getCode(elf_file));
    defer gpa.free(code);
    const relocs = self.getRelocs(elf_file);

    for (relocs) |rel| {
        // TODO: for each relocation type, we need work out what the source and target addresses are,
        // and write the result in the correct place in the Atom's code/data.
        const r_type = rel.r_type();
        switch (r_type) {
            else => {
                elf_file.warn("unhandled relocation type: {}", .{fmtRelocType(r_type)});
            },
        }
    }

    try writer.writeAll(code);
}

fn fmtRelocType(r_type: u32) std.fmt.Formatter(formatRelocType) {
    return .{ .data = r_type };
}

fn formatRelocType(
    r_type: u32,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    const str = switch (r_type) {
        elf.R_X86_64_NONE => "R_X86_64_NONE",
        elf.R_X86_64_64 => "R_X86_64_64",
        elf.R_X86_64_PC32 => "R_X86_64_PC32",
        elf.R_X86_64_GOT32 => "R_X86_64_GOT32",
        elf.R_X86_64_PLT32 => "R_X86_64_PLT32",
        elf.R_X86_64_COPY => "R_X86_64_COPY",
        elf.R_X86_64_GLOB_DAT => "R_X86_64_GLOB_DAT",
        elf.R_X86_64_JUMP_SLOT => "R_X86_64_JUMP_SLOT",
        elf.R_X86_64_RELATIVE => "R_X86_64_RELATIVE",
        elf.R_X86_64_GOTPCREL => "R_X86_64_GOTPCREL",
        elf.R_X86_64_32 => "R_X86_64_32",
        elf.R_X86_64_32S => "R_X86_64_32S",
        elf.R_X86_64_16 => "R_X86_64_16",
        elf.R_X86_64_PC16 => "R_X86_64_PC16",
        elf.R_X86_64_8 => "R_X86_64_8",
        elf.R_X86_64_PC8 => "R_X86_64_PC8",
        elf.R_X86_64_DTPMOD64 => "R_X86_64_DTPMOD64",
        elf.R_X86_64_DTPOFF64 => "R_X86_64_DTPOFF64",
        elf.R_X86_64_TPOFF64 => "R_X86_64_TPOFF64",
        elf.R_X86_64_TLSGD => "R_X86_64_TLSGD",
        elf.R_X86_64_TLSLD => "R_X86_64_TLSLD",
        elf.R_X86_64_DTPOFF32 => "R_X86_64_DTPOFF32",
        elf.R_X86_64_GOTTPOFF => "R_X86_64_GOTTPOFF",
        elf.R_X86_64_TPOFF32 => "R_X86_64_TPOFF32",
        elf.R_X86_64_PC64 => "R_X86_64_PC64",
        elf.R_X86_64_GOTOFF64 => "R_X86_64_GOTOFF64",
        elf.R_X86_64_GOTPC32 => "R_X86_64_GOTPC32",
        elf.R_X86_64_GOT64 => "R_X86_64_GOT64",
        elf.R_X86_64_GOTPCREL64 => "R_X86_64_GOTPCREL64",
        elf.R_X86_64_GOTPC64 => "R_X86_64_GOTPC64",
        elf.R_X86_64_GOTPLT64 => "R_X86_64_GOTPLT64",
        elf.R_X86_64_PLTOFF64 => "R_X86_64_PLTOFF64",
        elf.R_X86_64_SIZE32 => "R_X86_64_SIZE32",
        elf.R_X86_64_SIZE64 => "R_X86_64_SIZE64",
        elf.R_X86_64_GOTPC32_TLSDESC => "R_X86_64_GOTPC32_TLSDESC",
        elf.R_X86_64_TLSDESC_CALL => "R_X86_64_TLSDESC_CALL",
        elf.R_X86_64_TLSDESC => "R_X86_64_TLSDESC",
        elf.R_X86_64_IRELATIVE => "R_X86_64_IRELATIVE",
        elf.R_X86_64_RELATIVE64 => "R_X86_64_RELATIVE64",
        elf.R_X86_64_GOTPCRELX => "R_X86_64_GOTPCRELX",
        elf.R_X86_64_REX_GOTPCRELX => "R_X86_64_REX_GOTPCRELX",
        elf.R_X86_64_NUM => "R_X86_64_NUM",
        else => "R_X86_64_UNKNOWN",
    };
    try writer.print("{s}", .{str});
}

pub fn format(
    atom: Atom,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = atom;
    _ = unused_fmt_string;
    _ = options;
    _ = writer;
    @compileError("do not format symbols directly");
}

pub fn fmt(atom: Atom, elf_file: *Elf) std.fmt.Formatter(format2) {
    return .{ .data = .{
        .atom = atom,
        .elf_file = elf_file,
    } };
}

const FormatContext = struct {
    atom: Atom,
    elf_file: *Elf,
};

fn format2(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    _ = unused_fmt_string;
    const atom = ctx.atom;
    try writer.print("atom({d}) : {s} : @{x} : sect({d}) : align({x}) : size({x})", .{
        atom.atom_index, atom.getName(ctx.elf_file), atom.value,
        atom.out_shndx,  atom.alignment,             atom.size,
    });
}

const Atom = @This();

const std = @import("std");
const assert = std.debug.assert;
const dis_x86_64 = @import("dis_x86_64");
const elf = std.elf;
const log = std.log.scoped(.elf);
const relocs_log = std.log.scoped(.relocs);
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;
const Disassembler = dis_x86_64.Disassembler;
const Elf = @import("Elf.zig");
const Instruction = dis_x86_64.Instruction;
const Immediate = dis_x86_64.Immediate;
const Object = @import("Object.zig");
