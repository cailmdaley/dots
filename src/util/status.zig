const std = @import("std");

pub const StatusKind = enum(u2) { open, active, closed };

pub fn parse(status: []const u8) ?StatusKind {
    if (std.mem.eql(u8, status, "open")) return .open;
    if (std.mem.eql(u8, status, "active") or std.mem.eql(u8, status, "in_progress")) return .active;
    if (std.mem.eql(u8, status, "closed") or std.mem.eql(u8, status, "done")) return .closed;
    return null;
}

pub fn toString(kind: StatusKind) []const u8 {
    return switch (kind) {
        .open => "open",
        .active => "active",
        .closed => "closed",
    };
}

pub fn display(kind: StatusKind) []const u8 {
    return if (kind == .closed) "done" else toString(kind);
}

pub fn char(kind: StatusKind) u8 {
    return switch (kind) {
        .open => 'o',
        .active => '>',
        .closed => 'x',
    };
}

pub fn symbol(kind: StatusKind) []const u8 {
    return switch (kind) {
        .open => "○",
        .active => "●",
        .closed => "✓",
    };
}

pub fn isBlocking(kind: StatusKind) bool {
    return kind == .open or kind == .active;
}
