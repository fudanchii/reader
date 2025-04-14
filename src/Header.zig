map: std.StringHashMap(std.ArrayList(HeaderFieldValue)),
allocator: std.mem.Allocator,

pub const HeaderFieldValue = struct {
    unstructured: []const u8,
    structured: ?std.StringHashMap([]const u8) = null,

    const structure_fields_separator = ";";
    const structure_keyval_separator = "=";
    const err = error{NotAStructuredField};

    fn captureKeyValue(self: *@This(), idx: u8, start_field: usize, end_field: usize) !void {
        const key_len = std.mem.indexOf(u8, self.unstructured[start_field..end_field], structure_keyval_separator);

        var key: []const u8 = &[_]u8{idx};
        var start_val: usize = undefined;

        if (key_len == null) {
            start_val = start_field;
        } else {
            key = self.unstructured[start_field .. start_field + key_len.?];
            start_val = start_field + key_len.? + 1;
        }

        try self.structured.?.put(key, self.unstructured[start_val..end_field]);
    }

    pub fn asStructured(self: *@This(), allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
        if (self.structured != null) return self.structured.?;

        if (std.mem.indexOf(u8, self.unstructured, structure_keyval_separator) == null) {
            return err.NotAStructuredField;
        }

        self.structured = std.StringHashMap([]const u8).init(allocator);

        var start_field: usize = 0;
        var idx: u8 = 0;
        while (std.mem.indexOf(u8, self.unstructured[start_field..self.unstructured.len], structure_fields_separator)) |cursor| {
            const end_field = start_field + cursor;

            try self.captureKeyValue(idx, start_field, end_field);

            idx += 1;

            var skip_count: usize = 1;
            while (end_field + skip_count < self.unstructured.len) {
                if (isASCIIWhiteSpace(self.unstructured[end_field + skip_count])) skip_count += 1 else break;
            }

            start_field = end_field + skip_count;
        } else if (start_field < self.unstructured.len) {
            try self.captureKeyValue(idx, start_field, self.unstructured.len);
        }

        return self.structured.?;
    }

    pub fn deinit(self: *@This()) void {
        if (self.structured != null) {
            var iter = self.structured.?.iterator();

            // we're not freeing the key value here since it's just a slice over
            // unstructured data.
            while (iter.next()) |entry| {
                entry.key_ptr.* = undefined;
                entry.value_ptr.* = undefined;
            }

            self.structured.?.deinit();

            self.structured = null;
        }
    }
};

pub fn get(self: @This(), key: []const u8) ?std.ArrayList(HeaderFieldValue) {
    return self.map.get(key);
}

pub fn set(self: *@This(), key: []const u8, value: HeaderFieldValue) !void {
    return self.put(key, value);
}

pub fn put(self: *@This(), key: []const u8, value: HeaderFieldValue) !void {
    const elt = self.map.get(key);
    var elt_val = if (elt != null) elt.? else std.ArrayList(HeaderFieldValue).init(self.allocator);

    try elt_val.append(value);

    return self.map.put(key, elt_val);
}

pub fn deinit(self: *@This()) void {
    var iter = self.map.iterator();

    while (iter.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);

        for (entry.value_ptr.items) |*elt| {
            elt.deinit();
            self.allocator.free(elt.unstructured);
        }

        entry.value_ptr.deinit();
    }

    self.map.deinit();
}

pub const HeaderScanner = struct {
    pub const scan_option: Scanner.ScanOption = .{
        .include_delimiter = false,
        .delimiter = "\r\n",
    };

    inner_scanner: Scanner.WithDelimiter(scan_option),

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
    const header_map = std.StringHashMap(std.ArrayList(HeaderFieldValue)).init(allocator);
    var scanner: HeaderScanner = .{
        .inner_scanner = Scanner.withDelimiter(reader, allocator, HeaderScanner.scan_option),
    };

    defer scanner.inner_scanner.deinit();

    var header_result: Header = .{ .map = header_map, .allocator = allocator };

    while (true) {
        const field = scanner.scanWithAllocator(allocator) catch break;

        header_result.put(field[0], .{ .unstructured = field[1] }) catch |err| {
            std.debug.print("put err: {}\n", .{err});
            break;
        };
    }

    return header_result;
}

const std = @import("std");
const Scanner = @import("./Scanner.zig");
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

    try std.testing.expectEqualStrings("1.0", header.get("MIME-Version").?.items[0].unstructured);
    try std.testing.expectEqualStrings("Wed, 2 Apr 2025 14:15:19 +0900", header.get("Date").?.items[0].unstructured);
    try std.testing.expectEqualStrings(
        "multipart/alternative; boundary=\"00000000000062617a0631c4bd41\"",
        header.get("Content-Type").?.items[0].unstructured,
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

    try std.testing.expectEqualStrings(
        "text/plain; size=\"1024909\"; name=\"wololo.txt\"",
        current_header.get("Content-Type").?.items[0].unstructured,
    );

    const content_type = try current_header.get("Content-Type").?.items[0].asStructured(gpa);

    try std.testing.expectEqualStrings("text/plain", content_type.get(&[_]u8{0}).?);
    try std.testing.expectEqualStrings("\"1024909\"", content_type.get("size").?);
    try std.testing.expectEqualStrings("\"wololo.txt\"", content_type.get("name").?);
}
