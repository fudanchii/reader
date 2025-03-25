const std = @import("std");

const BUF_SIZE: usize = 1024;

pub const ReaderOption = struct {
    bufSize: usize = BUF_SIZE,
    includeDelimiter: bool,
    delimiter: []const u8,
};

pub fn ReaderWithDelimiter(option: ReaderOption) type {
    return struct {
        reader: std.io.AnyReader,
        buffer: [option.bufSize]u8 = [_]u8{0} ** option.bufSize,
        delimiter: []const u8 = option.delimiter,
        cursor: usize = 0,
        includeDelimiter: bool = option.includeDelimiter,

        pub const err = error{ EndOfStream, OutOfMemory };

        pub fn read(self: *@This(), outbuf: []u8) !usize {
            var innerbuffer: [self.buffer.len]u8 = [_]u8{0} ** self.buffer.len;

            // If we have excess data from previous read
            if (self.cursor > 0) {
                const linelen = std.mem.indexOf(u8, self.buffer[0..self.cursor], self.delimiter);

                // We have another line at the previous excess read
                if (linelen != null and linelen.? >= 0) {
                    @memcpy(outbuf[0..linelen.?], self.buffer[0..linelen.?]);

                    if (linelen.? + self.delimiter.len < self.cursor) {
                        std.mem.copyForwards(
                            u8,
                            self.buffer[0 .. self.cursor - (linelen.? + self.delimiter.len)],
                            self.buffer[linelen.? + self.delimiter.len .. self.cursor],
                        );
                    }

                    @memset(self.buffer[self.cursor - (linelen.? + self.delimiter.len) .. self.buffer.len], 0);
                    self.cursor -= linelen.? + self.delimiter.len;

                    return linelen.?;
                }
            }

            const readlen = try self.reader.read(&innerbuffer);

            // If nothing read it's an eof
            if (readlen == 0) {
                // handle excess with no newline
                if (self.cursor > 0) {
                    @memcpy(outbuf[0..self.cursor], self.buffer[0..self.cursor]);
                    @memset(self.buffer[0..self.cursor], 0);

                    defer self.cursor = 0;

                    return self.cursor;
                }

                return err.EndOfStream;
            }

            const linelen = std.mem.indexOf(u8, &innerbuffer, self.delimiter);

            // No delimiter found
            if (linelen == null) {
                // If buffer was full with previous excess, return error
                if (self.cursor == self.buffer.len or self.cursor + readlen > self.buffer.len) {
                    return err.OutOfMemory;
                }

                @memcpy(self.buffer[self.cursor .. self.cursor + readlen], innerbuffer[0..readlen]);

                self.cursor += readlen;

                return self.read(outbuf);
            }

            var pos: usize = 0;

            // delimiter found
            {
                // prepend previous excess
                if (self.cursor > 0) {
                    @memcpy(outbuf[0..self.cursor], self.buffer[0..self.cursor]);
                    @memset(self.buffer[0..self.cursor], 0);
                    pos = self.cursor;
                    self.cursor = 0;
                }

                const linelenval = linelen.?;
                @memcpy(outbuf[pos .. pos + linelenval], innerbuffer[0..linelenval]);

                if (linelenval + self.delimiter.len < readlen) {
                    const excesspos = linelenval + self.delimiter.len;
                    const excesslen = readlen - excesspos;

                    @memcpy(self.buffer[self.cursor .. self.cursor + excesslen], innerbuffer[excesspos..readlen]);
                    self.cursor += excesslen;
                }
            }

            return pos + linelen.?;
        }
    };
}

pub fn readerWithDelimiter(reader: std.io.AnyReader, comptime option: ReaderOption) ReaderWithDelimiter(option) {
    return .{ .reader = reader };
}

test "ReaderWithDelimiter" {
    const testing = std.testing;

    var bufferStream = std.io.fixedBufferStream("1\n22\n333\n4444\n\n1\n333\n22\n");
    var linereader = readerWithDelimiter(bufferStream.reader().any(), .{
        .bufSize = 4,
        .delimiter = "\n",
        .includeDelimiter = false,
    });

    const TestCaseType = struct {
        line: []const u8,
        len: usize,
    };

    const testCases = [_]TestCaseType{
        .{ .line = "1", .len = 1 },
        .{ .line = "22", .len = 2 },
        .{ .line = "333", .len = 3 },
        .{ .line = "4444", .len = 4 },
        .{ .line = "", .len = 0 },
        .{ .line = "1", .len = 1 },
        .{ .line = "333", .len = 3 },
        .{ .line = "22", .len = 2 },
    };

    for (testCases) |tc| {
        var testbuffer: [4]u8 = [_]u8{0} ** 4;
        const result = try linereader.read(&testbuffer);

        try testing.expectEqual(tc.len, result);
        try testing.expectEqualStrings(tc.line, testbuffer[0..result]);
    }
}
