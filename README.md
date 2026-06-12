zrocks is a RocksDB binding for Zig 0.13 that wraps the official C API with typed errors, allocator-aware slices, and full column family support.

RocksDB is a C++ library, and linking C++ across toolchains is fragile: the GNU libstdc++ and LLVM libc++ ABIs are not interchangeable, so Zig's bundled libc++ does not match a g++-compiled RocksDB and the link fails with undefined symbols. zrocks avoids that by binding RocksDB's stable C API (`rocksdb/c.h`) through `@cImport`, and by linking the GNU C++ runtime (`libstdc++`, `libgcc_s`) that the vendored library was compiled against. On top of the raw C calls it adds an idiomatic Zig layer: every fallible function returns a typed error union, returned values are slices owned by a caller-supplied allocator, and every handle has an explicit deinit path.

## Requirements

- Zig 0.13.0
- RocksDB 9.7.4, vendored and built from source on the first build
- `cmake`, `g++`, and `curl` to configure and compile the vendored library
- Compression development libraries: snappy, zlib, bzip2, lz4, zstd

## Build

The vendored RocksDB static library is built first. This downloads RocksDB 9.7.4 and compiles it with CMake, and is only needed once:

```
zig build vendor
```

Then build the static library and run the tests:

```
zig build
zig build test
```

By default zrocks builds and links the vendored RocksDB. If `rocksdb/c.h` and a `librocksdb` are present in standard system locations they are detected and used automatically. Pass `-Dsystem-rocksdb=true` to force system linking, or `-Dsystem-rocksdb=false` to force the vendored build.

## API

All public entry points are in `src/rocksdb.zig`.

### DB open / close / options

- `DB.open(allocator, path, Options)` opens or creates a database.
- `DB.openColumnFamilies(allocator, path, Options, descriptors, out_handles)` opens a database with a known set of column families and fills `out_handles`.
- `DB.close()` closes the database and frees its default read and write options.
- `Options`: `create_if_missing`, `create_missing_column_families`, `compression`, `write_buffer_size`, `max_open_files`.
- `Compression`: `none`, `snappy`, `zlib`, `bz2`, `lz4`, `lz4hc`, `xpress`, `zstd`.

### Point operations

- `DB.put`, `DB.get`, `DB.delete`, and the column family variants `putCf`, `getCf`, `deleteCf`.
- `get` and `getCf` return an allocator-owned `?[]u8` that is null when the key is absent; the caller frees it.
- `DB.multiGet(allocator, keys)` returns `[]?[]u8`, one slot per key; free it with `DB.freeMultiGet`.

### WriteBatch

- `WriteBatch.init`, `deinit`, `put`, `putCf`, `delete`, `deleteCf`, `clear`, `count`.
- `DB.write(batch)` commits the batch atomically.

### Iterator

- `DB.iterator()`, `DB.iteratorOpt(ReadOptions)`, and `DB.iteratorCf(cf)` create iterators.
- `Iterator`: `seekToFirst`, `seekToLast`, `seek`, `seekForPrev`, `next`, `prev`, `valid`, `key`, `value`, `status`, `deinit`.
- `key` and `value` return borrowed slices valid only until the next iterator movement.

### Column families

- `DB.createColumnFamily(allocator, name, Options)` and `DB.dropColumnFamily(cf)`.
- `listColumnFamilies(allocator, path, Options)` returns the column family names; free them with `freeColumnFamilyNames`.
- `CfDescriptor` pairs a name with `Options`; `ColumnFamily.deinit` destroys a handle.

### Snapshot

- `DB.createSnapshot()` and `DB.releaseSnapshot(snapshot)`.
- `ReadOptions.init`, `deinit`, `setSnapshot`, then `DB.getOpt` or `DB.iteratorOpt` for a consistent read.

### Compaction

- `DB.compactRange(start, limit)` and `DB.compactRangeCf(cf, start, limit)`; null bounds mean open ended.

### Error handling

- Every fallible call returns `Error`, a union of `NotFound`, `Corruption`, `NotSupported`, `InvalidArgument`, `IoError`, `MergeInProgress`, `Incomplete`, `ShutdownInProgress`, `TimedOut`, `Aborted`, `Busy`, `Expired`, `TryAgain`, `Unknown`, and `OutOfMemory`.
- RocksDB reports failures as `char*` strings. zrocks classifies each one into the matching `Error` and frees the string immediately, so no failure is silent and no error memory leaks.

## Tests

The suite in `src/rocksdb_test.zig` has 13 tests covering:

- open and close roundtrip, including reopen
- put then get, delete then get returns null, and missing key returns null
- `multiGet` batch lookup with a missing key in the middle
- `WriteBatch` atomicity across put and delete
- iterator forward scan in key order
- iterator seek, `seekToLast`, and prev
- column family full lifecycle: create, write, read, list, reopen with descriptors, drop
- snapshot isolation of reads from later writes
- manual compaction smoke test
- Snappy and bzip2 compression roundtrips that write, compact to SST, and read back

All 13 tests pass in Debug, ReleaseSafe, and ReleaseFast.

## License

MIT License.
