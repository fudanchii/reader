const std = @import("std");

pub const ScanOption = struct {
    include_delimiter: bool,
    delimiter: []const u8,

    // The size of buffer for each read from the stream source.
    read_buffer_size: usize = 256,
};

pub fn ScannerWithDelimiter(option: ScanOption) type {
    return struct {
        reader: std.io.AnyReader,
        buffer: std.ArrayList(u8),
        delimiter: []const u8 = option.delimiter,
        cursor: usize = 0,
        include_delimiter: bool = option.include_delimiter,
        allocator: std.mem.Allocator,

        comptime read_buffer_size: usize = option.read_buffer_size,

        pub const err = error{EndOfStream};
        pub const ScannedString = struct { std.ArrayList(u8), usize };

        pub fn scan(self: *@This()) !ScannedString {
            // If we have excess data from previous read
            if (self.cursor > 0) {
                return self.scanFromBuffer();
            }

            return self.scanFromStream();
        }

        inline fn scanFromBuffer(self: *@This()) !ScannedString {
            const linelen = std.mem.indexOf(u8, self.buffer.allocatedSlice()[0..self.cursor], self.delimiter);

            // We have another line at the previous excess read
            if (linelen != null and linelen.? >= 0) {
                var outlen = linelen.?;
                var outbuf = std.ArrayList(u8).init(self.allocator);

                if (self.include_delimiter) {
                    outlen = linelen.? + self.delimiter.len;
                }

                try outbuf.appendSlice(self.buffer.allocatedSlice()[0..outlen]);

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

                return .{ outbuf, outlen };
            }

            return self.scanFromStream();
        }

        inline fn scanFromStream(self: *@This()) !ScannedString {
            var innerbuffer: [self.read_buffer_size]u8 = [_]u8{0} ** self.read_buffer_size;

            const readlen = try self.reader.read(&innerbuffer);

            // If nothing read it's an eof
            if (readlen == 0) {
                // handle excess with no newline
                if (self.cursor > 0) {
                    var outbuf = std.ArrayList(u8).init(self.allocator);

                    try outbuf.appendSlice(self.buffer.allocatedSlice()[0..self.cursor]);

                    @memset(self.buffer.allocatedSlice()[0..self.cursor], 0);

                    defer self.cursor = 0;

                    return .{ outbuf, self.cursor };
                }

                return err.EndOfStream;
            }

            try self.buffer.appendSlice(innerbuffer[0..readlen]);

            self.cursor += readlen;

            const linelen = std.mem.indexOf(u8, self.buffer.allocatedSlice()[0..self.cursor], self.delimiter);

            // No delimiter found
            if (linelen == null) {
                return self.scan();
            }

            var outlen = linelen.?;
            var outbuf = std.ArrayList(u8).init(self.allocator);

            // delimiter found
            {
                if (self.include_delimiter) {
                    outlen = linelen.? + self.delimiter.len;
                }

                try outbuf.appendSlice(self.buffer.allocatedSlice()[0..outlen]);

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

            return .{ outbuf, outlen };
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
        .allocator = allocator,
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
        const testbuffer, const result_len = try line_scanner.scan();

        defer testbuffer.deinit();

        try testing.expectEqual(tc.len, result_len);
        try testing.expectEqualStrings(tc.line, testbuffer.allocatedSlice()[0..result_len]);
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
        const testbuffer, const result_len = try line_scanner.scan();

        defer testbuffer.deinit();

        try testing.expectEqual(tc.len, result_len);
        try testing.expectEqualStrings(tc.line, testbuffer.allocatedSlice()[0..result_len]);
    }
}
