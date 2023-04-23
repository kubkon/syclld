//! Represents an input section found in an input object file.

/// Offset of this input section wrt output section
offset: u32,

/// Output section.
section: u32,

/// Size of this input section.
size: u64,

/// Alignment of this input section.
alignment: u32,

name: u32,

pub fn getName(sect: InputSection, obj: Object) []const u8 {
    const strtab = obj.getShStrtab();
    return Object.getString(sect.name, strtab);
}

const std = @import("std");

const Elf = @import("Elf.zig");
const InputSection = @This();
const Object = @import("Object.zig");
