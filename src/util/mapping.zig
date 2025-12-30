const std = @import("std");

pub const Mapping = std.json.ArrayHashMap([]const u8);

pub fn deinit(allocator: std.mem.Allocator, map: *Mapping) void {
    var it = map.map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit(allocator);
}
