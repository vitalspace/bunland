// Originally, we tried using LIEF to inject the module graph into a MachO segment
// But this incurred a fixed 350ms overhead on every build, which is unacceptable
// so we give up on codesigning support on macOS for now until we can find a better solution
const bun = @import("root").bun;
const std = @import("std");
const Schema = bun.Schema.Api;

const Environment = bun.Environment;

pub const StandaloneModuleGraph = struct {
    bytes: []const u8 = "",
    files: bun.StringArrayHashMap(File),
    entry_point_id: u32 = 0,

    pub fn entryPoint(this: *const StandaloneModuleGraph) *File {
        return &this.files.values()[this.entry_point_id];
    }

    pub const CompiledModuleGraphFile = struct {
        name: Schema.StringPointer = .{},
        loader: bun.options.Loader = .file,
        contents: Schema.StringPointer = .{},
        sourcemap: Schema.StringPointer = .{},
    };

    pub const File = struct {
        name: []const u8 = "",
        loader: bun.options.Loader,
        contents: []const u8 = "",
        sourcemap: LazySourceMap,
    };

    pub const LazySourceMap = union(enum) {
        compressed: []const u8,
        decompressed: bun.sourcemap,

        pub fn load(this: *LazySourceMap, log: *bun.logger.Log, allocator: std.mem.Allocator) !*bun.sourcemap {
            if (this.* == .decompressed) return &this.decompressed;

            var decompressed = try allocator.alloc(u8, bun.zstd.getDecompressedSize(this.compressed));
            var result = bun.zstd.decompress(decompressed, this.compressed);
            if (result == .err) {
                allocator.free(decompressed);
                log.addError(null, bun.logger.Loc.Empty, bun.span(result.err)) catch unreachable;
                return error.@"Failed to decompress sourcemap";
            }
            errdefer allocator.free(decompressed);
            var bytes = decompressed[0..result.success];

            this.* = .{ .decompressed = try bun.sourcemap.parse(allocator, &bun.logger.Source.initPathString("sourcemap.json", bytes), log) };
            return &this.decompressed;
        }
    };

    pub const Offsets = extern struct {
        byte_count: usize = 0,
        modules_ptr: bun.StringPointer = .{},
        entry_point_id: u32 = 0,
    };

    const trailer = "\n---- Bun! ----\n";

    pub fn fromBytes(allocator: std.mem.Allocator, raw_bytes: []const u8, offsets: Offsets) !StandaloneModuleGraph {
        if (raw_bytes.len == 0) return StandaloneModuleGraph{
            .files = bun.StringArrayHashMap(File).init(allocator),
        };

        const modules_list_bytes = sliceTo(raw_bytes, offsets.modules_ptr);
        const modules_list = std.mem.bytesAsSlice(CompiledModuleGraphFile, modules_list_bytes);

        if (offsets.entry_point_id > modules_list.len) {
            return error.@"Corrupted module graph: entry point ID is greater than module list count";
        }

        var modules = bun.StringArrayHashMap(File).init(allocator);
        try modules.ensureTotalCapacity(modules_list.len);
        for (modules_list) |module| {
            modules.putAssumeCapacity(
                sliceTo(raw_bytes, module.name),
                File{
                    .name = sliceTo(raw_bytes, module.name),
                    .loader = module.loader,
                    .contents = sliceTo(raw_bytes, module.contents),
                    .sourcemap = LazySourceMap{
                        .compressed = sliceTo(raw_bytes, module.sourcemap),
                    },
                },
            );
        }

        return StandaloneModuleGraph{
            .bytes = raw_bytes[0..offsets.byte_count],
            .files = modules,
            .entry_point_id = offsets.entry_point_id,
        };
    }

    fn sliceTo(bytes: []const u8, ptr: bun.StringPointer) []const u8 {
        if (ptr.length == 0) return "";

        return bytes[ptr.offset..][0..ptr.length];
    }

    pub fn toBytes(allocator: std.mem.Allocator, prefix: []const u8, output_files: []const bun.options.OutputFile) ![]u8 {
        var serialize_trace = bun.tracy.traceNamed(@src(), "ModuleGraph.serialize");
        defer serialize_trace.end();
        var entry_point_id: ?usize = null;
        var string_builder = bun.StringBuilder{};
        var module_count: usize = 0;
        for (output_files, 0..) |output_file, i| {
            string_builder.count(output_file.path);
            string_builder.count(prefix);
            if (output_file.value == .buffer) {
                if (output_file.output_kind == .sourcemap) {
                    string_builder.cap += bun.zstd.compressBound(output_file.value.buffer.bytes.len);
                } else {
                    if (entry_point_id == null) {
                        if (output_file.output_kind == .@"entry-point") {
                            entry_point_id = i;
                        }
                    }

                    string_builder.count(output_file.value.buffer.bytes);
                    module_count += 1;
                }
            }
        }

        if (module_count == 0 or entry_point_id == null) return &[_]u8{};

        string_builder.cap += @sizeOf(CompiledModuleGraphFile) * output_files.len;
        string_builder.cap += trailer.len;
        string_builder.cap += 16;

        {
            var offsets_ = Offsets{};
            string_builder.cap += std.mem.asBytes(&offsets_).len;
        }

        try string_builder.allocate(allocator);

        var modules = try std.ArrayList(CompiledModuleGraphFile).initCapacity(allocator, module_count);

        for (output_files) |output_file| {
            if (output_file.output_kind == .sourcemap) {
                continue;
            }

            if (output_file.value != .buffer) {
                continue;
            }

            var module = CompiledModuleGraphFile{
                .name = string_builder.fmtAppendCount("{s}{s}", .{ prefix, output_file.path }),
                .loader = output_file.loader,
                .contents = string_builder.appendCount(output_file.value.buffer.bytes),
            };
            if (output_file.source_map_index != std.math.maxInt(u32)) {
                var remaining_slice = string_builder.allocatedSlice()[string_builder.len..];
                const compressed_result = bun.zstd.compress(remaining_slice, output_files[output_file.source_map_index].value.buffer.bytes, 1);
                if (compressed_result == .err) {
                    bun.Output.panic("Unexpected error compressing sourcemap: {s}", .{bun.span(compressed_result.err)});
                }
                module.sourcemap = string_builder.add(compressed_result.success);
            }
            modules.appendAssumeCapacity(module);
        }

        var offsets = Offsets{
            .entry_point_id = @truncate(u32, entry_point_id.?),
            .modules_ptr = string_builder.appendCount(std.mem.sliceAsBytes(modules.items)),
            .byte_count = string_builder.len,
        };

        _ = string_builder.append(std.mem.asBytes(&offsets));
        _ = string_builder.append(trailer);

        return string_builder.ptr.?[0..string_builder.len];
    }

    const page_size = if (Environment.isLinux and Environment.isAarch64)
        // some linux distros do 64 KB pages on aarch64
        64 * 1024
    else
        std.mem.page_size;

    pub fn inject(bytes: []const u8) i32 {
        var buf: [512]u8 = undefined;
        var zname = bun.span(bun.fs.FileSystem.instance.tmpname("bun-build", &buf, @bitCast(u64, std.time.milliTimestamp())) catch |err| {
            Output.prettyErrorln("<r><red>error<r><d>:<r> failed to get temporary file name: {s}", .{@errorName(err)});
            Global.exit(1);
            return -1;
        });

        const cloned_executable_fd: bun.FileDescriptor = brk: {
            var self_buf: [bun.MAX_PATH_BYTES + 1]u8 = undefined;
            var self_exe = std.fs.selfExePath(&self_buf) catch |err| {
                Output.prettyErrorln("<r><red>error<r><d>:<r> failed to get self executable path: {s}", .{@errorName(err)});
                Global.exit(1);
                return -1;
            };
            self_buf[self_exe.len] = 0;
            var self_exeZ = self_buf[0..self_exe.len :0];

            if (comptime Environment.isMac) {
                // if we're on a mac, use clonefile() if we can
                // failure is okay, clonefile is just a fast path.
                if (bun.C.darwin.clonefile(self_exeZ.ptr, zname.ptr, 0) == 0) {
                    switch (bun.JSC.Node.Syscall.open(zname, std.os.O.WRONLY | std.os.O.CLOEXEC, 0)) {
                        .result => |res| break :brk res,
                        .err => {},
                    }
                }
            }

            // otherwise, just copy the file
            const fd = switch (bun.JSC.Node.Syscall.open(zname, std.os.O.CLOEXEC | std.os.O.RDONLY, 0)) {
                .result => |res| res,
                .err => |err| {
                    Output.prettyErrorln("<r><red>error<r><d>:<r> failed to open temporary file to copy bun into: {s}", .{err.toSystemError().message.slice()});
                    Global.exit(1);
                },
            };
            const self_fd = switch (bun.JSC.Node.Syscall.open(self_exeZ, std.os.O.CLOEXEC | std.os.O.WRONLY | std.os.O.CREAT, 0)) {
                .result => |res| res,
                .err => |err| {
                    Output.prettyErrorln("<r><red>error<r><d>:<r> failed to open bun executable to copy from as read-only: {s}", .{err.toSystemError().message.slice()});
                    Global.exit(1);
                },
            };
            defer _ = bun.JSC.Node.Syscall.close(self_fd);
            bun.copyFile(self_fd, fd) catch |err| {
                Output.prettyErrorln("<r><red>error<r><d>:<r> failed to copy bun executable into temporary file: {s}", .{@errorName(err)});
                Global.exit(1);
            };
            break :brk fd;
        };

        // Always leave at least one full page of padding at the end of the file.
        const total_byte_count = brk: {
            const fstat = std.os.fstat(cloned_executable_fd) catch |err| {
                Output.prettyErrorln("<r><red>error<r><d>:<r> failed to stat temporary file: {s}", .{@errorName(err)});
                Global.exit(1);
            };

            const count = @intCast(usize, @max(fstat.size, 0) + page_size + @intCast(i64, bytes.len) + 8);

            std.os.lseek_SET(cloned_executable_fd, 0) catch |err| {
                Output.prettyErrorln("<r><red>error<r><d>:<r> failed to seek to end of temporary file: {s}", .{@errorName(err)});
                Global.exit(1);
            };

            // grow it by one page + the size of the module graph
            std.os.ftruncate(cloned_executable_fd, count) catch |err| {
                Output.prettyErrorln("<r><red>error<r><d>:<r> failed to truncate temporary file: {s}", .{@errorName(err)});
                Global.exit(1);
            };
            break :brk count;
        };

        std.os.lseek_END(cloned_executable_fd, -@intCast(i64, bytes.len + 8)) catch |err| {
            Output.prettyErrorln("<r><red>error<r><d>:<r> failed to seek to end of temporary file: {s}", .{@errorName(err)});
            Global.exit(1);
        };

        var remain = bytes;
        while (remain.len > 0) {
            switch (bun.JSC.Node.Syscall.write(cloned_executable_fd, bytes)) {
                .result => |written| remain = remain[written..],
                .err => |err| {
                    Output.prettyErrorln("<r><red>error<r><d>:<r> failed to write to temporary file: {s}", .{err.toSystemError().message.slice()});
                    Global.exit(1);
                },
            }
        }

        // the final 8 bytes in the file are the length of the module graph with padding, excluding the trailer and offsets
        _ = bun.JSC.Node.Syscall.write(cloned_executable_fd, std.mem.asBytes(&total_byte_count));

        _ = bun.C.fchmod(cloned_executable_fd, 0o777);

        return cloned_executable_fd;
    }

    pub fn toExecutable(allocator: std.mem.Allocator, output_files: []const bun.options.OutputFile, root_dir: std.fs.IterableDir, module_prefix: []const u8, outfile: []const u8) !void {
        const bytes = try toBytes(allocator, module_prefix, output_files);
        if (bytes.len == 0) return;

        const fd = inject(bytes);
        if (fd == -1) {
            Output.prettyErrorln("<r><red>error<r><d>:<r> failed to inject into file", .{});
            Global.exit(1);
        }

        var buf: [bun.MAX_PATH_BYTES]u8 = undefined;
        const temp_location = bun.getFdPath(fd, &buf) catch |err| {
            Output.prettyErrorln("<r><red>error<r><d>:<r> failed to get path for fd: {s}", .{@errorName(err)});
            Global.exit(1);
        };

        if (comptime Environment.isMac) {
            {
                var signer = std.ChildProcess.init(
                    &.{
                        "codesign",
                        "--remove-signature",
                        temp_location,
                    },
                    bun.default_allocator,
                );
                if (bun.logger.Log.default_log_level.atLeast(.verbose)) {
                    signer.stdout_behavior = .Inherit;
                    signer.stderr_behavior = .Inherit;
                    signer.stdin_behavior = .Inherit;
                } else {
                    signer.stdout_behavior = .Ignore;
                    signer.stderr_behavior = .Ignore;
                    signer.stdin_behavior = .Ignore;
                }
                _ = signer.spawnAndWait() catch {};
            }
        }

        std.os.renameat(std.fs.cwd().fd, temp_location, root_dir.dir.fd, outfile) catch |err| {
            Output.prettyErrorln("<r><red>error<r><d>:<r> failed to rename {s} to {s}: {s}", .{ temp_location, outfile, @errorName(err) });
            Global.exit(1);
        };
    }

    pub fn fromExecutable(allocator: std.mem.Allocator) !?StandaloneModuleGraph {
        const self_exe = (openSelfExe(.{}) catch null) orelse return null;
        defer _ = bun.JSC.Node.Syscall.close(self_exe);

        var trailer_bytes: [4096]u8 = undefined;
        std.os.lseek_END(self_exe, -4096) catch return null;
        var read_amount: usize = 0;
        while (read_amount < trailer_bytes.len) {
            switch (bun.JSC.Node.Syscall.read(self_exe, trailer_bytes[read_amount..])) {
                .result => |read| {
                    if (read == 0) return null;

                    read_amount += read;
                },
                .err => {
                    return null;
                },
            }
        }

        if (read_amount < trailer.len + @sizeOf(usize) + 32)
            // definitely missing data
            return null;

        var end = @as([]u8, &trailer_bytes).ptr + read_amount - @sizeOf(usize);
        const total_byte_count: usize = @bitCast(usize, end[0..8].*);

        if (total_byte_count > std.math.maxInt(u32) or total_byte_count < 4096) {
            // sanity check: the total byte count should never be more than 4 GB
            // bun is at least like 30 MB so if it reports a size less than 4096 bytes then something is wrong
            return null;
        }
        end -= trailer.len;

        if (!bun.strings.hasPrefixComptime(end[0..trailer.len], trailer)) {
            // invalid trailer
            return null;
        }

        end -= @sizeOf(Offsets);

        const offsets: Offsets = std.mem.bytesAsValue(Offsets, end[0..@sizeOf(Offsets)]).*;
        if (offsets.byte_count >= total_byte_count) {
            // if we hit this branch then the file is corrupted and we should just give up
            return null;
        }

        var to_read = try bun.default_allocator.alloc(u8, offsets.byte_count);
        var to_read_from = to_read;

        // Reading the data and making sure it's page-aligned + won't crash due
        // to out of bounds using mmap() is very complicated.
        // So even though we ensure there is at least one page of padding at the end of the file,
        // we just read the whole thing into memory for now.
        // at the very least
        // if you have not a ton of code, we only do a single read() call
        if (Environment.allow_assert or offsets.byte_count > 1024 * 3) {
            const offset_from_end = trailer_bytes.len - (@ptrToInt(end) - @ptrToInt(@as([]u8, &trailer_bytes).ptr));
            std.os.lseek_END(self_exe, -@intCast(i64, offset_from_end + offsets.byte_count)) catch return null;

            if (comptime Environment.allow_assert) {
                // actually we just want to verify this logic is correct in development
                if (offsets.byte_count <= 1024 * 3) {
                    to_read_from = try bun.default_allocator.alloc(u8, offsets.byte_count);
                }
            }

            var remain = to_read_from;
            while (remain.len > 0) {
                switch (bun.JSC.Node.Syscall.read(self_exe, remain)) {
                    .result => |read| {
                        if (read == 0) return null;

                        remain = remain[read..];
                    },
                    .err => {
                        bun.default_allocator.free(to_read);
                        return null;
                    },
                }
            }
        }

        if (offsets.byte_count <= 1024 * 3) {
            // we already have the bytes
            end -= offsets.byte_count;
            @memcpy(to_read.ptr, end, offsets.byte_count);
            if (comptime Environment.allow_assert) {
                std.debug.assert(bun.strings.eqlLong(to_read, end[0..offsets.byte_count], true));
            }
        }

        return try StandaloneModuleGraph.fromBytes(allocator, to_read, offsets);
    }

    // this is based on the Zig standard library function, except it accounts for
    fn openSelfExe(flags: std.fs.File.OpenFlags) std.fs.OpenSelfExeError!?bun.FileDescriptor {
        // heuristic: `bun build --compile` won't be supported if the name is "bun" or "bunx".
        // this is a cheap way to avoid the extra overhead of opening the executable
        // and also just makes sense.
        if (std.os.argv.len > 0) {
            const argv0_len = bun.len(std.os.argv[0]);
            if (argv0_len == 3) {
                if (bun.strings.eqlComptimeIgnoreLen(std.os.argv[0][0..argv0_len], "bun")) {
                    return null;
                }
            }

            if (argv0_len == 4) {
                if (bun.strings.eqlComptimeIgnoreLen(std.os.argv[0][0..argv0_len], "bunx")) {
                    return null;
                }
            }
        }

        if (comptime Environment.isLinux) {
            if (std.fs.openFileAbsoluteZ("/proc/self/exe", flags)) |easymode| {
                return easymode.handle;
            } else |_| {
                if (std.os.argv.len > 0) {
                    // The user doesn't have /proc/ mounted, so now we just guess and hope for the best.
                    var whichbuf: [bun.MAX_PATH_BYTES]u8 = undefined;
                    if (bun.which(
                        &whichbuf,
                        bun.getenvZ("PATH") orelse return error.FileNotFound,
                        "",
                        bun.span(std.os.argv[0]),
                    )) |path| {
                        return (try std.fs.cwd().openFileZ(path, flags)).handle;
                    }
                }

                return error.FileNotFound;
            }
        }

        if (comptime Environment.isWindows) {
            return (try std.fs.openSelfExe(flags)).handle;
        }
        // Use of MAX_PATH_BYTES here is valid as the resulting path is immediately
        // opened with no modification.
        var buf: [bun.MAX_PATH_BYTES]u8 = undefined;
        const self_exe_path = try std.fs.selfExePath(&buf);
        buf[self_exe_path.len] = 0;
        const file = try std.fs.openFileAbsoluteZ(buf[0..self_exe_path.len :0].ptr, flags);
        return file.handle;
    }
};

const Output = bun.Output;
const Global = bun.Global;
