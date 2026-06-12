const std = @import("std");

const vendor_include = "vendor/rocksdb-src/include";
const vendor_archive = "vendor/rocksdb-src/build/librocksdb.a";
const vendor_script = "vendor/build_rocksdb.sh";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_override = b.option(
        bool,
        "system-rocksdb",
        "Link against a system-installed librocksdb instead of the vendored build",
    );
    const use_system = system_override orelse detectSystemRocksDB();

    const vendor_cmd = b.addSystemCommand(&.{ "bash", vendor_script });
    vendor_cmd.setName("build vendored RocksDB");
    const vendor_step = b.step("vendor", "Download and compile RocksDB from source into vendor/");
    vendor_step.dependOn(&vendor_cmd.step);

    const link_vendor: ?*std.Build.Step = if (use_system) null else &vendor_cmd.step;

    const module = b.addModule("zrocks", .{
        .root_source_file = b.path("src/rocksdb.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureLink(b, module, use_system);

    const lib = b.addStaticLibrary(.{
        .name = "zrocks",
        .root_source_file = b.path("src/rocksdb.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureLink(b, &lib.root_module, use_system);
    if (link_vendor) |s| lib.step.dependOn(s);
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/rocksdb_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureLink(b, &tests.root_module, use_system);
    if (link_vendor) |s| tests.step.dependOn(s);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the zrocks test suite");
    test_step.dependOn(&run_tests.step);

    const example = b.addExecutable(.{
        .name = "zrocks-example",
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example.root_module.addImport("zrocks", module);
    if (link_vendor) |s| example.step.dependOn(s);
    const example_step = b.step("example", "Build the usage example");
    example_step.dependOn(&example.step);

    const run_example = b.addRunArtifact(example);
    const run_example_step = b.step("run-example", "Build and run the usage example");
    run_example_step.dependOn(&run_example.step);
}

fn configureLink(b: *std.Build, module: *std.Build.Module, use_system: bool) void {
    module.link_libc = true;
    if (use_system) {
        module.linkSystemLibrary("rocksdb", .{});
    } else {
        module.addIncludePath(b.path(vendor_include));
        module.addObjectFile(b.path(vendor_archive));
        module.linkSystemLibrary("lz4", .{});
        module.linkSystemLibrary("zstd", .{});
        module.linkSystemLibrary("z", .{});
        module.linkSystemLibrary("snappy", .{});
        module.linkSystemLibrary("bz2", .{});
    }
    linkCxxRuntime(b, module);
}

fn linkCxxRuntime(b: *std.Build, module: *std.Build.Module) void {
    addCompilerFile(b, module, "libstdc++.so");
    addCompilerFile(b, module, "libgcc_s.so.1");
}

fn addCompilerFile(b: *std.Build, module: *std.Build.Module, name: []const u8) void {
    const raw = b.run(&.{ "g++", b.fmt("-print-file-name={s}", .{name}) });
    const path = std.mem.trim(u8, raw, " \t\r\n");
    module.addObjectFile(.{ .cwd_relative = b.dupe(path) });
}

fn detectSystemRocksDB() bool {
    std.fs.accessAbsolute("/usr/include/rocksdb/c.h", .{}) catch return false;
    const candidates = [_][]const u8{
        "/usr/lib/x86_64-linux-gnu/librocksdb.so",
        "/usr/lib/x86_64-linux-gnu/librocksdb.a",
        "/usr/lib/librocksdb.so",
        "/usr/lib/librocksdb.a",
        "/usr/local/lib/librocksdb.so",
        "/usr/local/lib/librocksdb.a",
    };
    for (candidates) |path| {
        if (std.fs.accessAbsolute(path, .{})) |_| return true else |_| {}
    }
    return false;
}
