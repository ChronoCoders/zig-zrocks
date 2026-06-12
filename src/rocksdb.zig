const std = @import("std");
const c = @import("c.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    NotFound,
    Corruption,
    NotSupported,
    InvalidArgument,
    IoError,
    MergeInProgress,
    Incomplete,
    ShutdownInProgress,
    TimedOut,
    Aborted,
    Busy,
    Expired,
    TryAgain,
    Unknown,
    OutOfMemory,
};

pub const Compression = enum(c_int) {
    none = 0,
    snappy = 1,
    zlib = 2,
    bz2 = 3,
    lz4 = 4,
    lz4hc = 5,
    xpress = 6,
    zstd = 7,
};

pub const Options = struct {
    create_if_missing: bool = false,
    create_missing_column_families: bool = false,
    compression: Compression = .none,
    write_buffer_size: ?usize = null,
    max_open_files: ?i32 = null,
};

pub const CfDescriptor = struct {
    name: []const u8,
    options: Options = .{},
};

pub const ColumnFamily = struct {
    ptr: *c.rocksdb_column_family_handle_t,

    pub fn deinit(self: ColumnFamily) void {
        c.rocksdb_column_family_handle_destroy(self.ptr);
    }
};

pub const Snapshot = struct {
    ptr: *const c.rocksdb_snapshot_t,
};

pub const ReadOptions = struct {
    ptr: *c.rocksdb_readoptions_t,

    pub fn init() Error!ReadOptions {
        const p = c.rocksdb_readoptions_create() orelse return error.OutOfMemory;
        return .{ .ptr = p };
    }

    pub fn deinit(self: ReadOptions) void {
        c.rocksdb_readoptions_destroy(self.ptr);
    }

    pub fn setSnapshot(self: ReadOptions, snapshot: Snapshot) void {
        c.rocksdb_readoptions_set_snapshot(self.ptr, snapshot.ptr);
    }
};

pub const WriteBatch = struct {
    ptr: *c.rocksdb_writebatch_t,

    pub fn init() Error!WriteBatch {
        const p = c.rocksdb_writebatch_create() orelse return error.OutOfMemory;
        return .{ .ptr = p };
    }

    pub fn deinit(self: WriteBatch) void {
        c.rocksdb_writebatch_destroy(self.ptr);
    }

    pub fn clear(self: WriteBatch) void {
        c.rocksdb_writebatch_clear(self.ptr);
    }

    pub fn count(self: WriteBatch) usize {
        return @intCast(c.rocksdb_writebatch_count(self.ptr));
    }

    pub fn put(self: WriteBatch, key: []const u8, value: []const u8) void {
        c.rocksdb_writebatch_put(self.ptr, key.ptr, key.len, value.ptr, value.len);
    }

    pub fn putCf(self: WriteBatch, cf: ColumnFamily, key: []const u8, value: []const u8) void {
        c.rocksdb_writebatch_put_cf(self.ptr, cf.ptr, key.ptr, key.len, value.ptr, value.len);
    }

    pub fn delete(self: WriteBatch, key: []const u8) void {
        c.rocksdb_writebatch_delete(self.ptr, key.ptr, key.len);
    }

    pub fn deleteCf(self: WriteBatch, cf: ColumnFamily, key: []const u8) void {
        c.rocksdb_writebatch_delete_cf(self.ptr, cf.ptr, key.ptr, key.len);
    }
};

pub const Iterator = struct {
    ptr: *c.rocksdb_iterator_t,

    pub fn deinit(self: Iterator) void {
        c.rocksdb_iter_destroy(self.ptr);
    }

    pub fn valid(self: Iterator) bool {
        return c.rocksdb_iter_valid(self.ptr) != 0;
    }

    pub fn seekToFirst(self: Iterator) void {
        c.rocksdb_iter_seek_to_first(self.ptr);
    }

    pub fn seekToLast(self: Iterator) void {
        c.rocksdb_iter_seek_to_last(self.ptr);
    }

    pub fn seek(self: Iterator, target: []const u8) void {
        c.rocksdb_iter_seek(self.ptr, target.ptr, target.len);
    }

    pub fn seekForPrev(self: Iterator, target: []const u8) void {
        c.rocksdb_iter_seek_for_prev(self.ptr, target.ptr, target.len);
    }

    pub fn next(self: Iterator) void {
        c.rocksdb_iter_next(self.ptr);
    }

    pub fn prev(self: Iterator) void {
        c.rocksdb_iter_prev(self.ptr);
    }

    pub fn key(self: Iterator) []const u8 {
        var len: usize = 0;
        const p = c.rocksdb_iter_key(self.ptr, &len);
        return p[0..len];
    }

    pub fn value(self: Iterator) []const u8 {
        var len: usize = 0;
        const p = c.rocksdb_iter_value(self.ptr, &len);
        return p[0..len];
    }

    pub fn status(self: Iterator) Error!void {
        var err: [*c]u8 = null;
        c.rocksdb_iter_get_error(self.ptr, &err);
        if (err != null) return consumeError(err);
    }
};

pub const DB = struct {
    ptr: *c.rocksdb_t,
    write_opts: *c.rocksdb_writeoptions_t,
    read_opts: *c.rocksdb_readoptions_t,

    pub fn open(allocator: Allocator, path: []const u8, options: Options) Error!DB {
        const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer allocator.free(path_z);

        const opts = try buildOptions(options);
        defer c.rocksdb_options_destroy(opts);

        var err: [*c]u8 = null;
        const handle = c.rocksdb_open(opts, path_z.ptr, &err);
        if (err != null) return consumeError(err);
        const ptr = handle orelse return error.Unknown;

        return finishOpen(ptr);
    }

    pub fn openColumnFamilies(
        allocator: Allocator,
        path: []const u8,
        db_options: Options,
        descriptors: []const CfDescriptor,
        out_handles: []ColumnFamily,
    ) Error!DB {
        if (out_handles.len != descriptors.len) return error.InvalidArgument;
        const n = descriptors.len;

        const names = allocator.alloc([*c]const u8, n) catch return error.OutOfMemory;
        defer allocator.free(names);

        const name_storage = allocator.alloc([:0]u8, n) catch return error.OutOfMemory;
        var names_built: usize = 0;
        defer {
            for (name_storage[0..names_built]) |s| allocator.free(s);
            allocator.free(name_storage);
        }

        const cf_opts = allocator.alloc(?*c.rocksdb_options_t, n) catch return error.OutOfMemory;
        var opts_built: usize = 0;
        defer {
            for (cf_opts[0..opts_built]) |maybe| if (maybe) |o| c.rocksdb_options_destroy(o);
            allocator.free(cf_opts);
        }

        const handles_raw = allocator.alloc(?*c.rocksdb_column_family_handle_t, n) catch return error.OutOfMemory;
        defer allocator.free(handles_raw);

        for (descriptors, 0..) |d, i| {
            const nz = allocator.dupeZ(u8, d.name) catch return error.OutOfMemory;
            name_storage[i] = nz;
            names_built += 1;
            names[i] = nz.ptr;

            cf_opts[i] = try buildOptions(d.options);
            opts_built += 1;
        }

        const db_opts = try buildOptions(db_options);
        defer c.rocksdb_options_destroy(db_opts);

        const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer allocator.free(path_z);

        var err: [*c]u8 = null;
        const handle = c.rocksdb_open_column_families(
            db_opts,
            path_z.ptr,
            @intCast(n),
            @ptrCast(names.ptr),
            @ptrCast(cf_opts.ptr),
            handles_raw.ptr,
            &err,
        );
        if (err != null) return consumeError(err);
        const ptr = handle orelse return error.Unknown;

        for (handles_raw, 0..) |maybe, i| {
            const h = maybe orelse {
                for (handles_raw) |m| if (m) |hp| c.rocksdb_column_family_handle_destroy(hp);
                c.rocksdb_close(ptr);
                return error.Unknown;
            };
            out_handles[i] = .{ .ptr = h };
        }

        return finishOpen(ptr);
    }

    fn finishOpen(ptr: *c.rocksdb_t) Error!DB {
        const wopts = c.rocksdb_writeoptions_create() orelse {
            c.rocksdb_close(ptr);
            return error.OutOfMemory;
        };
        const ropts = c.rocksdb_readoptions_create() orelse {
            c.rocksdb_writeoptions_destroy(wopts);
            c.rocksdb_close(ptr);
            return error.OutOfMemory;
        };
        return DB{ .ptr = ptr, .write_opts = wopts, .read_opts = ropts };
    }

    pub fn close(self: DB) void {
        c.rocksdb_readoptions_destroy(self.read_opts);
        c.rocksdb_writeoptions_destroy(self.write_opts);
        c.rocksdb_close(self.ptr);
    }

    pub fn put(self: DB, key: []const u8, value: []const u8) Error!void {
        var err: [*c]u8 = null;
        c.rocksdb_put(self.ptr, self.write_opts, key.ptr, key.len, value.ptr, value.len, &err);
        if (err != null) return consumeError(err);
    }

    pub fn putCf(self: DB, cf: ColumnFamily, key: []const u8, value: []const u8) Error!void {
        var err: [*c]u8 = null;
        c.rocksdb_put_cf(self.ptr, self.write_opts, cf.ptr, key.ptr, key.len, value.ptr, value.len, &err);
        if (err != null) return consumeError(err);
    }

    pub fn get(self: DB, allocator: Allocator, key: []const u8) Error!?[]u8 {
        return self.getImpl(allocator, self.read_opts, key);
    }

    pub fn getOpt(self: DB, allocator: Allocator, read_options: ReadOptions, key: []const u8) Error!?[]u8 {
        return self.getImpl(allocator, read_options.ptr, key);
    }

    fn getImpl(self: DB, allocator: Allocator, ropts: *c.rocksdb_readoptions_t, key: []const u8) Error!?[]u8 {
        var vallen: usize = 0;
        var err: [*c]u8 = null;
        const v = c.rocksdb_get(self.ptr, ropts, key.ptr, key.len, &vallen, &err);
        if (err != null) return consumeError(err);
        if (v == null) return null;
        defer c.rocksdb_free(@ptrCast(v));
        const out = allocator.alloc(u8, vallen) catch return error.OutOfMemory;
        @memcpy(out, v[0..vallen]);
        return out;
    }

    pub fn getCf(self: DB, allocator: Allocator, cf: ColumnFamily, key: []const u8) Error!?[]u8 {
        var vallen: usize = 0;
        var err: [*c]u8 = null;
        const v = c.rocksdb_get_cf(self.ptr, self.read_opts, cf.ptr, key.ptr, key.len, &vallen, &err);
        if (err != null) return consumeError(err);
        if (v == null) return null;
        defer c.rocksdb_free(@ptrCast(v));
        const out = allocator.alloc(u8, vallen) catch return error.OutOfMemory;
        @memcpy(out, v[0..vallen]);
        return out;
    }

    pub fn delete(self: DB, key: []const u8) Error!void {
        var err: [*c]u8 = null;
        c.rocksdb_delete(self.ptr, self.write_opts, key.ptr, key.len, &err);
        if (err != null) return consumeError(err);
    }

    pub fn deleteCf(self: DB, cf: ColumnFamily, key: []const u8) Error!void {
        var err: [*c]u8 = null;
        c.rocksdb_delete_cf(self.ptr, self.write_opts, cf.ptr, key.ptr, key.len, &err);
        if (err != null) return consumeError(err);
    }

    pub fn multiGet(self: DB, allocator: Allocator, keys: []const []const u8) Error![]?[]u8 {
        const n = keys.len;
        const key_ptrs = allocator.alloc([*c]const u8, n) catch return error.OutOfMemory;
        defer allocator.free(key_ptrs);
        const key_sizes = allocator.alloc(usize, n) catch return error.OutOfMemory;
        defer allocator.free(key_sizes);
        for (keys, 0..) |k, i| {
            key_ptrs[i] = k.ptr;
            key_sizes[i] = k.len;
        }

        const vals = allocator.alloc([*c]u8, n) catch return error.OutOfMemory;
        defer allocator.free(vals);
        const val_sizes = allocator.alloc(usize, n) catch return error.OutOfMemory;
        defer allocator.free(val_sizes);
        const errs = allocator.alloc([*c]u8, n) catch return error.OutOfMemory;
        defer allocator.free(errs);
        for (0..n) |i| {
            vals[i] = null;
            errs[i] = null;
        }

        c.rocksdb_multi_get(
            self.ptr,
            self.read_opts,
            n,
            key_ptrs.ptr,
            key_sizes.ptr,
            vals.ptr,
            val_sizes.ptr,
            errs.ptr,
        );

        var first_error: ?Error = null;
        for (0..n) |i| {
            if (errs[i] != null) {
                if (first_error == null) first_error = classify(std.mem.span(errs[i]));
                c.rocksdb_free(@ptrCast(errs[i]));
            }
        }
        if (first_error) |e| {
            for (0..n) |i| if (vals[i] != null) c.rocksdb_free(@ptrCast(vals[i]));
            return e;
        }

        const result = allocator.alloc(?[]u8, n) catch return error.OutOfMemory;
        var filled: usize = 0;
        errdefer {
            for (result[0..filled]) |maybe| if (maybe) |s| allocator.free(s);
            allocator.free(result);
            for (filled..n) |i| if (vals[i] != null) c.rocksdb_free(@ptrCast(vals[i]));
        }

        for (0..n) |i| {
            if (vals[i] == null) {
                result[i] = null;
            } else {
                const slice = allocator.alloc(u8, val_sizes[i]) catch return error.OutOfMemory;
                @memcpy(slice, vals[i][0..val_sizes[i]]);
                c.rocksdb_free(@ptrCast(vals[i]));
                result[i] = slice;
            }
            filled += 1;
        }
        return result;
    }

    pub fn freeMultiGet(allocator: Allocator, results: []?[]u8) void {
        for (results) |maybe| if (maybe) |s| allocator.free(s);
        allocator.free(results);
    }

    pub fn write(self: DB, batch: WriteBatch) Error!void {
        var err: [*c]u8 = null;
        c.rocksdb_write(self.ptr, self.write_opts, batch.ptr, &err);
        if (err != null) return consumeError(err);
    }

    pub fn iterator(self: DB) Error!Iterator {
        const it = c.rocksdb_create_iterator(self.ptr, self.read_opts) orelse return error.Unknown;
        return .{ .ptr = it };
    }

    pub fn iteratorOpt(self: DB, read_options: ReadOptions) Error!Iterator {
        const it = c.rocksdb_create_iterator(self.ptr, read_options.ptr) orelse return error.Unknown;
        return .{ .ptr = it };
    }

    pub fn iteratorCf(self: DB, cf: ColumnFamily) Error!Iterator {
        const it = c.rocksdb_create_iterator_cf(self.ptr, self.read_opts, cf.ptr) orelse return error.Unknown;
        return .{ .ptr = it };
    }

    pub fn createColumnFamily(self: DB, allocator: Allocator, name: []const u8, options: Options) Error!ColumnFamily {
        const nz = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
        defer allocator.free(nz);
        const opts = try buildOptions(options);
        defer c.rocksdb_options_destroy(opts);
        var err: [*c]u8 = null;
        const h = c.rocksdb_create_column_family(self.ptr, opts, nz.ptr, &err);
        if (err != null) return consumeError(err);
        const ptr = h orelse return error.Unknown;
        return .{ .ptr = ptr };
    }

    pub fn dropColumnFamily(self: DB, cf: ColumnFamily) Error!void {
        var err: [*c]u8 = null;
        c.rocksdb_drop_column_family(self.ptr, cf.ptr, &err);
        if (err != null) return consumeError(err);
    }

    pub fn createSnapshot(self: DB) Error!Snapshot {
        const s = c.rocksdb_create_snapshot(self.ptr) orelse return error.Unknown;
        return .{ .ptr = s };
    }

    pub fn releaseSnapshot(self: DB, snapshot: Snapshot) void {
        c.rocksdb_release_snapshot(self.ptr, snapshot.ptr);
    }

    pub fn compactRange(self: DB, start: ?[]const u8, limit: ?[]const u8) void {
        const sp: [*c]const u8 = if (start) |s| s.ptr else null;
        const sl: usize = if (start) |s| s.len else 0;
        const lp: [*c]const u8 = if (limit) |l| l.ptr else null;
        const ll: usize = if (limit) |l| l.len else 0;
        c.rocksdb_compact_range(self.ptr, sp, sl, lp, ll);
    }

    pub fn compactRangeCf(self: DB, cf: ColumnFamily, start: ?[]const u8, limit: ?[]const u8) void {
        const sp: [*c]const u8 = if (start) |s| s.ptr else null;
        const sl: usize = if (start) |s| s.len else 0;
        const lp: [*c]const u8 = if (limit) |l| l.ptr else null;
        const ll: usize = if (limit) |l| l.len else 0;
        c.rocksdb_compact_range_cf(self.ptr, cf.ptr, sp, sl, lp, ll);
    }
};

pub fn listColumnFamilies(allocator: Allocator, path: []const u8, options: Options) Error![][]u8 {
    const opts = try buildOptions(options);
    defer c.rocksdb_options_destroy(opts);
    const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(path_z);

    var len: usize = 0;
    var err: [*c]u8 = null;
    const raw = c.rocksdb_list_column_families(opts, path_z.ptr, &len, &err);
    if (err != null) return consumeError(err);
    const list = raw orelse return error.Unknown;
    defer c.rocksdb_list_column_families_destroy(list, len);

    const result = allocator.alloc([]u8, len) catch return error.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |s| allocator.free(s);
        allocator.free(result);
    }
    for (0..len) |i| {
        const name = std.mem.span(list[i]);
        result[i] = allocator.dupe(u8, name) catch return error.OutOfMemory;
        filled += 1;
    }
    return result;
}

pub fn freeColumnFamilyNames(allocator: Allocator, names: [][]u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

fn buildOptions(o: Options) Error!*c.rocksdb_options_t {
    const opts = c.rocksdb_options_create() orelse return error.OutOfMemory;
    c.rocksdb_options_set_create_if_missing(opts, if (o.create_if_missing) 1 else 0);
    c.rocksdb_options_set_create_missing_column_families(opts, if (o.create_missing_column_families) 1 else 0);
    c.rocksdb_options_set_compression(opts, @intFromEnum(o.compression));
    if (o.write_buffer_size) |w| c.rocksdb_options_set_write_buffer_size(opts, w);
    if (o.max_open_files) |m| c.rocksdb_options_set_max_open_files(opts, m);
    return opts;
}

fn consumeError(errptr: [*c]u8) Error {
    const e = classify(std.mem.span(errptr));
    c.rocksdb_free(@ptrCast(errptr));
    return e;
}

fn classify(msg: []const u8) Error {
    const sw = std.mem.startsWith;
    if (sw(u8, msg, "NotFound")) return error.NotFound;
    if (sw(u8, msg, "Corruption")) return error.Corruption;
    if (sw(u8, msg, "Not implemented")) return error.NotSupported;
    if (sw(u8, msg, "Invalid argument")) return error.InvalidArgument;
    if (sw(u8, msg, "IO error")) return error.IoError;
    if (sw(u8, msg, "Merge in progress")) return error.MergeInProgress;
    if (sw(u8, msg, "Result incomplete")) return error.Incomplete;
    if (sw(u8, msg, "Shutdown in progress")) return error.ShutdownInProgress;
    if (sw(u8, msg, "Operation timed out")) return error.TimedOut;
    if (sw(u8, msg, "Operation aborted")) return error.Aborted;
    if (sw(u8, msg, "Resource busy")) return error.Busy;
    if (sw(u8, msg, "Operation expired")) return error.Expired;
    if (sw(u8, msg, "Operation failed. Try again")) return error.TryAgain;
    return error.Unknown;
}
