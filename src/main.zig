const std = @import("std");

const fmt = std.fmt;
const mem = std.mem;
const assert = std.debug.assert;

const AutoHashMap = std.AutoHashMap;

/// PDF version example: %PDF-1.4
const header_byte_count = 8;

const ObjectLabel = struct {
    object_number: u32,
    generation_number: u32,
};

const Object = union {
    name: []const u8,
    dict: AutoHashMap(u64, Object),
};

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    var arena = arena_instance.allocator();

    const pdf_file = try std.fs.cwd().openFile("hello.pdf", .{});
    defer pdf_file.close();

    var buf: [1024]u8 = undefined;
    var pdf_fbs = std.io.fixedBufferStream(&buf);
    var pdf_writer = pdf_fbs.writer();

    // TODO(caleb): Determine line delim. (for now assume \n) but \r\n is possible

    const pdf_reader = pdf_file.reader();

    // Parse version header
    {
        try pdf_reader.streamUntilDelimiter(pdf_writer, '\n', pdf_fbs.buffer.len);
        defer pdf_fbs.reset();
        assert(pdf_fbs.getWritten().len >= header_byte_count);
        assert(std.mem.eql(u8, pdf_fbs.getWritten()[0 .. header_byte_count - 1], "%PDF-1."));
        const pdf_minor_version = try fmt.charToDigit(pdf_fbs.getWritten()[header_byte_count - 1], 10); //HACK(caleb): -1 is for \r

        // NOTE(caleb): This dummy pdf text extractor only supports minor version 4
        assert(pdf_minor_version == 4);
    }

    // TODO(caleb): Support non-textual PDF reading
    // Next determine if this is a textual or binary PDF file
    {
        try pdf_reader.streamUntilDelimiter(pdf_writer, '\n', pdf_fbs.buffer.len);
        defer pdf_fbs.reset();
        assert(pdf_fbs.getWritten()[0] == '%'); // Line begins with a comment
        assert(pdf_fbs.getWritten()[1] < 128); // Textual if less than 128
    }
    while (true) {
        try pdf_reader.streamUntilDelimiter(pdf_writer, '\n', pdf_fbs.buffer.len);
        defer pdf_fbs.reset();
        if (pdf_fbs.getWritten()[0] == '%') continue; // Ignore comments

        // Parse object label
        {
            var tok_obj_line = std.mem.splitSequence(u8, pdf_fbs.getWritten(), " ");
            const obj_number = try fmt.parseUnsigned(u32, tok_obj_line.first(), 10);
            const generation_number = try fmt.parseUnsigned(u32, tok_obj_line.next() orelse unreachable, 10);
            pdf_fbs.reset();

            assert(obj_number == 1);
            assert(generation_number == 0);
        }

        // Now read object data
        while (true) {
            // TODO(caleb): Handle other obj types (for now assume dict)
            try pdf_reader.streamUntilDelimiter(pdf_writer, '\r', pdf_fbs.buffer.len);
            try pdf_reader.skipUntilDelimiterOrEof('\n');
            var tok_obj_line = std.mem.splitSequence(u8, pdf_fbs.getWritten(), " ");
            if (mem.eql(u8, tok_obj_line.first(), "<<")) { // dict
                var obj = Object{ .dict = AutoHashMap(u64, Object).init(arena) };
                while (true) {
                    // tok_obj_line.peek() != null and !mem.eql(u8, tok_obj_line.peek().?, ">>") break
                    const k = tok_obj_line.next() orelse unreachable;
                    const v = tok_obj_line.next() orelse unreachable;
                    try obj.dict.put(std.hash_map.hashString(k[1..]), Object{ .name = try arena.dupe(u8, v[1..]) });

                    break; // TODO(Caleb): Handle values like "2 0 R"
                }

                const type_value = obj.dict.getEntry(std.hash_map.hashString("Type")) orelse unreachable;
                std.debug.print("{s}\n", .{type_value.value_ptr.*.name});
                assert(mem.eql(u8, type_value.value_ptr.*.name, "Catalog"));

                unreachable; // :)
            } else unreachable;
        }

        break;
    }

    std.process.cleanExit();
}
