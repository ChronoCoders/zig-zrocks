const std = @import("std");
const rocks = @import("rocksdb.zig");
const testing = std.testing;

fn tmpDbPath(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![]u8 {
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "db" });
}

test "open and close roundtrip" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    db.close();

    const reopened = try rocks.DB.open(allocator, path, .{ .create_if_missing = false });
    reopened.close();
}

test "put then get returns the value" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    try db.put("alpha", "one");

    const value = try db.get(allocator, "alpha");
    try testing.expect(value != null);
    defer allocator.free(value.?);
    try testing.expectEqualStrings("one", value.?);
}

test "delete then get returns null" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    try db.put("beta", "two");
    try db.delete("beta");

    const value = try db.get(allocator, "beta");
    try testing.expect(value == null);
}

test "missing key returns null" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    const value = try db.get(allocator, "does-not-exist");
    try testing.expect(value == null);
}

test "multi get batch lookup" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    try db.put("k1", "v1");
    try db.put("k3", "v3");

    const keys = [_][]const u8{ "k1", "k2", "k3" };
    const results = try db.multiGet(allocator, &keys);
    defer rocks.DB.freeMultiGet(allocator, results);

    try testing.expect(results[0] != null);
    try testing.expectEqualStrings("v1", results[0].?);
    try testing.expect(results[1] == null);
    try testing.expect(results[2] != null);
    try testing.expectEqualStrings("v3", results[2].?);
}

test "write batch applies multiple ops atomically" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    try db.put("stale", "old");

    const batch = try rocks.WriteBatch.init();
    defer batch.deinit();
    batch.put("a", "1");
    batch.put("b", "2");
    batch.delete("stale");
    try testing.expectEqual(@as(usize, 3), batch.count());

    try db.write(batch);

    const a = try db.get(allocator, "a");
    defer if (a) |v| allocator.free(v);
    const b = try db.get(allocator, "b");
    defer if (b) |v| allocator.free(v);
    const stale = try db.get(allocator, "stale");

    try testing.expect(a != null and b != null and stale == null);
    try testing.expectEqualStrings("1", a.?);
    try testing.expectEqualStrings("2", b.?);
}

test "iterator forward scan visits keys in order" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    try db.put("k1", "v1");
    try db.put("k2", "v2");
    try db.put("k3", "v3");

    var it = try db.iterator();
    defer it.deinit();

    const expected_keys = [_][]const u8{ "k1", "k2", "k3" };
    const expected_vals = [_][]const u8{ "v1", "v2", "v3" };

    var i: usize = 0;
    it.seekToFirst();
    while (it.valid()) : (it.next()) {
        try testing.expect(i < expected_keys.len);
        try testing.expectEqualStrings(expected_keys[i], it.key());
        try testing.expectEqualStrings(expected_vals[i], it.value());
        i += 1;
    }
    try it.status();
    try testing.expectEqual(expected_keys.len, i);
}

test "iterator seek lands on the requested key" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    try db.put("apple", "a");
    try db.put("mango", "m");
    try db.put("pear", "p");

    var it = try db.iterator();
    defer it.deinit();

    it.seek("mango");
    try testing.expect(it.valid());
    try testing.expectEqualStrings("mango", it.key());
    try testing.expectEqualStrings("m", it.value());

    it.seekToLast();
    try testing.expect(it.valid());
    try testing.expectEqualStrings("pear", it.key());

    it.prev();
    try testing.expect(it.valid());
    try testing.expectEqualStrings("mango", it.key());
    try it.status();
}

test "column family create write read drop" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    {
        const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
        defer db.close();

        const cf = try db.createColumnFamily(allocator, "metrics", .{});
        try db.putCf(cf, "hits", "42");

        const got = try db.getCf(allocator, cf, "hits");
        try testing.expect(got != null);
        defer allocator.free(got.?);
        try testing.expectEqualStrings("42", got.?);

        const default_miss = try db.get(allocator, "hits");
        try testing.expect(default_miss == null);

        cf.deinit();
    }

    {
        const names = try rocks.listColumnFamilies(allocator, path, .{});
        defer rocks.freeColumnFamilyNames(allocator, names);
        var saw_metrics = false;
        for (names) |n| {
            if (std.mem.eql(u8, n, "metrics")) saw_metrics = true;
        }
        try testing.expect(saw_metrics);
    }

    {
        var handles: [2]rocks.ColumnFamily = undefined;
        const descriptors = [_]rocks.CfDescriptor{
            .{ .name = "default" },
            .{ .name = "metrics" },
        };
        const db = try rocks.DB.openColumnFamilies(allocator, path, .{}, &descriptors, &handles);
        defer db.close();

        const got = try db.getCf(allocator, handles[1], "hits");
        try testing.expect(got != null);
        defer allocator.free(got.?);
        try testing.expectEqualStrings("42", got.?);

        try db.dropColumnFamily(handles[1]);

        handles[0].deinit();
        handles[1].deinit();
    }
}

test "snapshot isolates reads from later writes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    try db.put("key", "before");

    const snap = try db.createSnapshot();
    defer db.releaseSnapshot(snap);

    try db.put("key", "after");

    var ropts = try rocks.ReadOptions.init();
    defer ropts.deinit();
    ropts.setSnapshot(snap);

    const snap_value = try db.getOpt(allocator, ropts, "key");
    try testing.expect(snap_value != null);
    defer allocator.free(snap_value.?);
    try testing.expectEqualStrings("before", snap_value.?);

    const live_value = try db.get(allocator, "key");
    try testing.expect(live_value != null);
    defer allocator.free(live_value.?);
    try testing.expectEqualStrings("after", live_value.?);
}

fn compressionRoundtrip(compression: rocks.Compression) !void {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{
        .create_if_missing = true,
        .compression = compression,
    });
    defer db.close();

    var key_buf: [16]u8 = undefined;
    var val_buf: [256]u8 = undefined;
    @memset(&val_buf, 'x');

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "key{d:0>6}", .{i});
        const value = try std.fmt.bufPrint(&val_buf, "payload-{d}-", .{i});
        @memset(val_buf[value.len..], 'x');
        try db.put(key, &val_buf);
    }

    db.compactRange(null, null);

    i = 0;
    while (i < 500) : (i += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "key{d:0>6}", .{i});
        const got = try db.get(allocator, key);
        try testing.expect(got != null);
        defer allocator.free(got.?);
        const expected = try std.fmt.bufPrint(&val_buf, "payload-{d}-", .{i});
        @memset(val_buf[expected.len..], 'x');
        try testing.expectEqualSlices(u8, &val_buf, got.?);
    }
}

test "snappy compression roundtrip" {
    try compressionRoundtrip(.snappy);
}

test "bz2 compression roundtrip" {
    try compressionRoundtrip(.bz2);
}

test "manual compaction smoke test" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDbPath(&tmp, allocator);
    defer allocator.free(path);

    const db = try rocks.DB.open(allocator, path, .{ .create_if_missing = true });
    defer db.close();

    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "key{d:0>5}", .{i});
        try db.put(key, "payload");
    }
    i = 0;
    while (i < 200) : (i += 2) {
        const key = try std.fmt.bufPrint(&buf, "key{d:0>5}", .{i});
        try db.delete(key);
    }

    db.compactRange(null, null);

    const survivor = try db.get(allocator, "key00001");
    try testing.expect(survivor != null);
    defer allocator.free(survivor.?);
    try testing.expectEqualStrings("payload", survivor.?);

    const removed = try db.get(allocator, "key00000");
    try testing.expect(removed == null);
}
