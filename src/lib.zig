const std = @import("std");

pub const IncludeDelimiterOption = struct {
    includeDelimiter: bool,
};

pub fn ReaderWithDelimiter(bufsize: usize) type {
    return struct {
        reader: std.io.AnyReader,
        buffer: [bufsize]u8,
        delimiter: []const u8,
        cursor: usize = 0,

        pub const err = error{ EndOfStream, OutOfMemory };

        pub fn read(self: *@This(), outbuf: []u8) !usize {
            var innerbuffer: [self.buffer.len]u8 = [_]u8{0} ** self.buffer.len;

            // If we have excess data from previous read
            if (self.cursor > 0) {
                const linelen = std.mem.indexOf(u8, self.buffer[0..self.cursor], self.delimiter);

                // We have another line at the previous excess read
                if (linelen != null and linelen.? > 0) {
                    @memcpy(outbuf[0..linelen.?], self.buffer[0..linelen.?]);

                    if (linelen.? < self.cursor) {
                        @memcpy(self.buffer[0 .. self.cursor - linelen.?], self.buffer[linelen.?..self.cursor]);
                        @memset(self.buffer[self.cursor - linelen.? .. self.buffer.len], 0);
                        self.cursor -= linelen.?;
                    }

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

pub fn readerWithDelimiter(reader: std.io.AnyReader, lineDelimiter: []const u8, comptime bufsize: usize) ReaderWithDelimiter(bufsize) {
    return .{
        .reader = reader,
        .delimiter = lineDelimiter,
        .buffer = [_]u8{0} ** bufsize,
    };
}

test "ReaderWithDelimiter" {
    const testing = std.testing;

    var bufferStream = std.io.fixedBufferStream("1\n22\n333\n4444");
    var linereader: ReaderWithDelimiter(4) = readerWithDelimiter(bufferStream.reader().any(), "\n", 4);

    {
        var testbuffer: [4]u8 = [_]u8{0} ** 4;
        const result = try linereader.read(&testbuffer);

        try testing.expectEqual(1, result);
        try testing.expectEqualStrings("1", testbuffer[0..result]);
    }

    {
        var testbuffer: [4]u8 = [_]u8{0} ** 4;
        const result = try linereader.read(&testbuffer);

        try testing.expectEqual(2, result);
        try testing.expectEqualStrings("22", testbuffer[0..result]);
    }

    {
        var testbuffer: [4]u8 = [_]u8{0} ** 4;
        const result = try linereader.read(&testbuffer);

        try testing.expectEqual(3, result);
        try testing.expectEqualStrings("333", testbuffer[0..result]);
    }

    {
        var testbuffer: [4]u8 = [_]u8{0} ** 4;
        const result = try linereader.read(&testbuffer);

        try testing.expectEqual(4, result);
        try testing.expectEqualStrings("4444", testbuffer[0..result]);
    }
}
