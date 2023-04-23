//! Elf is the driver - it coordinates which stage in the link process should be next executed
//! and produces/flushes the final output executable file.

allocator: Allocator,
options: Options,
file: std.fs.File,

objects: std.ArrayListUnmanaged(Object) = .{},

pub const Emit = struct {
    directory: std.fs.Dir,
    sub_path: []const u8,
};

const Options = struct {
    positionals: []const []const u8,
    libs: []const []const u8,
    lib_dirs: []const []const u8,
    emit: Emit,
};

pub fn openPath(allocator: Allocator, options: Options) !Elf {
    const file = try options.emit.directory.createFile(options.emit.sub_path, .{
        .truncate = true,
        .read = true,
        .mode = 0o777,
    });
    errdefer file.close();

    return Elf{
        .allocator = allocator,
        .options = options,
        .file = file,
    };
}

pub fn deinit(ld: *Elf) void {
    ld.file.close();

    for (ld.objects.items) |*object| {
        object.deinit(ld.allocator);
    }
    ld.objects.deinit(ld.allocator);
}

/// Performs the full link and flushes the output executable file.
pub fn flush(ld: *Elf) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(ld.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const stderr = std.io.getStdErr().writer();

    var lib_dirs = std.ArrayList([]const u8).init(arena);
    for (ld.options.lib_dirs) |dir| {
        // Verify that search path actually exists
        var tmp = std.fs.cwd().openDir(dir, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer tmp.close();

        try lib_dirs.append(dir);
    }

    var libs = std.StringArrayHashMap(void).init(arena);
    var lib_not_found = false;
    for (ld.options.libs) |lib_name| {
        for (&[_][]const u8{".a"}) |ext| {
            if (try resolveLib(arena, lib_dirs.items, lib_name, ext)) |full_path| {
                _ = try libs.getOrPut(full_path);
                break;
            }
        } else {
            try stderr.print("library not found for '-l{s}'\n", .{lib_name});
            lib_not_found = true;
        }
    }
    if (lib_not_found) {
        try stderr.writeAll("Library search paths:\n");
        for (lib_dirs.items) |dir| {
            try stderr.print("  {s}\n", .{dir});
        }
    }

    var positionals = std.ArrayList([]const u8).init(arena);
    try positionals.ensureTotalCapacity(ld.options.positionals.len);
    for (ld.options.positionals) |path| {
        positionals.appendAssumeCapacity(path);
    }

    try ld.parsePositionals(positionals.items);
    // try ld.parseLibs(libs.keys());
}

fn resolveLib(
    arena: Allocator,
    search_dirs: []const []const u8,
    name: []const u8,
    ext: []const u8,
) !?[]const u8 {
    const search_name = try std.fmt.allocPrint(arena, "lib{s}{s}", .{ name, ext });

    for (search_dirs) |dir| {
        const full_path = try std.fs.path.join(arena, &[_][]const u8{ dir, search_name });
        // Check if the file exists.
        const tmp = std.fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        defer tmp.close();

        return full_path;
    }

    return null;
}

fn parsePositionals(ld: *Elf, files: []const []const u8) !void {
    for (files) |file_name| {
        const full_path = full_path: {
            var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const path = try std.fs.realpath(file_name, &buffer);
            break :full_path try ld.allocator.dupe(u8, path);
        };
        defer ld.allocator.free(full_path);
        log.debug("parsing input file path '{s}'", .{full_path});

        blk: {
            ld.parseObjectFile(full_path) catch |err| switch (err) {
                error.NotObject => break :blk,
                else => |e| return e,
            };
            continue;
        }
        const stderr = std.io.getStdErr().writer();
        return stderr.print("unknown filetype for positional input file: '{s}'\n", .{file_name});
    }
}

fn parseObjectFile(ld: *Elf, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const name = try ld.allocator.dupe(u8, path);
    errdefer ld.allocator.free(name);

    const file_stat = try file.stat();
    const file_size = std.math.cast(usize, file_stat.size) orelse return error.Overflow;
    const data = try file.readToEndAlloc(ld.allocator, file_size);
    errdefer ld.allocator.free(data);

    var obj = Object{
        .name = name,
        .data = data,
    };
    try obj.parse(ld.allocator);
    try ld.objects.append(ld.allocator, obj);
}

const std = @import("std");
const log = std.log;

const Allocator = std.mem.Allocator;
const Elf = @This();
const Object = @import("Object.zig");
