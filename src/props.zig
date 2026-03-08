const std = @import("std");

const pltfm = @import("platform.zig");
const platform = pltfm.platform;

/// Coerce props to the target struct type, handling defaults
pub fn coerceProps(comptime TargetType: type, props: anytype) TargetType {
    const TargetInfo = @typeInfo(TargetType);
    if (TargetInfo != .@"struct") {
        @compileError("Target type must be a struct");
    }

    const fields = TargetInfo.@"struct".fields;
    var result: TargetType = undefined;

    inline for (fields) |field| {
        if (@hasField(@TypeOf(props), field.name)) {
            @field(result, field.name) = @field(props, field.name);
        } else if (field.defaultValue()) |default_value| {
            @field(result, field.name) = default_value;
        } else {
            @compileError(std.fmt.comptimePrint("Missing required attribute `{s}` in Component `{s}`", .{ field.name, @typeName(TargetType) }));
        }
    }

    return result;
}

/// Serialize a value in positional array format (structs become arrays, nested structs too)
pub fn serializePositional(comptime T: type, value: T, writer: *std.Io.Writer) anyerror!void {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .@"struct" => |s| {
            // Structs become arrays: [field1_value, field2_value, ...]
            try writer.writeByte('[');
            inline for (s.fields, 0..) |field, i| {
                if (i > 0) try writer.writeByte(',');
                try serializePositional(field.type, @field(value, field.name), writer);
            }
            try writer.writeByte(']');
        },
        .optional => |opt| {
            if (value) |v| {
                try serializePositional(opt.child, v, writer);
            } else {
                try writer.writeAll("null");
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                // String slice - use JSON string encoding
                try writer.writeByte('"');
                for (value) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeByte('"');
            } else if (ptr.size == .slice) {
                // Non-u8 slice (e.g., []SearchContent) - serialize as JSON array
                try writer.writeByte('[');
                for (value, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try serializePositional(ptr.child, item, writer);
                }
                try writer.writeByte(']');
            } else if (ptr.size == .one) {
                // String literal (*const [N]u8 or *const [N:0]u8)
                const child_info = @typeInfo(ptr.child);
                if (child_info == .array and child_info.array.child == u8) {
                    try writer.writeByte('"');
                    for (value) |c| {
                        if (c == 0) break; // Handle null-terminated strings
                        switch (c) {
                            '"' => try writer.writeAll("\\\""),
                            '\\' => try writer.writeAll("\\\\"),
                            '\n' => try writer.writeAll("\\n"),
                            '\r' => try writer.writeAll("\\r"),
                            '\t' => try writer.writeAll("\\t"),
                            else => try writer.writeByte(c),
                        }
                    }
                    try writer.writeByte('"');
                } else {
                    try writer.writeAll("null");
                }
            } else {
                try writer.writeAll("null");
            }
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (value, 0..) |item, i| {
                if (i > 0) try writer.writeByte(',');
                try serializePositional(arr.child, item, writer);
            }
            try writer.writeByte(']');
        },
        .int, .comptime_int => {
            try writer.print("{d}", .{value});
        },
        .float, .comptime_float => {
            try writer.print("{d}", .{value});
        },
        .bool => {
            try writer.writeAll(if (value) "true" else "false");
        },
        .@"enum" => {
            // Serialize enum as integer index for compactness
            try writer.print("{d}", .{@intFromEnum(value)});
        },
        else => {
            try writer.writeAll("null");
        },
    }
}

/// Returns props pointer and JSON serializer function for React components
pub fn propsSerializerJson(comptime Props: type, allocator: std.mem.Allocator, props: Props) struct {
    ptr: ?*const anyopaque,
    writeFn: ?*const fn (*std.Io.Writer, *const anyopaque) anyerror!void,
} {
    const type_info = @typeInfo(Props);

    if (type_info != .@"struct") return .{ .ptr = null, .writeFn = null };
    if (type_info.@"struct".fields.len == 0) return .{ .ptr = null, .writeFn = null };
    if (!comptime isPropsSerializable(Props)) return .{ .ptr = null, .writeFn = null };

    const props_copy = allocator.create(Props) catch return .{ .ptr = null, .writeFn = null };
    props_copy.* = props;

    return .{
        .ptr = props_copy,
        .writeFn = &struct {
            fn write(writer: *std.Io.Writer, ptr: *const anyopaque) anyerror!void {
                const typed_props: *const Props = @ptrCast(@alignCast(ptr));
                try std.json.Stringify.value(typed_props.*, .{}, writer);
            }
        }.write,
    };
}

fn isPropsSerializable(comptime T: type) bool {
    return isPropsSerializableImpl(T, &.{});
}

fn isPropsSerializableImpl(comptime T: type, comptime visited: []const type) bool {
    // Check if we've already visited this type (recursive type detection)
    for (visited) |v| {
        if (v == T) return true; // Recursive type, assume serializable
    }

    const new_visited = visited ++ [_]type{T};

    const type_info = @typeInfo(T);
    return switch (type_info) {
        .int, .comptime_int, .float, .comptime_float, .bool => true,
        .pointer => |ptr| blk: {
            // Handle slices
            if (ptr.size == .slice) {
                if (ptr.child == u8) break :blk true;
                if (isPropsSerializableImpl(ptr.child, new_visited)) break :blk true;
            }
            if (ptr.size == .one) {
                const child_info = @typeInfo(ptr.child);
                // Check for *const [N]u8 or *const [N:0]u8 (null-terminated string literals)
                if (child_info == .array and child_info.array.child == u8) break :blk true;
            }
            break :blk false;
        },
        .array => |arr| isPropsSerializableImpl(arr.child, new_visited),
        .optional => |opt| isPropsSerializableImpl(opt.child, new_visited),
        .@"struct" => |s| blk: {
            for (s.fields) |field| {
                if (!isPropsSerializableImpl(field.type, new_visited)) break :blk false;
            }
            break :blk true;
        },
        .@"enum" => true,
        else => false,
    };
}

/// Compute the merged type of two structs for props spreading
/// All fields from both structs are included in the result
pub fn MergedPropsType(comptime BaseType: type, comptime OverrideType: type) type {
    const base_info = @typeInfo(BaseType);
    const override_info = @typeInfo(OverrideType);

    if (base_info != .@"struct" or override_info != .@"struct") {
        @compileError("MergedPropsType expects struct types");
    }

    const base_fields = base_info.@"struct".fields;
    const override_fields = override_info.@"struct".fields;

    // Count unique fields (override fields replace base fields with same name)
    comptime var field_count = base_fields.len;
    inline for (override_fields) |of| {
        comptime var found = false;
        inline for (base_fields) |bf| {
            if (std.mem.eql(u8, bf.name, of.name)) {
                found = true;
                break;
            }
        }
        if (!found) field_count += 1;
    }

    // Build the combined fields array
    comptime var fields: [field_count]std.builtin.Type.StructField = undefined;
    comptime var idx: usize = 0;

    // Add base fields (unless overridden)
    inline for (base_fields) |bf| {
        comptime var overridden = false;
        inline for (override_fields) |of| {
            if (std.mem.eql(u8, bf.name, of.name)) {
                overridden = true;
                break;
            }
        }
        if (overridden) {
            // Use override field's type
            inline for (override_fields) |of| {
                if (std.mem.eql(u8, bf.name, of.name)) {
                    fields[idx] = of;
                    break;
                }
            }
        } else {
            fields[idx] = bf;
        }
        idx += 1;
    }

    // Add new fields from override
    inline for (override_fields) |of| {
        comptime var found = false;
        inline for (base_fields) |bf| {
            if (std.mem.eql(u8, bf.name, of.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            fields[idx] = of;
            idx += 1;
        }
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// Returns props pointer and serializer function for direct-to-writer serialization at render time
/// Uses positional array format [val1, val2, ...] instead of JSON objects for smaller size.
/// Field names are known at compile time on both server and client, so we only need values.
pub fn propsSerializer(comptime Props: type, allocator: std.mem.Allocator, props: Props) struct {
    ptr: ?*const anyopaque,
    writeFn: ?*const fn (*std.Io.Writer, *const anyopaque) anyerror!void,
} {
    if (platform == .browser) return .{ .ptr = null, .writeFn = null };
    const type_info = @typeInfo(Props);

    if (type_info != .@"struct") return .{ .ptr = null, .writeFn = null };
    if (type_info.@"struct".fields.len == 0) return .{ .ptr = null, .writeFn = null };
    if (!comptime isPropsSerializable(Props)) {
        // @compileError("Props must be serializable");
        return .{ .ptr = null, .writeFn = null };
    }

    const props_copy = allocator.create(Props) catch return .{ .ptr = null, .writeFn = null };
    props_copy.* = props;

    return .{
        .ptr = props_copy,
        .writeFn = &struct {
            fn write(writer: *std.Io.Writer, ptr: *const anyopaque) anyerror!void {
                const typed_props: *const Props = @ptrCast(@alignCast(ptr));
                // Use positional array format: [val1, val2, ...] - no field names
                try serializePositional(Props, typed_props.*, writer);
            }
        }.write,
    };
}

/// MinimalArrayParser - Parses positional array format for component props
/// Format: [val1, val2, ...] where values are in struct field order
/// ~78KB smaller than std.json for WASM builds
pub const PropsParser = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) PropsParser {
        return .{ .data = data };
    }

    pub fn parse(self: *PropsParser, comptime T: type, allocator: std.mem.Allocator) !T {
        self.skipWhitespace();
        return self.parseValue(T, allocator);
    }

    fn parseValue(self: *PropsParser, comptime T: type, allocator: std.mem.Allocator) anyerror!T {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .@"struct" => |s| {
                // Structs are serialized as arrays
                if (self.current() != '[') return error.ExpectedArrayStart;
                self.pos += 1;
                self.skipWhitespace();

                var result: T = undefined;
                inline for (s.fields, 0..) |field, i| {
                    if (i > 0) {
                        self.skipWhitespace();
                        if (self.current() == ',') self.pos += 1;
                        self.skipWhitespace();
                    }
                    @field(result, field.name) = try self.parseValue(field.type, allocator);
                }

                self.skipWhitespace();
                if (self.current() != ']') return error.ExpectedArrayEnd;
                self.pos += 1;
                return result;
            },
            .optional => |opt| {
                if (self.matchLiteral("null")) return null;
                return try self.parseValue(opt.child, allocator);
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    if (ptr.child == u8) {
                        return self.parseString(allocator);
                    }

                    if (self.current() != '[') return error.ExpectedArrayStart;
                    self.pos += 1;
                    self.skipWhitespace();

                    if (self.current() == ']') {
                        self.pos += 1;
                        return &.{};
                    }

                    var list = std.array_list.Managed(ptr.child).init(allocator);
                    errdefer list.deinit();

                    while (self.pos < self.data.len) {
                        const val = try self.parseValue(ptr.child, allocator);
                        try list.append(val);

                        self.skipWhitespace();
                        if (self.current() == ',') {
                            self.pos += 1;
                            self.skipWhitespace();
                        } else if (self.current() == ']') {
                            self.pos += 1;
                            return list.toOwnedSlice();
                        } else {
                            return error.ExpectedArrayEnd;
                        }
                    }
                    return error.UnexpectedEnd;
                }
                return error.UnsupportedType;
            },
            .array => |arr| {
                if (self.current() != '[') return error.ExpectedArrayStart;
                self.pos += 1;
                self.skipWhitespace();

                var result: T = undefined;
                for (&result, 0..) |*item, i| {
                    if (i > 0) {
                        self.skipWhitespace();
                        if (self.current() == ',') self.pos += 1;
                        self.skipWhitespace();
                    }
                    item.* = try self.parseValue(arr.child, allocator);
                }

                self.skipWhitespace();
                if (self.current() != ']') return error.ExpectedArrayEnd;
                self.pos += 1;
                return result;
            },
            .int => return self.parseInt(T),
            .float => return self.parseFloat(T),
            .bool => {
                if (self.matchLiteral("true")) return true;
                if (self.matchLiteral("false")) return false;
                return false;
            },
            .@"enum" => |e| {
                const int_val = self.parseInt(e.tag_type) catch 0;
                return @enumFromInt(int_val);
            },
            else => return error.UnsupportedType,
        }
    }

    fn parseString(self: *PropsParser, allocator: std.mem.Allocator) ![]const u8 {
        if (self.current() != '"') return error.ExpectedString;
        self.pos += 1;

        const start = self.pos;
        var has_escapes = false;

        while (self.pos < self.data.len and self.data[self.pos] != '"') {
            if (self.data[self.pos] == '\\') {
                has_escapes = true;
                self.pos += 2; // Skip escape sequence
            } else {
                self.pos += 1;
            }
        }

        const end = self.pos;
        if (self.pos < self.data.len) self.pos += 1; // Skip closing quote

        if (!has_escapes) {
            return allocator.dupe(u8, self.data[start..end]) catch "";
        }

        // Handle escapes - build result manually
        var result_buf: [4096]u8 = undefined;
        var result_len: usize = 0;
        var i = start;
        while (i < end and result_len < result_buf.len) {
            if (self.data[i] == '\\' and i + 1 < end) {
                result_buf[result_len] = switch (self.data[i + 1]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '"' => '"',
                    '\\' => '\\',
                    else => self.data[i + 1],
                };
                result_len += 1;
                i += 2;
            } else {
                result_buf[result_len] = self.data[i];
                result_len += 1;
                i += 1;
            }
        }

        return allocator.dupe(u8, result_buf[0..result_len]) catch "";
    }

    fn parseInt(self: *PropsParser, comptime T: type) !T {
        self.skipWhitespace();
        const start = self.pos;
        var is_negative = false;

        if (self.current() == '-') {
            is_negative = true;
            self.pos += 1;
        }

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c >= '0' and c <= '9') {
                self.pos += 1;
            } else {
                break;
            }
        }

        if (self.pos == start or (is_negative and self.pos == start + 1)) {
            return 0;
        }

        return std.fmt.parseInt(T, self.data[start..self.pos], 10) catch 0;
    }

    fn parseFloat(self: *PropsParser, comptime T: type) !T {
        self.skipWhitespace();
        const start = self.pos;

        if (self.current() == '-') self.pos += 1;

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if ((c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') {
                self.pos += 1;
            } else {
                break;
            }
        }

        if (self.pos == start) return 0;
        return std.fmt.parseFloat(T, self.data[start..self.pos]) catch 0;
    }

    fn matchLiteral(self: *PropsParser, literal: []const u8) bool {
        if (self.pos + literal.len <= self.data.len) {
            if (std.mem.eql(u8, self.data[self.pos..][0..literal.len], literal)) {
                self.pos += literal.len;
                return true;
            }
        }
        return false;
    }

    fn skipWhitespace(self: *PropsParser) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn current(self: *PropsParser) u8 {
        return if (self.pos < self.data.len) self.data[self.pos] else 0;
    }
};

/// Parse props from positional array format: [val1, val2, ...]
/// Field names are known at compile time, so we only need values in order.
/// Returns zeroed props on parse failure.
pub fn parseProps(comptime PropT: type, allocator: std.mem.Allocator, props_json: ?[]const u8) PropT {
    if (props_json) |json_bytes| {
        var parser = PropsParser.init(json_bytes);
        return parser.parse(PropT, allocator) catch std.mem.zeroes(PropT);
    }
    return std.mem.zeroes(PropT);
}

pub const prop = struct {
    pub const serialize = serializePositional;
    pub const parse = parseProps;
};
