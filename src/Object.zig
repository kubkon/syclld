//! Represents an input relocatable object file.
//! Input relocatable object files are characterised by ET_REL e_type
//! in the ELF header.

/// Name of this file.
/// Usually the same as the fully resolved path to the file unless the file
/// was extracted from an archive; then the name corresponds to the value
/// exctracted from there.
name: []const u8,

/// The entire contents of the file allocated and pre-read in one go.
/// This will make it easier for us to work with different sections within
/// the file as we will only need to cast pointers when trying to get section's
/// contents, etc.
data: []const u8,

/// Sequential id of this object.
/// Populated by linker's main driver.
object_id: u32,

/// Parsed file's header.
header: ?elf.Elf64_Ehdr = null,

/// Input symbol table as encoded within the file.
/// This represents what we see when running `readelf -s` or `nm -a`
/// against the input file.
symtab: []align(1) const elf.Elf64_Sym = &[0]elf.Elf64_Sym{},

/// Input string table.
strtab: []const u8 = &[0]u8{},

/// Input section headers string table.
shstrtab: []const u8 = &[0]u8{},

/// Helper variable denoting the start of the global symbols.
first_global: ?u32 = null,

/// Parsed table of local symbols.
/// These symbols by definition will not take part in global symbol resolution.
locals: std.ArrayListUnmanaged(Symbol) = .{},

/// Parsed table of indexes into the global symbol table.
/// Global symbol table stores unique symbols at the linker level, and
/// therefore we only store indexes into the global symbol table here.
globals: std.ArrayListUnmanaged(u32) = .{},

/// Parsed input sections as indexes into the global list of all Atoms
/// stored at the linker level.
atoms: std.ArrayListUnmanaged(Atom.Index) = .{},

pub fn isValidHeader(header: *const elf.Elf64_Ehdr) bool {
    if (!mem.eql(u8, header.e_ident[0..4], "\x7fELF")) {
        log.debug("invalid ELF magic '{s}', expected \x7fELF", .{header.e_ident[0..4]});
        return false;
    }
    if (header.e_ident[elf.EI_VERSION] != 1) {
        log.debug("unknown ELF version '{d}', expected 1", .{header.e_ident[elf.EI_VERSION]});
        return false;
    }
    if (header.e_type != elf.ET.REL) {
        log.debug("invalid file type '{s}', expected ET.REL", .{@tagName(header.e_type)});
        return false;
    }
    if (header.e_version != 1) {
        log.debug("invalid ELF version '{d}', expected 1", .{header.e_version});
        return false;
    }
    return true;
}

pub fn deinit(self: *Object, allocator: Allocator) void {
    self.locals.deinit(allocator);
    self.globals.deinit(allocator);
    self.atoms.deinit(allocator);
    allocator.free(self.name);
    allocator.free(self.data);
}

pub fn parse(self: *Object, elf_file: *Elf) !void {
    var stream = std.io.fixedBufferStream(self.data);
    const reader = stream.reader();

    self.header = try reader.readStruct(elf.Elf64_Ehdr);

    if (self.header.?.e_shnum == 0) return;

    const shdrs = self.getShdrs();
    self.shstrtab = self.getShdrContents(self.header.?.e_shstrndx);

    const symtab_index = for (self.getShdrs(), 0..) |shdr, i| switch (shdr.sh_type) {
        elf.SHT_SYMTAB => break @intCast(u16, i),
        else => {},
    } else null;

    if (symtab_index) |index| {
        const shdr = shdrs[index];
        self.first_global = shdr.sh_info;

        const symtab = self.getShdrContents(index);
        const nsyms = @divExact(symtab.len, @sizeOf(elf.Elf64_Sym));
        self.symtab = @ptrCast([*]align(1) const elf.Elf64_Sym, symtab.ptr)[0..nsyms];
        self.strtab = self.getShdrContents(@intCast(u16, shdr.sh_link));
    }

    try self.initAtoms(elf_file);
    try self.initSymtab(elf_file);
}

fn initAtoms(self: *Object, elf_file: *Elf) !void {
    const shdrs = self.getShdrs();
    try self.atoms.resize(elf_file.allocator, shdrs.len);
    @memset(self.atoms.items, 0); // Set all indexes to null value represented by index 0.

    // TODO: we need to do two things here:
    // 1) Unpack each input SHDR into an `Atom`.
    //    In order to create an `Atom`, you can use `Elf.addAtom()` helper.
    //    If you are in possession of an `atom_index`, you can turn it into a pointer
    //    via `Elf.getAtom()`.
    //    You can use `Object.skipShdr` to help you decide if SHDR should be allocated an `Atom`
    //    or not.
    // 2) Tie each section containing relocation records SHT_RELA to an existing `Atom`.
    //    While this will not be needed just yet, once we get to committing atoms to final
    //    output file, we will need to get each `Atom`'s relocations and resolve them
    //    (do the so-called fixups).
}

fn skipShdr(self: Object, index: u32) bool {
    const shdr = self.getShdrs()[index];
    const ignore = switch (shdr.sh_type) {
        elf.SHT_NULL,
        elf.SHT_REL,
        elf.SHT_RELA,
        elf.SHT_SYMTAB,
        elf.SHT_STRTAB,
        elf.SHT_GROUP,
        elf.SHT_SYMTAB_SHNDX,
        elf.SHT_X86_64_UNWIND,
        elf.SHT_LLVM_ADDRSIG,
        => true,
        else => blk: {
            if (shdr.sh_flags & elf.SHF_EXCLUDE != 0 and
                shdr.sh_flags & elf.SHF_ALLOC == 0) break :blk true;
            const name = self.getShString(shdr.sh_name);
            if (mem.startsWith(u8, name, ".note")) break :blk true;
            if (mem.startsWith(u8, name, ".comment")) break :blk true;
            break :blk false;
        },
    };
    return ignore;
}

fn initSymtab(self: *Object, elf_file: *Elf) !void {
    const gpa = elf_file.allocator;
    const first_global = self.first_global orelse self.symtab.len;
    try self.locals.ensureTotalCapacityPrecise(gpa, first_global);
    try self.globals.ensureTotalCapacityPrecise(gpa, self.symtab.len - first_global);

    // TODO: we need to do two things here:
    // 1) Unpack each local symbol tying it to a parsed Atom in `Object.initAtoms`. To make tracking symbol
    //    names consistent, we could use `Elf.string_intern` buffer. This will be very useful for
    //    symbols that have type `STT_SECTION`.
    // 2) Unpack each global symbol. We will not resolve any global just yet, however, we will initialize it
    //    to the first occurrence in any of the input object files. Also, since globals are by definition
    //    unique to the entire linking process, we store them in a list in the global linker scope `Elf.globals`.
    //    You can use `Object.setGlobal()` helper to correctly initialize fields of the struct.
    //    In order to create a new global symbol at the linker scope, you can use `Elf.getOrCreateGlobal()`.
}

fn setGlobal(self: Object, sym_idx: u32, global: *Symbol) void {
    const sym = self.symtab[sym_idx];
    const name = global.name;
    const atom = if (sym.st_shndx == elf.SHN_UNDEF or sym.st_shndx == elf.SHN_ABS)
        0
    else
        self.atoms.items[sym.st_shndx];
    global.* = .{
        .value = sym.st_value,
        .name = name,
        .atom = atom,
        .sym_idx = sym_idx,
        .file = self.object_id,
    };
}

pub fn resolveSymbols(self: Object, elf_file: *Elf) !void {
    const first_global = self.first_global orelse return;
    _ = first_global;
    _ = elf_file;
    // TODO: for each global symbol in the input symbol table (`Object.symtab`)
    // we need to check if:
    // 1) the symbol is undefined, just skip it as this object file doesn't define it
    // 2) otherwise, decide if this symbol ranks higher than the already tracked global symbol
    //    2.1) if it does, overwrite the global with this symbol
    //    2.2) otherwise, do nothing
}

pub fn checkDuplicates(self: Object, elf_file: *Elf) void {
    const first_global = self.first_global orelse return;
    for (self.globals.items, 0..) |index, i| {
        const sym_idx = @intCast(u32, first_global + i);
        const this_sym = self.symtab[sym_idx];
        const global = elf_file.getGlobal(index);
        const global_file = global.getObject(elf_file) orelse continue;

        if (self.object_id == global_file.object_id or
            this_sym.st_shndx == elf.SHN_UNDEF or
            this_sym.st_bind() == elf.STB_WEAK) continue;
        elf_file.fatal("multiple definition: {s}: {s}: {s}", .{
            self.name,
            global_file.name,
            global.getName(elf_file),
        });
    }
}

pub fn checkUndefined(self: Object, elf_file: *Elf) void {
    for (self.globals.items) |index| {
        const global = elf_file.getGlobal(index);
        if (global.isUndef(elf_file) and !global.isWeak(elf_file)) {
            elf_file.fatal("undefined reference: {s}: {s}", .{ self.name, global.getName(elf_file) });
        }
    }
}

/// Encodes symbol precedence so that the following ordering applies:
/// * strong defined
/// * weak defined
/// * undefined
pub inline fn getSymbolRank(sym: elf.Elf64_Sym) u4 {
    if (sym.st_shndx == elf.SHN_UNDEF) return 0xf;
    return switch (sym.st_bind()) {
        elf.STB_GLOBAL => 0,
        elf.STB_WEAK => 1,
        else => 0xf,
    };
}

pub inline fn getSourceSymbol(self: Object, index: u32) elf.Elf64_Sym {
    assert(index < self.symtab.len);
    return self.symtab[index];
}

pub fn getGlobalIndex(self: Object, index: u32) ?u32 {
    assert(index < self.symtab.len);
    const nlocals = self.first_global orelse self.locals.items.len;
    if (index < nlocals) return null;
    return self.globals.items[index - nlocals];
}

pub fn getSymbol(self: *Object, index: u32, elf_file: *Elf) *Symbol {
    if (self.getGlobalIndex(index)) |global_index| {
        return elf_file.getGlobal(global_index);
    } else {
        return &self.locals.items[index];
    }
}

pub inline fn getShdrs(self: Object) []align(1) const elf.Elf64_Shdr {
    const header = self.header orelse return &[0]elf.Elf64_Shdr{};
    return @ptrCast([*]align(1) const elf.Elf64_Shdr, self.data.ptr + header.e_shoff)[0..header.e_shnum];
}

pub inline fn getShdrContents(self: Object, index: u16) []const u8 {
    const shdr = self.getShdrs()[index];
    return self.data[shdr.sh_offset..][0..shdr.sh_size];
}

inline fn getString(self: Object, off: u32) [:0]const u8 {
    assert(off < self.strtab.len);
    return mem.sliceTo(@ptrCast([*:0]const u8, self.strtab.ptr + off), 0);
}

inline fn getShString(self: Object, off: u32) [:0]const u8 {
    assert(off < self.shstrtab.len);
    return mem.sliceTo(@ptrCast([*:0]const u8, self.shstrtab.ptr + off), 0);
}

pub fn format(
    self: Object,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = self;
    _ = unused_fmt_string;
    _ = options;
    _ = writer;
    @compileError("do not format objects directly");
}

pub fn fmtSymtab(self: *const Object, elf_file: *Elf) std.fmt.Formatter(formatSymtab) {
    return .{ .data = .{
        .object = self,
        .elf_file = elf_file,
    } };
}

const FormatContext = struct {
    object: *const Object,
    elf_file: *Elf,
};

fn formatSymtab(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const object = ctx.object;
    try writer.writeAll("  locals\n");
    for (object.locals.items) |sym| {
        try writer.print("    {}\n", .{sym.fmt(ctx.elf_file)});
    }
    try writer.writeAll("  globals\n");
    for (object.globals.items) |index| {
        const global = ctx.elf_file.getGlobal(index);
        try writer.print("    {}\n", .{global.fmt(ctx.elf_file)});
    }
}

pub fn fmtAtoms(self: *const Object, elf_file: *Elf) std.fmt.Formatter(formatAtoms) {
    return .{ .data = .{
        .object = self,
        .elf_file = elf_file,
    } };
}

fn formatAtoms(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    const object = ctx.object;
    try writer.writeAll("  atoms\n");
    for (object.atoms.items) |atom_index| {
        const atom = ctx.elf_file.getAtom(atom_index) orelse continue;
        try writer.print("    {}\n", .{atom.fmt(ctx.elf_file)});
    }
}

const Object = @This();

const std = @import("std");
const assert = std.debug.assert;
const elf = std.elf;
const fs = std.fs;
const log = std.log.scoped(.elf);
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const Elf = @import("Elf.zig");
const Symbol = @import("Symbol.zig");
