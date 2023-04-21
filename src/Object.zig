//! Represents an input relocatable object file.

name: []const u8,
data: []align(1) const u8,

pub fn parse(allocator: Allocator, path: []const u8) !Object {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const name = try allocator.dupe(u8, path);
    errdefer allocator.free(name);

    const file_stat = try file.stat();
    const file_size = std.math.cast(usize, file_stat.size) orelse return error.Overflow;
    const data = try file.readToEndAlloc(allocator, file_size);
    errdefer allocator.free(data);

    return .{
        .name = name,
        .data = data,
    };
}

pub fn deinit(obj: *Object, allocator: Allocator) void {
    allocator.free(obj.name);
    allocator.free(obj.data);
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const Object = @This();
