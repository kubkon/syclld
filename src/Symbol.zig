//! Represents resolved symbol.

address: u64,

name: u32,

section: struct {
    input: u32,
    output: u32,
},

/// Points at an object file which defines this symbol.
file: u32,

/// If true, this symbol is weak.
/// Otherwise, it is strong.
is_weak: bool = false,

pub fn getAddress(symbol: Symbol, ctx: Elf) ?u64 {
    switch (symbol.section.input) {
        elf.SHN_UNDEF => return null,
        elf.SHN_ABS => return symbol.address,
        elf.SHN_COMMON => @panic("TODO"),
        else => {
            const file = ctx.getObject(symbol.file);
            const input_section = file.getInputSection(symbol.input_section);
            return input_section.getAddress(ctx) + symbol.address;
        },
    }
}

pub fn getName(symbol: Symbol, ctx: Elf) []const u8 {
    switch (symbol.section.input) {
        elf.SHN_UNDEF => @panic("TODO"),
        else => {
            const obj = ctx.getObject(symbol.file);
            const strtab = obj.getStrtab();
            return Object.getString(symbol.name, strtab);
        },
    }
}

const std = @import("std");
const elf = std.elf;

const Elf = @import("Elf.zig");
const InputSection = @import("InputSection.zig");
const Object = @import("Object.zig");
const Symbol = @This();
