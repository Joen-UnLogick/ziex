const std = @import("std");
const zx = @import("../../root.zig");
const kv = @import("kv.zig");
const render = @import("../server/render.zig");

const Router = zx.Router;
const Component = zx.Component;

pub fn run() !void {
    kv.use();
    const allocator = std.heap.wasm_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    var pathname: []const u8 = "/";
    var search: []const u8 = "";
    var method: zx.Request.Method = .GET;
    var header_entries = std.ArrayList(HeaderEntry).empty;
    defer header_entries.deinit(allocator);

    // --- Parse CLI flags --- //
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pathname")) {
            pathname = args.next() orelse return error.MissingPathname;
        } else if (std.mem.eql(u8, arg, "--search")) {
            search = args.next() orelse return error.MissingSearch;
        } else if (std.mem.eql(u8, arg, "--method")) {
            const method_str = args.next() orelse return error.MissingMethod;
            method = std.meta.stringToEnum(zx.Request.Method, method_str) orelse return error.InvalidMethod;
        } else if (std.mem.eql(u8, arg, "--header")) {
            const header_str = args.next() orelse return error.MissingHeader;
            if (std.mem.indexOfScalar(u8, header_str, ':')) |sep| {
                try header_entries.append(allocator, .{
                    .name = header_str[0..sep],
                    .value = std.mem.trimLeft(u8, header_str[sep + 1 ..], " "),
                });
            }
        }
    }

    // --- Set up WASI backends --- //
    var wasi_headers = WasiHeaders{ .entries = header_entries.items };
    var wasi_search = WasiSearchParams{ .search = search };
    var wasi_res = WasiResponse.init(allocator);
    defer wasi_res.deinit();

    // --- Stdout/stderr writers --- //
    var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
    var stdout = &stdout_writer.interface;

    var stderr_writer = std.fs.File.stderr().writerStreaming(&.{});
    const stderr = &stderr_writer.interface;

    var stdin_body_buf: std.Io.Writer.Allocating = .init(allocator);
    defer stdin_body_buf.deinit();
    var stdin_read_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_read_buf);
    _ = stdin_reader.interface.streamRemaining(&stdin_body_buf.writer) catch {};

    var wasi_req = WasiRequest{ .body = stdin_body_buf.written() };

    // Extract headers needed before request construction
    var content_type: []const u8 = "";
    var cookie_header: []const u8 = "";
    for (header_entries.items) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, "content-type")) content_type = entry.value;
        if (std.ascii.eqlIgnoreCase(entry.name, "cookie")) cookie_header = entry.value;
    }
    var wasi_form_data = WasiFormData{
        .body = stdin_body_buf.written(),
        .content_type = content_type,
        .allocator = allocator,
    };

    const request = zx.Request{
        .url = "",
        .method = method,
        .pathname = pathname,
        .search = search,
        .headers = .{
            .backend_ctx = @ptrCast(&wasi_headers),
            .vtable = &WasiHeaders.vtable,
        },
        .searchParams = .{
            .backend_ctx = @ptrCast(&wasi_search),
            .vtable = &WasiSearchParams.vtable,
        },
        .arena = allocator,
        .backend_ctx = @ptrCast(&wasi_req),
        .vtable = &WasiRequest.vtable,
        .cookies = .{ .header_value = cookie_header },
        .formdata_backend_ctx = @ptrCast(&wasi_form_data),
        .formdata_vtable = &WasiFormData.vtable,
    };

    const response = zx.Response{
        .arena = allocator,
        .backend_ctx = @ptrCast(&wasi_res),
        .vtable = &WasiResponse.vtable,
    };

    // --- Route matching --- //
    const route_match = Router.matchRoute(pathname, .{ .match = .exact });
    wasi_req.route_match = route_match;
    const matched_route = if (route_match) |m| m.route else null;

    // --- Execute cascading proxy chain --- //
    var proxy_result = Router.executeCascadingProxies(pathname, request, response, allocator);
    if (proxy_result.aborted) {
        try sendResponse(stdout, stderr, &wasi_res);
        return;
    }

    if (matched_route) |route| {
        // --- API route dispatch --- //
        if (route.route) |handlers| {
            // Execute route-specific proxy (does NOT cascade)
            if (route.route_proxy) |route_proxy| {
                proxy_result = Router.executeLocalProxy(route_proxy, proxy_result, request, response, allocator);
                if (proxy_result.aborted) {
                    try sendResponse(stdout, stderr, &wasi_res);
                    return;
                }
            }

            if (Router.resolveRouteHandler(handlers, method)) |handler_fn| {
                var route_ctx = zx.RouteContext{
                    .request = request,
                    .response = response,
                    .socket = .{},
                    .allocator = allocator,
                    .arena = allocator,
                };
                route_ctx._state_ptr = proxy_result.state_ptr;
                handler_fn(route_ctx) catch |err| {
                    wasi_res.status = 500;
                    if (Router.renderErrorComponent(allocator, request, response, pathname, err)) |cmp| {
                        wasi_res.body.deinit();
                        wasi_res.body = .init(allocator);
                        render.current_route_path = pathname;
                        cmp.render(&wasi_res.body.writer) catch {};
                    }
                };
            } else {
                wasi_res.status = 405;
            }

            try sendResponse(stdout, stderr, &wasi_res);
            return;
        }

        // --- Page route rendering --- //
        if (route.page) |page_fn| {
            // Execute page-specific proxy (does NOT cascade)
            if (route.page_proxy) |page_proxy| {
                proxy_result = Router.executeLocalProxy(page_proxy, proxy_result, request, response, allocator);
                if (proxy_result.aborted) {
                    try sendResponse(stdout, stderr, &wasi_res);
                    return;
                }
            }

            var pagectx = zx.PageContext{
                .request = request,
                .response = response,
                .allocator = allocator,
                .arena = allocator,
            };
            pagectx._state_ptr = proxy_result.state_ptr;

            var layoutctx = zx.LayoutContext{
                .request = request,
                .response = response,
                .allocator = allocator,
                .arena = allocator,
            };
            layoutctx._state_ptr = proxy_result.state_ptr;

            var page_component = page_fn(pagectx) catch |err| {
                wasi_res.status = 500;
                if (Router.renderErrorComponent(allocator, request, response, pathname, err)) |cmp| {
                    wasi_res.body.deinit();
                    wasi_res.body = .init(allocator);
                    render.current_route_path = pathname;
                    cmp.render(&wasi_res.body.writer) catch {};
                }
                wasi_res.setContentTypeStr("text/html");
                try sendResponse(stdout, stderr, &wasi_res);
                return;
            };

            page_component = Router.applyLayouts(route, pathname, layoutctx, page_component);

            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            render.current_route_path = pathname;
            page_component.render(&aw.writer) catch {};

            wasi_res.setContentTypeStr("text/html");
            try writeEdgeMeta(stderr, &wasi_res);
            try stdout.print("<!DOCTYPE html>{s}", .{aw.written()});
            try stdout.flush();
            return;
        }
    }

    // --- Not Found --- //
    wasi_res.status = 404;
    wasi_res.setContentTypeStr("text/html");

    if (Router.renderNotFoundComponent(allocator, request, response, pathname, matched_route)) |cmp| {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        render.current_route_path = pathname;
        cmp.render(&aw.writer) catch {};

        try writeEdgeMeta(stderr, &wasi_res);
        try stdout.print("<!DOCTYPE html>{s}", .{aw.written()});
    } else {
        try writeEdgeMeta(stderr, &wasi_res);
        try stdout.print("404 Not Found", .{});
    }
    try stdout.flush();
}

/// Send response: write metadata to stderr, body to stdout
fn sendResponse(stdout: *std.Io.Writer, stderr: *std.Io.Writer, wasi_res: *WasiResponse) !void {
    try writeEdgeMeta(stderr, wasi_res);
    const body = wasi_res.written();
    if (body.len > 0) try stdout.print("{s}", .{body});
    try stdout.flush();
}

/// Write edge response metadata as a JSON line to stderr.
fn writeEdgeMeta(stderr: *std.Io.Writer, res: *const WasiResponse) !void {
    try stderr.print("__EDGE_META__:{{\"status\":{d}", .{res.status});
    if (res.header_entries.items.len > 0) {
        try stderr.print(",\"headers\":[", .{});
        for (res.header_entries.items, 0..) |entry, i| {
            if (i > 0) try stderr.print(",", .{});
            try stderr.print("[\"{s}\",\"{s}\"]", .{ entry.name, entry.value });
        }
        try stderr.print("]", .{});
    }
    try stderr.print("}}\n", .{});
    try stderr.flush();
}

// -- Net WASI Adapters -- //
const HeaderEntry = struct { name: []const u8, value: []const u8 };

/// WASI request headers backend - reads from CLI --header args
const WasiHeaders = struct {
    entries: []const HeaderEntry,

    const vtable = zx.Request.Headers.HeadersVTable{
        .get = &get,
        .has = &has,
    };

    fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *WasiHeaders = @ptrCast(@alignCast(ctx));
        for (self.entries) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn has(ctx: *anyopaque, name: []const u8) bool {
        return get(ctx, name) != null;
    }
};

/// WASI URL search params backend - parses query string
const WasiSearchParams = struct {
    search: []const u8,

    const vtable = zx.Request.URLSearchParams.URLSearchParamsVTable{
        .get = &get,
        .has = &has,
    };

    fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *WasiSearchParams = @ptrCast(@alignCast(ctx));
        const query = if (self.search.len > 0 and self.search[0] == '?') self.search[1..] else self.search;
        var iter = std.mem.splitScalar(u8, query, '&');
        while (iter.next()) |pair| {
            if (pair.len == 0) continue;
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
            } else {
                if (std.mem.eql(u8, pair, name)) return "";
            }
        }
        return null;
    }

    fn has(ctx: *anyopaque, name: []const u8) bool {
        return get(ctx, name) != null;
    }
};

/// WASI request backend - provides access to the request body read from stdin
const WasiRequest = struct {
    body: []const u8,
    route_match: ?Router.RouteMatch = null,

    const vtable = zx.Request.VTable{
        .text = &text,
        .getParam = &getParam,
    };

    fn text(ctx: *anyopaque) ?[]const u8 {
        const self: *WasiRequest = @ptrCast(@alignCast(ctx));
        if (self.body.len == 0) return null;
        return self.body;
    }

    fn getParam(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *WasiRequest = @ptrCast(@alignCast(ctx));
        const m = self.route_match orelse return null;
        return m.getParam(name);
    }
};

/// WASI form data backend - lazily parses application/x-www-form-urlencoded body
const WasiFormData = struct {
    body: []const u8,
    content_type: []const u8,
    allocator: std.mem.Allocator,

    keys: [32][]const u8 = undefined,
    values: [32][]const u8 = undefined,
    count: usize = 0,
    parsed: bool = false,

    const vtable = zx.Request.FormDataVTable{
        .get = &get,
        .has = &has,
        .entries = &entries,
    };

    fn parse(self: *WasiFormData) void {
        if (self.parsed) return;
        self.parsed = true;
        self.count = 0;

        // Only handle application/x-www-form-urlencoded
        const ct = self.content_type;
        const prefix = "application/x-www-form-urlencoded";
        const is_urlencoded = ct.len >= prefix.len and std.ascii.eqlIgnoreCase(ct[0..prefix.len], prefix);
        if (!is_urlencoded) return;

        var iter = std.mem.splitScalar(u8, self.body, '&');
        while (iter.next()) |pair| {
            if (pair.len == 0) continue;
            if (self.count >= self.keys.len) break;
            const i = self.count;
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                self.keys[i] = urlDecode(self.allocator, pair[0..eq]) catch pair[0..eq];
                self.values[i] = urlDecode(self.allocator, pair[eq + 1 ..]) catch pair[eq + 1 ..];
            } else {
                self.keys[i] = urlDecode(self.allocator, pair) catch pair;
                self.values[i] = "";
            }
            self.count += 1;
        }
    }

    fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *WasiFormData = @ptrCast(@alignCast(ctx));
        self.parse();
        for (self.keys[0..self.count], 0..) |key, i| {
            if (std.mem.eql(u8, key, name)) return self.values[i];
        }
        return null;
    }

    fn has(ctx: *anyopaque, name: []const u8) bool {
        return get(ctx, name) != null;
    }

    fn entries(ctx: *anyopaque) ?zx.Request.FormData.Iterator {
        const self: *WasiFormData = @ptrCast(@alignCast(ctx));
        self.parse();
        return .{
            .keys = self.keys[0..self.count],
            .values = self.values[0..self.count],
        };
    }
};

/// Decode a URL-encoded string (%xx and + → space). Returns allocated slice.
fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, input.len);
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '+') {
            buf[out] = ' ';
            out += 1;
            i += 1;
        } else if (input[i] == '%' and i + 2 < input.len) {
            const hi = std.fmt.charToDigit(input[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(input[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                buf[out] = (hi.? << 4) | lo.?;
                out += 1;
                i += 3;
            } else {
                buf[out] = input[i];
                out += 1;
                i += 1;
            }
        } else {
            buf[out] = input[i];
            out += 1;
            i += 1;
        }
    }
    return buf[0..out];
}

/// WASI response backend - stores response data in memory for later output
const WasiResponse = struct {
    status: u16 = 200,
    body: std.Io.Writer.Allocating,
    header_entries: std.ArrayList(HeaderEntry),
    allocator: std.mem.Allocator,

    const vtable = zx.Response.VTable{
        .setStatus = &setStatus,
        .setBody = &setBody,
        .setHeader = &setHeader,
        .getWriter = &getWriter,
        .writeChunk = &writeChunk,
        .clearWriter = &clearWriter,
        .setCookie = &setCookie,
    };

    fn init(alloc: std.mem.Allocator) WasiResponse {
        return .{
            .allocator = alloc,
            .body = .init(alloc),
            .header_entries = .empty,
        };
    }

    fn deinit(self: *WasiResponse) void {
        self.body.deinit();
        self.header_entries.deinit(self.allocator);
    }

    fn written(self: *WasiResponse) []const u8 {
        return self.body.written();
    }

    fn setContentTypeStr(self: *WasiResponse, ct: []const u8) void {
        for (self.header_entries.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, "Content-Type")) {
                entry.value = ct;
                return;
            }
        }
        self.header_entries.append(self.allocator, .{ .name = "Content-Type", .value = ct }) catch {};
    }

    fn setStatus(ctx: *anyopaque, code: u16) void {
        const self: *WasiResponse = @ptrCast(@alignCast(ctx));
        self.status = code;
    }

    fn setBody(ctx: *anyopaque, content: []const u8) void {
        const self: *WasiResponse = @ptrCast(@alignCast(ctx));
        self.body.deinit();
        self.body = .init(self.allocator);
        self.body.writer.writeAll(content) catch {};
    }

    fn setHeader(ctx: *anyopaque, name: []const u8, value: []const u8) void {
        const self: *WasiResponse = @ptrCast(@alignCast(ctx));
        for (self.header_entries.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) {
                entry.value = value;
                return;
            }
        }
        self.header_entries.append(self.allocator, .{ .name = name, .value = value }) catch {};
    }

    fn getWriter(ctx: *anyopaque) *std.Io.Writer {
        const self: *WasiResponse = @ptrCast(@alignCast(ctx));
        return &self.body.writer;
    }

    fn writeChunk(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *WasiResponse = @ptrCast(@alignCast(ctx));
        try self.body.writer.writeAll(data);
    }

    fn clearWriter(ctx: *anyopaque) void {
        const self: *WasiResponse = @ptrCast(@alignCast(ctx));
        self.body.deinit();
        self.body = .init(self.allocator);
    }

    fn setCookie(ctx: *anyopaque, name: []const u8, value: []const u8, opts: zx.Response.CookieOptions) anyerror!void {
        const self: *WasiResponse = @ptrCast(@alignCast(ctx));

        var buf = std.Io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();

        try buf.writer.print("{s}={s}", .{ name, value });
        if (opts.path.len > 0) try buf.writer.print("; Path={s}", .{opts.path});
        if (opts.domain.len > 0) try buf.writer.print("; Domain={s}", .{opts.domain});
        if (opts.max_age) |max_age| try buf.writer.print("; Max-Age={d}", .{max_age});
        if (opts.secure) try buf.writer.writeAll("; Secure");
        if (opts.http_only) try buf.writer.writeAll("; HttpOnly");
        if (opts.same_site) |ss| try buf.writer.print("; SameSite={s}", .{switch (ss) {
            .lax => "Lax",
            .strict => "Strict",
            .none => "None",
        }});
        if (opts.partitioned) try buf.writer.writeAll("; Partitioned");

        const cookie_str = try self.allocator.dupe(u8, buf.written());
        try self.header_entries.append(self.allocator, .{ .name = "Set-Cookie", .value = cookie_str });
    }
};
