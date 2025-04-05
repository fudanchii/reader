map: std.StringHashMap(std.ArrayList([]const u8)),
allocator: std.mem.Allocator,

pub fn get(self: @This(), key: []const u8) ?std.ArrayList([]const u8) {
    return self.map.get(key);
}

pub fn set(self: *@This(), key: []const u8, value: []const u8) !void {
    return self.put(key, value);
}

pub fn put(self: *@This(), key: []const u8, value: []const u8) !void {
    const elt = self.map.get(key);
    var elt_val = if (elt != null) elt.? else std.ArrayList([]const u8).init(self.allocator);

    try elt_val.append(value);

    return self.map.put(key, elt_val);
}

pub fn deinit(self: *@This()) void {
    var iter = self.map.iterator();

    while (iter.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);

        for (entry.value_ptr.items) |elt| {
            self.allocator.free(elt);
        }

        entry.value_ptr.deinit();
    }

    return self.map.deinit();
}

pub const Scanner = struct {
    pub const scan_option: lib.ScanOption = .{
        .include_delimiter = false,
        .delimiter = "\r\n",
    };

    inner_scanner: ScannerWithDelimiter(scan_option),

    pub const Field = struct { []const u8, []const u8 };

    pub const err = error{ EndOfHeaderSequence, InvalidHeader, UnreadFWSLine };

    pub fn scanWithAllocator(self: *@This(), allocator: std.mem.Allocator) !Field {
        var str_line, var str_len = try self.inner_scanner.scan();

        defer str_line.deinit();

        if (str_len == 0) return err.EndOfHeaderSequence;

        const field_separator_position = std.mem.indexOf(u8, str_line.items[0..str_len], ":");

        if (field_separator_position == null) {
            if (isASCIIWhiteSpace(str_line.items[0])) return err.UnreadFWSLine;
            return err.InvalidHeader;
        }

        while (true) {
            const next_line_first_char = self.inner_scanner.peek(1) catch break;

            if (next_line_first_char.len == 1 and isASCIIWhiteSpace(next_line_first_char[0])) {
                const next_line, const next_line_len = self.inner_scanner.scan() catch break;

                defer next_line.deinit();

                str_line.appendSlice(next_line.items[0..next_line_len]) catch break;
                str_len += next_line_len;

                continue;
            }

            break;
        }

        var key = try allocator.alloc(u8, field_separator_position.?);
        @memcpy(key[0..field_separator_position.?], str_line.items[0..field_separator_position.?]);

        // Left trim spaces.
        var val_start_idx = field_separator_position.? + 1;
        while (isASCIIWhiteSpace(str_line.items[val_start_idx])) {
            val_start_idx += 1;
        }

        const val_len = str_len - (val_start_idx);
        var val = try allocator.alloc(u8, val_len);
        @memcpy(val[0..val_len], str_line.items[val_start_idx..str_len]);

        return .{ key, val };
    }
};

pub fn isASCIIWhiteSpace(char: u8) bool {
    return char == ' ' or char == '\t';
}

pub fn scanAllFromStream(reader: std.io.AnyReader, allocator: std.mem.Allocator) Header {
    const header_map = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    var scanner: Scanner = .{
        .inner_scanner = lib.scannerWithDelimiter(reader, allocator, Scanner.scan_option),
    };

    defer scanner.inner_scanner.deinit();

    var header_result: Header = .{ .map = header_map, .allocator = allocator };

    while (true) {
        const field = scanner.scanWithAllocator(allocator) catch break;

        header_result.put(field[0], field[1]) catch |err| {
            std.debug.print("put err: {}\n", .{err});
            break;
        };
    }

    return header_result;
}

const std = @import("std");
const lib = @import("./lib.zig");
const ScannerWithDelimiter = lib.ScannerWithDelimiter;
const Header = @This();

test "Header" {
    const gpa = std.testing.allocator;

    const input =
        \\MIME-Version: 1.0
        \\Date: Wed, 2 Apr 2025 14:15:19 +0900
        \\Content-Type: multipart/alternative; boundary="00000000000062617a0631c4bd41"
    ;

    const actual_input = try std.mem.replaceOwned(u8, gpa, input, "\n", "\r\n");

    defer gpa.free(actual_input);

    var input_buffer = std.io.fixedBufferStream(actual_input);

    var header = Header.scanAllFromStream(input_buffer.reader().any(), gpa);

    defer header.deinit();

    try std.testing.expectEqualStrings("1.0", header.get("MIME-Version").?.items[0]);
    try std.testing.expectEqualStrings("Wed, 2 Apr 2025 14:15:19 +0900", header.get("Date").?.items[0]);
    try std.testing.expectEqualStrings(
        "multipart/alternative; boundary=\"00000000000062617a0631c4bd41\"",
        header.get("Content-Type").?.items[0],
    );

    try std.testing.expectEqual(null, header.get("X-Hello"));
}

test "Header with multiline value" {
    const gpa = std.testing.allocator;

    const input =
        \\Content-Type: text/plain; size="1024909";
        \\ name="wololo.txt"
    ;

    const actual_input = try std.mem.replaceOwned(u8, gpa, input, "\n", "\r\n");

    defer gpa.free(actual_input);

    var input_buffer = std.io.fixedBufferStream(actual_input);

    var current_header = Header.scanAllFromStream(input_buffer.reader().any(), gpa);

    defer current_header.deinit();

    try std.testing.expectEqualStrings("text/plain; size=\"1024909\"; name=\"wololo.txt\"", current_header.get("Content-Type").?.items[0]);
}
