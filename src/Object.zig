//! Represents an input relocatable object file.

name: []const u8,
data: []align(1) const u8,

header: std.elf.Elf64_Ehdr = undefined,

symtab_shdr_index: ?u16 = null,
symtab: std.ArrayListUnmanaged(std.elf.Elf64_Sym) = .{},

pub fn parse(allocator: Allocator, path: []const u8) !Object {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const name = try allocator.dupe(u8, path);
    errdefer allocator.free(name);

    const file_stat = try file.stat();
    const file_size = std.math.cast(usize, file_stat.size) orelse return error.Overflow;
    const data = try file.readToEndAlloc(allocator, file_size);
    errdefer allocator.free(data);

    var obj = Object{
        .name = name,
        .data = data,
    };

    var stream = std.io.fixedBufferStream(obj.data);
    const reader = stream.reader();

    obj.header = try reader.readStruct(std.elf.Elf64_Ehdr);

    if (!std.mem.eql(u8, obj.header.e_ident[0..4], "\x7fELF")) {
        log.debug("Invalid ELF magic {s}, expected \x7fELF", .{obj.header.e_ident[0..4]});
        return error.NotObject;
    }
    if (obj.header.e_ident[std.elf.EI_VERSION] != 1) {
        return error.NotObject;
    }
    if (obj.header.e_ident[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) {
        return error.TODOBigEndianSupport;
    }
    if (obj.header.e_ident[std.elf.EI_CLASS] != std.elf.ELFCLASS64) {
        return error.TODOElf32bitSupport;
    }
    if (obj.header.e_type != std.elf.ET.REL) {
        return error.NotObject;
    }
    if (obj.header.e_version != 1) {
        return error.NotObject;
    }

    assert(obj.header.e_entry == 0);
    assert(obj.header.e_phoff == 0);
    assert(obj.header.e_phnum == 0);

    for (obj.getShdrs(), 0..) |shdr, i| switch (shdr.sh_type) {
        std.elf.SHT_SYMTAB => {
            obj.symtab_shdr_index = @intCast(u16, i);
            const nsyms = @divExact(shdr.sh_size, @sizeOf(std.elf.Elf64_Sym));
            try obj.symtab.appendUnalignedSlice(allocator, @ptrCast(
                [*]align(1) const std.elf.Elf64_Sym,
                &obj.data[shdr.sh_offset],
            )[0..nsyms]);
        },
        else => {},
    };

    return obj;
}

pub fn deinit(obj: *Object, allocator: Allocator) void {
    allocator.free(obj.name);
    allocator.free(obj.data);
}

pub fn getShdrs(obj: Object) []align(1) const std.elf.Elf64_Shdr {
    return @ptrCast([*]align(1) const std.elf.Elf64_Shdr, &obj.data[obj.header.e_shoff])[0..obj.header.e_shnum];
}

fn getSectionContents(obj: Object, index: u16) []align(1) const u8 {
    const shdr = obj.getShdrs()[index];
    return obj.data[shdr.sh_offset..][0..shdr.sh_size];
}

pub fn getInputSymtab(obj: Object) []align(1) const std.elf.Elf64_Sym {
    const index = obj.symtab_shdr_index orelse return &[0]std.elf.Elf64_Sym{};
    const shdr = obj.getShdrs()[index];
    const nsyms = @divExact(shdr.sh_size, @sizeOf(std.elf.Elf64_Sym));
    return @ptrCast([*]align(1) const std.elf.Elf64_Sym, &obj.data[shdr.sh_offset])[0..nsyms];
}

pub fn getInputStrtab(obj: Object) []const u8 {
    const index = obj.symtab_shdr_index orelse return &[0]u8{};
    const shdr = obj.getShdrs()[index];
    return obj.getShdrContents(@intCast(u16, shdr.sh_link));
}

pub fn getInputShstrtab(obj: Object) []const u8 {
    return obj.getShdrContents(obj.header.e_shstrndx);
}

pub fn getInputSymbol(obj: Object, index: u32) ?std.elf.Elf64_Sym {
    const symtab = obj.getInputSymtab();
    if (index >= symtab.len) return null;
    return symtab[index];
}

pub fn getInputSymbolName(obj: Object, index: u32) []const u8 {
    const sym = obj.getSourceSymtab()[index];
    if (sym.st_info & 0xf == std.elf.STT_SECTION) {
        const shdr = obj.getShdrs()[sym.st_shndx];
        return obj.getShString(shdr.sh_name);
    } else {
        return obj.getString(sym.st_name);
    }
}

pub fn getSymbolPtr(obj: *Object, index: u32) *std.elf.Elf64_Sym {
    return &obj.symtab.items[index];
}

pub fn getSymbol(obj: Object, index: u32) std.elf.Elf64_Sym {
    return obj.symtab.items[index];
}

pub fn getSymbolName(obj: Object, index: u32) []const u8 {
    const sym = obj.getSymbol(index);
    return obj.getString(sym.st_name);
}

pub fn getString(obj: Object, off: u32) []const u8 {
    const strtab = obj.getSourceStrtab();
    assert(off < strtab.len);
    return std.mem.sliceTo(@ptrCast([*:0]const u8, strtab.ptr + off), 0);
}

pub fn getShString(obj: Object, off: u32) []const u8 {
    const shstrtab = obj.getSourceShstrtab();
    assert(off < shstrtab.len);
    return std.mem.sliceTo(@ptrCast([*:0]const u8, shstrtab.ptr + off), 0);
}

const std = @import("std");
const assert = std.debug.assert;
const log = std.log;

const Allocator = std.mem.Allocator;
const Object = @This();
