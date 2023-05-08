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
    const flags = shdr.sh_flags;
    const @"type" = shdr.sh_type;
    const is_alloc = flags & elf.SHF_ALLOC != 0;
    const is_write = flags & elf.SHF_WRITE != 0;
    const is_exec = flags & elf.SHF_EXECINSTR != 0;
    const opts: Elf.AddSectionOpts = switch (@"type") {
        elf.SHT_NULL => unreachable,
        elf.SHT_NOBITS => .{
            .flags = elf.SHF_ALLOC | elf.SHF_WRITE,
            .name = ".bss",
            .type = @"type",
        },
        elf.SHT_PROGBITS => blk: {
            if (!is_alloc) break :blk .{
                .name = name,
                .type = @"type",
                .flags = flags,
            };

            if (is_exec) {
                const out_name = if (mem.eql(u8, name, ".init"))
                    ".init"
                else if (mem.eql(u8, name, ".fini"))
                    ".fini"
                else
                    ".text";
                var out_flags: u32 = elf.SHF_ALLOC | elf.SHF_EXECINSTR;
                if (is_write) out_flags |= elf.SHF_WRITE;
                break :blk .{
                    .flags = out_flags,
                    .name = out_name,
                    .type = @"type",
                };
            }

            if (is_write) break :blk .{
                .flags = elf.SHF_ALLOC | elf.SHF_WRITE,
                .name = if (mem.startsWith(u8, name, ".data.rel.ro")) ".data.rel.ro" else ".data",
                .type = @"type",
            };

            break :blk .{
                .flags = elf.SHF_ALLOC,
                .name = ".rodata",
                .type = @"type",
            };
        },
        elf.SHT_INIT_ARRAY, elf.SHT_FINI_ARRAY => .{
            .flags = elf.SHF_ALLOC | elf.SHF_WRITE,
            .name = if (shdr.sh_type == elf.SHT_INIT_ARRAY) ".init_array" else ".fini_array",
            .type = @"type",
        },
        else => .{
            .name = name,
            .type = @"type",
            .flags = flags,
            .info = shdr.sh_info,
            .entsize = shdr.sh_entsize,
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
    const object = self.getObject(elf_file);

    for (relocs) |rel| {
        const target = object.getSymbol(rel.r_sym(), elf_file);
        const target_name = target.getName(elf_file);

        const r_type = rel.r_type();
        switch (r_type) {
            elf.R_X86_64_NONE => {},
            elf.R_X86_64_64 => {
                const target_addr = @intCast(i64, target.value) + rel.r_addend;
                relocs_log.debug("{}: {x}: [() => 0x{x}] ({s})", .{
                    fmtRelocType(r_type),
                    rel.r_offset,
                    target_addr,
                    target_name,
                });
                mem.writeIntLittle(i64, code[rel.r_offset..][0..8], target_addr);
            },
            elf.R_X86_64_32 => {
                const target_addr = @bitCast(u64, @intCast(i64, target.value) + rel.r_addend);
                const scaled = @truncate(u32, target_addr);
                relocs_log.debug("{}: {x}: [() => 0x{x}] ({s})", .{
                    fmtRelocType(r_type),
                    rel.r_offset,
                    scaled,
                    target_name,
                });
                mem.writeIntLittle(u32, code[rel.r_offset..][0..4], scaled);
            },
            else => {
                elf_file.fatal("unhandled relocation type: {}", .{fmtRelocType(r_type)});
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
