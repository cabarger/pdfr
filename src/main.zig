const std = @import("std");

const fmt = std.fmt;
const mem = std.mem;
const assert = std.debug.assert;

const AutoHashMap = std.AutoHashMap;

/// PDF version example: %PDF-1.4
const header_byte_count = 8;

const IndirectObjectRefrence = struct {
    object_number: u32,
    generation_number: u32,
};

const Object = union {
    name: []const u8,
    dict: AutoHashMap(u64, Object),
    ior: IndirectObjectRefrence,
    number: u32,
};

/// Handle those pesky CRs
fn streamAppropriately(deal_with_crs: bool, reader: anytype, writer: anytype) !void {
    if (deal_with_crs) {
        try reader.streamUntilDelimiter(writer, '\r', null);
        try reader.skipUntilDelimiterOrEof('\n');
    } else try reader.streamUntilDelimiter(writer, '\r', null);
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    var arena = arena_instance.allocator();

    const pdf_file = try std.fs.cwd().openFile("hello.pdf", .{});
    defer pdf_file.close();

    var buf: [1024]u8 = undefined;
    var pdf_fbs = std.io.fixedBufferStream(&buf);
    var pdf_writer = pdf_fbs.writer();
    const pdf_reader = pdf_file.reader();

    var deal_with_crs = false;

    // Parse version header
    {
        try pdf_reader.streamUntilDelimiter(pdf_writer, '\n', pdf_fbs.buffer.len);
        defer pdf_fbs.reset();
        assert(pdf_fbs.getWritten().len > header_byte_count);

        // Figure out if lines end with '\r\n' or '\n'
        if (pdf_fbs.getWritten()[try pdf_fbs.getPos() - 1] == '\r') deal_with_crs = true;

        assert(std.mem.eql(u8, pdf_fbs.getWritten()[0 .. header_byte_count - 1], "%PDF-1."));
        const pdf_minor_version = try fmt.charToDigit(pdf_fbs.getWritten()[header_byte_count - 1], 10);

        // NOTE(caleb): This dummy pdf text extractor only supports minor version 4
        assert(pdf_minor_version == 4);
    }

    // TODO(caleb): Support non-textual PDF reading
    // Next determine if this is a textual or binary PDF file
    {
        try streamAppropriately(deal_with_crs, pdf_reader, pdf_writer);
        defer pdf_fbs.reset();
        assert(pdf_fbs.getWritten()[0] == '%'); // Line begins with a comment
        assert(pdf_fbs.getWritten()[1] < 128); // Textual if less than 128
    }
    while (true) {
        try streamAppropriately(deal_with_crs, pdf_reader, pdf_writer);
        defer pdf_fbs.reset();
        if (pdf_fbs.getWritten()[0] == '%') continue; // Ignore comments

        // Parse object label
        var tok_obj_line = std.mem.splitSequence(u8, pdf_fbs.getWritten(), " ");
        const obj_number = try fmt.parseUnsigned(u32, tok_obj_line.first(), 10);
        _ = obj_number;
        const generation_number = try fmt.parseUnsigned(u32, tok_obj_line.next() orelse unreachable, 10);
        _ = generation_number;

        // Now read object data. TODO(caleb): Handle other obj types (for now assume dict)
        pdf_fbs.reset();
        try streamAppropriately(deal_with_crs, pdf_reader, pdf_writer);
        tok_obj_line = std.mem.splitSequence(u8, pdf_fbs.getWritten(), " ");
        if (mem.eql(u8, tok_obj_line.first(), "<<")) { // dict
            var obj = Object{ .dict = AutoHashMap(u64, Object).init(arena) };
            while (true) {
                defer {
                    pdf_fbs.reset();
                    streamAppropriately(deal_with_crs, pdf_reader, pdf_writer) catch unreachable;
                    tok_obj_line = std.mem.splitSequence(u8, pdf_fbs.getWritten(), " ");
                }

                const k = if (tok_obj_line.index == 0) tok_obj_line.first() else tok_obj_line.next() orelse unreachable;
                const v = tok_obj_line.next() orelse break; //HACK(caleb): Handles ">>" case.

                std.debug.print("-- {s}\n", .{k});
                std.debug.print("-- {s}\n", .{v});

                // Resolve value type
                if (v[0] == '/') { // Name object
                    try obj.dict.put(std.hash_map.hashString(k[1..]), Object{ .name = try arena.dupe(u8, v[1..]) });
                } else if (pdf_fbs.getWritten()[try pdf_fbs.getPos() - 1] == 'R') { // Indirect refrence object
                    var ior = IndirectObjectRefrence{
                        .object_number = try fmt.parseUnsigned(u32, v, 10),
                        .generation_number = try fmt.parseUnsigned(u32, tok_obj_line.next() orelse unreachable, 10),
                    };
                    try obj.dict.put(std.hash_map.hashString(k[1..]), Object{ .ior = ior });
                } else if (v[0] == '[') { // List
                    continue;
                } else { // Number
                    try obj.dict.put(std.hash_map.hashString(k[1..]), Object{ .number = try fmt.parseUnsigned(u32, v, 10) });
                }
            }

            const type_entry = obj.dict.getEntry(std.hash_map.hashString("Type")) orelse unreachable;
            std.debug.print("Type: {?}\n", .{type_entry.value_ptr.*});
        }
        assert(mem.eql(u8, pdf_fbs.getWritten(), "endobj")); // Last stream call should have read "endobj"
    }

    std.process.cleanExit();
}
