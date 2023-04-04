const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const gpaType = if (builtin.mode == .Debug) std.heap.GeneralPurposeAllocator(.{}) else void;
var g_alloc: gpaType = .{};
const gpa = if (builtin.mode == .Debug) g_alloc.allocator() else std.heap.c_allocator;

const usage =
    \\Usage: syclld [files...]
    \\
    \\General Options:
    \\-l[name]                      Specify library to link against
    \\-L[path]                      Specify library search dir
    \\-o [path]                     Specify output path for the final artifact
    \\-h, --help                    Print this help and exit
    \\--debug-log [scope]           Turn on debugging logs for [scope]
    \\
;

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    ret: {
        const msg = std.fmt.allocPrint(gpa, format, args) catch break :ret;
        std.io.getStdErr().writeAll(msg) catch {};
    }
    std.process.exit(1);
}

var log_scopes: std.ArrayList([]const u8) = std.ArrayList([]const u8).init(gpa);

pub const std_options = struct {
    pub fn logFn(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // Hide debug messages unless:
        // * logging enabled with `-Dlog`.
        // * the --debug-log arg for the scope has been provided
        if (@enumToInt(level) > @enumToInt(std.options.log_level) or
            @enumToInt(level) > @enumToInt(std.log.Level.info))
        {
            if (!build_options.enable_logging) return;

            const scope_name = @tagName(scope);
            for (log_scopes.items) |log_scope| {
                if (std.mem.eql(u8, log_scope, scope_name)) break;
            } else return;
        }

        // We only recognize 4 log levels in this application.
        const level_txt = switch (level) {
            .err => "error",
            .warn => "warning",
            .info => "info",
            .debug => "debug",
        };
        const prefix1 = level_txt;
        const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

        // Print the message to stderr, silently ignoring any errors
        std.debug.print(prefix1 ++ prefix2 ++ format ++ "\n", args);
    }
};

const ArgsIterator = struct {
    args: []const []const u8,
    i: usize = 0,

    fn next(it: *@This()) ?[]const u8 {
        if (it.i >= it.args.len) {
            return null;
        }
        defer it.i += 1;
        return it.args[it.i];
    }

    fn nextOrFatal(it: *@This()) []const u8 {
        return it.next() orelse fatal("expected parameter after {s}\n", .{it.args[it.i - 1]});
    }
};

pub fn main() !void {
    const all_args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, all_args);

    const args = all_args[1..];

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    if (args.len == 0) fatal(usage, .{});

    var positionals = std.ArrayList([]const u8).init(arena);
    var libs = std.StringArrayHashMap(void).init(arena);
    var lib_dirs = std.ArrayList([]const u8).init(arena);
    var out_path: ?[]const u8 = null;

    var args_iter = ArgsIterator{ .args = args };

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            fatal(usage, .{});
        } else if (std.mem.eql(u8, arg, "--debug-log")) {
            const scope = args_iter.nextOrFatal();
            try log_scopes.append(scope);
        } else if (std.mem.startsWith(u8, arg, "-l")) {
            try libs.put(arg[2..], {});
        } else if (std.mem.startsWith(u8, arg, "-L")) {
            try lib_dirs.append(arg[2..]);
        } else if (std.mem.eql(u8, arg, "-o")) {
            out_path = args_iter.nextOrFatal();
        } else {
            try positionals.append(arg);
        }
    }

    if (positionals.items.len == 0) {
        fatal("expected at least one positional argument\n", .{});
    }
}
