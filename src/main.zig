const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");

const libc = @cImport({
    @cInclude("time.h");
});

const BEADS_DIR = ".beads";
const BEADS_DB = ".beads/beads.db";
const BEADS_JSONL = ".beads/issues.jsonl";

// Command dispatch table
const Handler = *const fn (Allocator, []const []const u8) anyerror!void;
const Command = struct { names: []const []const u8, handler: Handler };

const commands = [_]Command{
    .{ .names = &.{ "add", "create" }, .handler = cmdAdd },
    .{ .names = &.{ "ls", "list" }, .handler = cmdList },
    .{ .names = &.{ "it", "do" }, .handler = cmdIt },
    .{ .names = &.{ "off", "done" }, .handler = cmdOff },
    .{ .names = &.{ "rm", "delete" }, .handler = cmdRm },
    .{ .names = &.{"show"}, .handler = cmdShow },
    .{ .names = &.{"ready"}, .handler = cmdReady },
    .{ .names = &.{"tree"}, .handler = cmdTree },
    .{ .names = &.{"find"}, .handler = cmdFind },
    .{ .names = &.{"update"}, .handler = cmdBeadsUpdate },
    .{ .names = &.{"close"}, .handler = cmdBeadsClose },
};

fn findCommand(name: []const u8) ?Handler {
    inline for (commands) |cmd| {
        inline for (cmd.names) |n| {
            if (std.mem.eql(u8, name, n)) return cmd.handler;
        }
    }
    return null;
}

fn isCommand(s: []const u8) bool {
    return findCommand(s) != null or
        std.mem.eql(u8, s, "init") or
        std.mem.eql(u8, s, "help") or
        std.mem.eql(u8, s, "--help") or
        std.mem.eql(u8, s, "-h") or
        std.mem.eql(u8, s, "--version") or
        std.mem.eql(u8, s, "-v");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try cmdReady(allocator, &.{"--json"});
        return;
    }

    const cmd = args[1];

    // Quick add: dot "title"
    if (cmd.len > 0 and cmd[0] != '-' and !isCommand(cmd)) {
        try cmdAdd(allocator, args[1..]);
        return;
    }

    // Special commands
    if (std.mem.eql(u8, cmd, "init")) return cmdInit(allocator);
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) return stdout().writeAll(USAGE);
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) return stdout().writeAll("dots 0.2.0\n");

    // Dispatch from table
    if (findCommand(cmd)) |handler| {
        try handler(allocator, args[2..]);
    } else {
        try cmdAdd(allocator, args[1..]);
    }
}

fn openStorage(allocator: Allocator) !sqlite.Storage {
    return sqlite.Storage.open(allocator, BEADS_DB);
}

// I/O helpers
const Writer = std.io.GenericWriter(void, anyerror, struct {
    fn write(_: void, bytes: []const u8) !usize {
        return fs.File.stdout().write(bytes);
    }
}.write);

fn stdout() Writer {
    return .{ .context = {} };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    _ = fs.File.stderr().write(msg) catch {};
    std.process.exit(1);
}

// Status helpers
fn statusChar(status: []const u8) u8 {
    return if (std.mem.eql(u8, status, "open")) 'o' else if (std.mem.eql(u8, status, "active")) '>' else 'x';
}

fn statusSym(status: []const u8) []const u8 {
    return if (std.mem.eql(u8, status, "open")) "○" else if (std.mem.eql(u8, status, "active")) "●" else "✓";
}

fn mapStatus(s: []const u8) []const u8 {
    if (std.mem.eql(u8, s, "in_progress")) return "active";
    if (std.mem.eql(u8, s, "closed")) return "done";
    return s;
}

// Arg parsing helper
fn getArg(args: []const []const u8, i: *usize, flag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, args[i.*], flag) and i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

const USAGE =
    \\dots - Connect the dots
    \\
    \\Usage: dot [command] [options]
    \\
    \\Commands:
    \\  dot "title"                  Quick add a dot
    \\  dot add "title" [options]    Add a dot (-p priority, -d desc, -P parent, -a after)
    \\  dot ls [--status S] [--json] List dots
    \\  dot it <id>                  Start working ("I'm on it!")
    \\  dot off <id> [-r reason]     Complete ("cross it off")
    \\  dot rm <id>                  Remove a dot
    \\  dot show <id>                Show dot details
    \\  dot ready [--json]           Show unblocked dots
    \\  dot tree                     Show hierarchy
    \\  dot find "query"             Search dots
    \\  dot init                     Initialize .beads directory
    \\
    \\Examples:
    \\  dot "Fix the bug"
    \\  dot add "Design API" -p 1 -d "REST endpoints"
    \\  dot add "Implement" -P bd-1 -a bd-2
    \\  dot it bd-3
    \\  dot off bd-3 -r "shipped"
    \\
;

fn cmdInit(allocator: Allocator) !void {
    fs.cwd().makeDir(BEADS_DIR) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const jsonl_exists = fs.cwd().access(BEADS_JSONL, .{}) != error.FileNotFound;

    var storage = try openStorage(allocator);
    defer storage.close();

    if (jsonl_exists) {
        const count = try sqlite.hydrateFromJsonl(&storage, allocator, BEADS_JSONL);
        if (count > 0) try stdout().print("Hydrated {d} issues from {s}\n", .{ count, BEADS_JSONL });
    }
}

fn cmdAdd(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot add <title> [options]\n", .{});

    var title: []const u8 = "";
    var description: []const u8 = "";
    var priority: i64 = 2;
    var parent: ?[]const u8 = null;
    var after: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-p")) |v| {
            priority = std.fmt.parseInt(i64, v, 10) catch 2;
        } else if (getArg(args, &i, "-d")) |v| {
            description = v;
        } else if (getArg(args, &i, "-P")) |v| {
            parent = v;
        } else if (getArg(args, &i, "-a")) |v| {
            after = v;
        } else if (title.len == 0 and args[i].len > 0 and args[i][0] != '-') {
            title = args[i];
        }
    }

    if (title.len == 0) fatal("Error: title required\n", .{});

    const id = try generateId(allocator);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    const issue = sqlite.Issue{
        .id = id,
        .title = title,
        .description = description,
        .status = "open",
        .priority = priority,
        .issue_type = "task",
        .assignee = null,
        .created_at = now,
        .updated_at = now,
        .closed_at = null,
        .close_reason = null,
        .after = after,
        .parent = parent,
    };

    try storage.createIssue(issue);

    const w = stdout();
    if (hasFlag(args, "--json")) {
        try writeIssueJson(issue, w);
        try w.writeByte('\n');
    } else {
        try w.print("{s}\n", .{id});
    }
}

fn cmdList(allocator: Allocator, args: []const []const u8) !void {
    var filter_status: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| filter_status = mapStatus(v);
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.listIssues(filter_status);
    defer allocator.free(issues);

    try writeIssueList(issues, filter_status == null, hasFlag(args, "--json"));
}

fn cmdReady(allocator: Allocator, args: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.getReadyIssues();
    defer allocator.free(issues);

    try writeIssueList(issues, false, hasFlag(args, "--json"));
}

fn writeIssueList(issues: []const sqlite.Issue, skip_done: bool, use_json: bool) !void {
    const w = stdout();
    if (use_json) {
        try w.writeByte('[');
        var first = true;
        for (issues) |issue| {
            if (skip_done and std.mem.eql(u8, issue.status, "done")) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try writeIssueJson(issue, w);
        }
        try w.writeAll("]\n");
    } else {
        for (issues) |issue| {
            if (skip_done and std.mem.eql(u8, issue.status, "done")) continue;
            try w.print("[{s}] {c} {s}\n", .{ issue.id, statusChar(issue.status), issue.title });
        }
    }
}

fn cmdIt(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot it <id>\n", .{});

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.updateStatus(args[0], "active", now, null, null);
}

fn cmdOff(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot off <id> [-r reason]\n", .{});

    var reason: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-r")) |v| reason = v;
    }

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.updateStatus(args[0], "done", now, now, reason);
}

fn cmdRm(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot rm <id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.deleteIssue(args[0]);
}

fn cmdShow(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot show <id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const iss = try storage.getIssue(args[0]) orelse fatal("Issue not found: {s}\n", .{args[0]});

    const w = stdout();
    try w.print("ID:       {s}\nTitle:    {s}\nStatus:   {s}\nPriority: {d}\n", .{ iss.id, iss.title, iss.status, iss.priority });
    if (iss.description.len > 0) try w.print("Desc:     {s}\n", .{iss.description});
    try w.print("Created:  {s}\n", .{iss.created_at});
    if (iss.closed_at) |ca| try w.print("Closed:   {s}\n", .{ca});
    if (iss.close_reason) |r| try w.print("Reason:   {s}\n", .{r});
}

fn cmdTree(allocator: Allocator, args: []const []const u8) !void {
    _ = args;

    var storage = try openStorage(allocator);
    defer storage.close();

    const roots = try storage.getRootIssues();
    defer allocator.free(roots);

    const w = stdout();
    for (roots) |root| {
        try w.print("[{s}] {s} {s}\n", .{ root.id, statusSym(root.status), root.title });

        const children = try storage.getChildren(root.id);
        defer allocator.free(children);

        for (children) |child| {
            const blocked_msg: []const u8 = if (try storage.isBlocked(child.id)) " (blocked)" else "";
            try w.print("  └─ [{s}] {s} {s}{s}\n", .{ child.id, statusSym(child.status), child.title, blocked_msg });
        }
    }
}

fn cmdFind(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot find <query>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.searchIssues(args[0]);
    defer allocator.free(issues);

    const w = stdout();
    for (issues) |issue| {
        try w.print("[{s}] {c} {s}\n", .{ issue.id, statusChar(issue.status), issue.title });
    }
}

fn cmdBeadsUpdate(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot update <id> [--status S]\n", .{});

    var new_status: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| new_status = mapStatus(v);
    }

    if (new_status) |status| {
        var ts_buf: [40]u8 = undefined;
        const now = try formatTimestamp(&ts_buf);

        var storage = try openStorage(allocator);
        defer storage.close();

        try storage.updateStatus(args[0], status, now, null, null);
    }
}

fn cmdBeadsClose(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot close <id> [--reason R]\n", .{});

    var reason: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--reason")) |v| reason = v;
    }

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.updateStatus(args[0], "done", now, now, reason);
}

fn generateId(allocator: Allocator) ![]u8 {
    const nanos = std.time.nanoTimestamp();
    const ts: u64 = @intCast(@as(u128, @intCast(nanos)) & 0xFFFFFFFF);
    return std.fmt.allocPrint(allocator, "bd-{x}", .{@as(u16, @truncate(ts))});
}

fn formatTimestamp(buf: []u8) ![]const u8 {
    const nanos = std.time.nanoTimestamp();
    const epoch_nanos: u128 = @intCast(nanos);
    const epoch_secs: libc.time_t = @intCast(epoch_nanos / 1_000_000_000);
    const micros: u64 = @intCast((epoch_nanos % 1_000_000_000) / 1000);

    var tm: libc.struct_tm = undefined;
    _ = libc.localtime_r(&epoch_secs, &tm);

    const year: u64 = @intCast(tm.tm_year + 1900);
    const month: u64 = @intCast(tm.tm_mon + 1);
    const day: u64 = @intCast(tm.tm_mday);
    const hours: u64 = @intCast(tm.tm_hour);
    const mins: u64 = @intCast(tm.tm_min);
    const secs: u64 = @intCast(tm.tm_sec);

    const tz_offset_secs: i64 = tm.tm_gmtoff;
    const tz_hours: i64 = @divTrunc(tz_offset_secs, 3600);
    const tz_mins: u64 = @abs(@rem(tz_offset_secs, 3600)) / 60;
    const tz_sign: u8 = if (tz_hours >= 0) '+' else '-';
    const tz_hours_abs: u64 = @abs(tz_hours);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}{c}{d:0>2}:{d:0>2}", .{
        year, month, day, hours, mins, secs, micros, tz_sign, tz_hours_abs, tz_mins,
    });
}

fn writeIssueJson(issue: sqlite.Issue, w: Writer) !void {
    try w.writeAll("{\"id\":\"");
    try w.writeAll(issue.id);
    try w.writeAll("\",\"title\":");
    try writeJsonString(issue.title, w);
    if (issue.description.len > 0) {
        try w.writeAll(",\"description\":");
        try writeJsonString(issue.description, w);
    }
    try w.writeAll(",\"status\":\"");
    try w.writeAll(issue.status);
    try w.writeAll("\",\"priority\":");
    try w.print("{d}", .{issue.priority});
    try w.writeAll(",\"issue_type\":\"");
    try w.writeAll(issue.issue_type);
    try w.writeAll("\",\"created_at\":\"");
    try w.writeAll(issue.created_at);
    try w.writeAll("\",\"updated_at\":\"");
    try w.writeAll(issue.updated_at);
    try w.writeByte('"');
    if (issue.closed_at) |ca| {
        try w.writeAll(",\"closed_at\":\"");
        try w.writeAll(ca);
        try w.writeByte('"');
    }
    if (issue.close_reason) |r| {
        try w.writeAll(",\"close_reason\":");
        try writeJsonString(r, w);
    }
    try w.writeByte('}');
}

fn writeJsonString(s: []const u8, w: Writer) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

test "basic" {
    try std.testing.expect(true);
}
