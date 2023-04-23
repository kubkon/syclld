//! Represents an input relocatable object file.

name: []const u8,
data: []const u8,

header: ?elf.Elf64_Ehdr = null,
symtab_index: ?u32 = null,

input_sections: std.ArrayListUnmanaged(InputSection) = .{},

pub fn parse(obj: *Object, allocator: Allocator) !void {
    _ = allocator;
    var stream = std.io.fixedBufferStream(obj.data);
    const reader = stream.reader();

    const header = try reader.readStruct(elf.Elf64_Ehdr);

    if (!std.mem.eql(u8, header.e_ident[0..4], "\x7fELF")) {
        log.debug("Invalid ELF magic {s}, expected \x7fELF", .{header.e_ident[0..4]});
        return error.NotObject;
    }
    if (header.e_ident[elf.EI_VERSION] != 1) {
        return error.NotObject;
    }
    if (header.e_ident[elf.EI_DATA] != elf.ELFDATA2LSB) {
        return error.TODOBigEndianSupport;
    }
    if (header.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) {
        return error.TODOElf32bitSupport;
    }
    if (header.e_type != elf.ET.REL) {
        return error.NotObject;
    }
    if (header.e_version != 1) {
        return error.NotObject;
    }

    obj.header = header;

    // Get .symtab index
    for (obj.getShdrs(), 0..) |shdr, i| switch (shdr.sh_type) {
        elf.SHT_SYMTAB => obj.symtab_index = @intCast(u16, i),
        else => {},
    };

    // Let's parse into input sections
    const symtab = obj.getSourceSymtab();

    var nsects: usize = 0;
    for (symtab) |sym| switch (sym.st_type()) {
        elf.STT_SECTION => nsects += 1,
        else => {},
    };
    log.warn("nsects {d}", .{nsects});

    // for (symtab) |sym| {
    //     const sym_name = getString(sym.st_name, strtab);
    //     const sym_type = sym.st_info & 0xf;
    //     const sym_binding = sym.st_info >> 4;
    //     switch (sym.st_shndx) {
    //         std.elf.SHN_UNDEF => log.warn("{x} => {s}, UNDEF, {}", .{ sym.st_value, sym_name, sym }),
    //         std.elf.SHN_ABS => log.warn("{x} => {s}, ABS, {}", .{ sym.st_value, sym_name, sym }),
    //         std.elf.SHN_COMMON => log.warn("{x} => {s}, COMMON, {}", .{ sym.st_value, sym_name, sym }),
    //         else => log.warn("{x} => {s}, {}", .{ sym.st_value, sym_name, sym }),
    //     }
    // }
}

pub fn deinit(obj: *Object, allocator: Allocator) void {
    allocator.free(obj.name);
    allocator.free(obj.data);
    obj.input_sections.deinit(allocator);
}

pub fn getShdrs(obj: Object) []align(1) const elf.Elf64_Shdr {
    const header = obj.header orelse return &[0]elf.Elf64_Shdr{};
    return @ptrCast([*]align(1) const elf.Elf64_Shdr, &obj.data[header.e_shoff])[0..header.e_shnum];
}

fn getSectionContents(obj: Object, index: u32) []align(1) const u8 {
    const shdr = obj.getShdrs()[index];
    return obj.data[shdr.sh_offset..][0..shdr.sh_size];
}

pub fn getSourceSymtab(obj: Object) []align(1) const elf.Elf64_Sym {
    const index = obj.symtab_index orelse return &[0]elf.Elf64_Sym{};
    const payload = obj.getSectionContents(index);
    const nsyms = @divExact(payload.len, @sizeOf(elf.Elf64_Sym));
    return @ptrCast([*]align(1) const elf.Elf64_Sym, payload.ptr)[0..nsyms];
}

pub fn getStrtab(obj: Object) []const u8 {
    const index = obj.symtab_index orelse return &[0]u8{};
    const shdr = obj.getShdrs()[index];
    return obj.getSectionContents(shdr.sh_link);
}

pub fn getShStrtab(obj: Object) []const u8 {
    const header = obj.header orelse return &[0]u8{};
    return obj.getSectionContents(header.e_shstrndx);
}

pub fn getString(obj: Object, off: u32) []const u8 {
    const strtab = obj.getStrtab();
    assert(off < strtab.len);
    return std.mem.sliceTo(@ptrCast([*:0]const u8, strtab.ptr + off), 0);
}

pub fn getShString(obj: Object, off: u32) []const u8 {
    const strtab = obj.getShStrtab();
    assert(off < strtab.len);
    return std.mem.sliceTo(@ptrCast([*:0]const u8, strtab.ptr + off), 0);
}

const std = @import("std");
const assert = std.debug.assert;
const elf = std.elf;
const log = std.log;

const Allocator = std.mem.Allocator;
const InputSection = @import("InputSection.zig");
const Object = @This();
