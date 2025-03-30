const std = @import("std");

const MAX_BUF_SIZE: usize = 100 * 1024 * 1024;

pub const ScanOption = struct {
    include_delimiter: bool,
    delimiter: []const u8,
};

pub fn ScannerWithDelimiter(option: ScanOption) type {
    return struct {
        reader: std.io.AnyReader,
        buffer: std.ArrayList(u8),
        delimiter: []const u8 = option.delimiter,
        cursor: usize = 0,
        include_delimiter: bool = option.include_delimiter,

        pub const err = error{ EndOfStream, OutOfMemory };

        pub fn scan(self: *@This(), outbuf: []u8) !usize {
            // If we have excess data from previous read
            if (self.cursor > 0) {
                return self.scanFromBuffer(outbuf);
            }

            return self.scanFromStream(outbuf);
        }

        inline fn scanFromBuffer(self: *@This(), outbuf: []u8) !usize {
            const linelen = std.mem.indexOf(u8, self.buffer.allocatedSlice()[0..self.cursor], self.delimiter);

            // We have another line at the previous excess read
            if (linelen != null and linelen.? >= 0) {
                var outlen = linelen.?;

                if (self.include_delimiter) {
                    outlen = linelen.? + self.delimiter.len;
                }

                @memcpy(outbuf[0..outlen], self.buffer.allocatedSlice()[0..outlen]);

                if (linelen.? + self.delimiter.len < self.cursor) {
                    std.mem.copyForwards(
                        u8,
                        self.buffer.allocatedSlice()[0 .. self.cursor - (linelen.? + self.delimiter.len)],
                        self.buffer.allocatedSlice()[linelen.? + self.delimiter.len .. self.cursor],
                    );
                }

                @memset(self.buffer.allocatedSlice()[self.cursor - (linelen.? + self.delimiter.len) .. self.buffer.capacity], 0);
                self.cursor -= linelen.? + self.delimiter.len;

                self.buffer.shrinkAndFree(self.cursor);

                return outlen;
            }

            return self.scanFromStream(outbuf);
        }

        inline fn scanFromStream(self: *@This(), outbuf: []u8) !usize {
            const innerbuffer_size = 256;

            var innerbuffer: [innerbuffer_size]u8 = [_]u8{0} ** innerbuffer_size;

            const readlen = try self.reader.read(&innerbuffer);

            // If nothing read it's an eof
            if (readlen == 0) {
                // handle excess with no newline
                if (self.cursor > 0) {
                    @memcpy(outbuf[0..self.cursor], self.buffer.allocatedSlice()[0..self.cursor]);
                    @memset(self.buffer.allocatedSlice()[0..self.cursor], 0);

                    defer self.cursor = 0;

                    return self.cursor;
                }

                return err.EndOfStream;
            }

            try self.buffer.appendSlice(innerbuffer[0..readlen]);

            self.cursor += readlen;

            const linelen = std.mem.indexOf(u8, self.buffer.allocatedSlice()[0..self.cursor], self.delimiter);

            // No delimiter found
            if (linelen == null) {
                return self.scan(outbuf);
            }

            var outlen = linelen.?;

            // delimiter found
            {
                if (self.include_delimiter) {
                    outlen = linelen.? + self.delimiter.len;
                }

                @memcpy(outbuf[0..outlen], self.buffer.allocatedSlice()[0..outlen]);

                if (linelen.? + self.delimiter.len < readlen) {
                    const excesspos = linelen.? + self.delimiter.len;
                    const excesslen = self.cursor - excesspos;

                    std.mem.copyForwards(
                        u8,
                        self.buffer.allocatedSlice()[0..excesslen],
                        self.buffer.allocatedSlice()[excesspos .. excesspos + excesslen],
                    );

                    @memset(self.buffer.allocatedSlice()[excesslen..self.cursor], 0);

                    self.cursor = excesslen;

                    self.buffer.shrinkAndFree(self.cursor);
                }
            }

            return outlen;
        }

        pub fn deinit(self: *@This()) void {
            self.buffer.deinit();
        }
    };
}

pub fn scannerWithDelimiter(reader: std.io.AnyReader, allocator: std.mem.Allocator, comptime option: ScanOption) ScannerWithDelimiter(option) {
    return .{
        .reader = reader,
        .buffer = std.ArrayList(u8).init(allocator),
    };
}

test "ReaderWithDelimiter scan exclude delimiter" {
    const testing = std.testing;

    var buffer_stream = std.io.fixedBufferStream("1\n22\n333\n4444\n\n1\n333\n22\n.");
    var line_scanner = scannerWithDelimiter(buffer_stream.reader().any(), std.testing.allocator, .{
        .delimiter = "\n",
        .include_delimiter = false,
    });

    defer line_scanner.deinit();

    const TestCaseType = struct {
        line: []const u8,
        len: usize,
    };

    const test_cases = [_]TestCaseType{
        .{ .line = "1", .len = 1 },
        .{ .line = "22", .len = 2 },
        .{ .line = "333", .len = 3 },
        .{ .line = "4444", .len = 4 },
        .{ .line = "", .len = 0 },
        .{ .line = "1", .len = 1 },
        .{ .line = "333", .len = 3 },
        .{ .line = "22", .len = 2 },
        .{ .line = ".", .len = 1 },
    };

    for (test_cases) |tc| {
        var testbuffer: [4]u8 = [_]u8{0} ** 4;
        const result = try line_scanner.scan(&testbuffer);

        try testing.expectEqual(tc.len, result);
        try testing.expectEqualStrings(tc.line, testbuffer[0..result]);
    }
}

test "ReaderWithDelimiter scan include delimiter" {
    const testing = std.testing;

    var buffer_stream = std.io.fixedBufferStream("1\r\n22\r\n333\r\n4444\r\n\r\n1\r\n333\r\n22\r\n.");
    var line_scanner = scannerWithDelimiter(buffer_stream.reader().any(), std.testing.allocator, .{
        .delimiter = "\r\n",
        .include_delimiter = true,
    });

    defer line_scanner.deinit();

    const TestCaseType = struct {
        line: []const u8,
        len: usize,
    };

    const test_cases = [_]TestCaseType{
        .{ .line = "1\r\n", .len = 3 },
        .{ .line = "22\r\n", .len = 4 },
        .{ .line = "333\r\n", .len = 5 },
        .{ .line = "4444\r\n", .len = 6 },
        .{ .line = "\r\n", .len = 2 },
        .{ .line = "1\r\n", .len = 3 },
        .{ .line = "333\r\n", .len = 5 },
        .{ .line = "22\r\n", .len = 4 },
        .{ .line = ".", .len = 1 },
    };

    for (test_cases) |tc| {
        var testbuffer: [9]u8 = [_]u8{0} ** 9;
        const result = try line_scanner.scan(&testbuffer);

        // try testing.expectEqual(tc.len, result);
        try testing.expectEqualStrings(tc.line, testbuffer[0..result]);
    }
}
