const std = @import("std");
const rocks = @import("zrocks");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const db = try rocks.DB.open(allocator, "/tmp/zrocks-demo", .{
        .create_if_missing = true,
        .compression = .zstd,
        .write_buffer_size = 64 * 1024 * 1024,
    });
    defer db.close();

    try db.put("user:1", "alice");
    try db.put("user:2", "bob");

    if (try db.get(allocator, "user:1")) |value| {
        defer allocator.free(value);
        std.debug.print("user:1 = {s}\n", .{value});
    }

    var it = try db.iterator();
    defer it.deinit();

    it.seek("user:");
    while (it.valid()) : (it.next()) {
        if (!std.mem.startsWith(u8, it.key(), "user:")) break;
        std.debug.print("{s} -> {s}\n", .{ it.key(), it.value() });
    }
    try it.status();
}
