const std = @import("std");
const builtin = @import("builtin");

const zx = @import("root.zig");
const Request = @import("runtime/core/Request.zig");
const Response = @import("runtime/core/Response.zig");
const pltfm = @import("platform.zig");
const client = @import("runtime/client/window.zig");
const reactivity = client.reactivity;

const Component = zx.Component;
const Allocator = std.mem.Allocator;

const platform = zx.platform;
const client_allocator = zx.client_allocator;

/// Context passed to proxy middleware functions.
/// Use `state.set()` to pass typed data to downstream route/page handlers.
pub const ProxyContext = struct {
    request: Request,
    response: Response,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,

    //TODO: move these to single _inner ptr
    _aborted: bool = false,
    _state_ptr: ?*const anyopaque = null,

    pub fn init(request: Request, response: Response, allocator: std.mem.Allocator, arena: std.mem.Allocator) ProxyContext {
        return .{
            .request = request,
            .response = response,
            .allocator = allocator,
            .arena = arena,
        };
    }

    /// Set typed state data to be passed to downstream route/page handlers.
    /// (e.g., `zx.RouteCtx(AppCtx, MyState)` or `zx.PageCtx(AppCtx, MyState)`).
    pub fn state(self: *ProxyContext, value: anytype) void {
        const T = @TypeOf(value);
        const ptr = self.arena.create(T) catch return;
        ptr.* = value;
        self._state_ptr = @ptrCast(ptr);
    }

    /// Abort the request chain - no further handlers (proxies, page, route) will be called
    /// Use this when the proxy has fully handled the request (e.g., returned an error response)
    pub fn abort(self: *ProxyContext) void {
        self._aborted = true;
    }

    /// Continue to the next handler in the chain
    /// This is a no-op (chain continues by default), but makes intent explicit
    pub fn next(self: *ProxyContext) void {
        _ = self;
        // No-op - chain continues by default unless abort() is called
    }

    /// Check if the request chain was aborted
    pub fn isAborted(self: *const ProxyContext) bool {
        return self._aborted;
    }
};

pub const EventContext = struct {
    /// The JS event object reference (as a u64 NaN-boxed value)
    event_ref: u64,
    /// The component ID to allow state access (set by ctx.bind())
    _component_id: []const u8 = "",
    /// The state slot index (set/reset by ctx.bind())
    _state_index: u32 = 0,

    pub fn init(event_ref: u64) EventContext {
        return .{ .event_ref = event_ref };
    }

    /// Access the component's state.
    /// Must be called in the same order as `ctx.state()` in the render function.
    pub fn state(self: *EventContext, comptime T: type) *reactivity.State(T) {
        if (self._component_id.len == 0) @panic("state() can only be called in a handler bound with ctx.bind()");
        const slot = (1 << 20) + self._state_index;
        self._state_index += 1;
        return reactivity.State(T).getExisting(self._component_id, slot);
    }

    /// Get the underlying js.Object for the event
    pub fn getEvent(self: EventContext) client.Event {
        return client.Event.fromRef(self.event_ref);
    }

    /// Get the underlying js.Object with data loaded (value, key, etc)
    pub fn getEventWithData(self: EventContext, allocator: std.mem.Allocator) client.Event {
        return client.Event.fromRefWithData(allocator, self.event_ref);
    }

    pub fn preventDefault(self: EventContext) void {
        self.getEvent().preventDefault();
    }

    /// Get the input value from event.target.value
    pub fn value(self: EventContext) ?[]const u8 {
        if (platform != .browser) return null;
        const real_js = @import("js");
        const event = self.getEvent();
        const target = event.ref.get(real_js.Object, "target") catch return null;
        return target.getAlloc(real_js.String, client_allocator, "value") catch null;
    }

    /// Get the key from keyboard event
    pub fn key(self: EventContext) ?[]const u8 {
        if (platform != .browser) return null;
        const real_js = @import("js");
        const event = self.getEvent();
        return event.ref.getAlloc(real_js.String, client_allocator, "key") catch null;
    }
};

pub const ActionContext = struct {
    request: Request = undefined,
    response: Response = undefined,
    allocator: std.mem.Allocator = undefined,
    arena: std.mem.Allocator = undefined,
    action_ref: u64 = 0,
    /// Set by stateful action wrappers; read back by the server to build the response.
    _state_ctx: ?*StateContext = null,

    pub fn init(action_ref: u64) ActionContext {
        return .{ .action_ref = action_ref };
    }

    /// Parse the submitted form fields into a typed struct using comptime reflection.
    ///
    /// Each struct field name must match an HTML `<input name="...">` attribute.
    /// Handles both `multipart/form-data` and `application/x-www-form-urlencoded`.
    ///
    /// Supported field types: `[]const u8`, `bool`, any int/float, and `?T` wrappers.
    /// Missing fields get zero-values (`""`, `false`, `0`); optional fields get `null`.
    ///
    /// Example:
    /// ```zig
    /// const Login = struct { username: []const u8, remember: bool };
    /// const form = ctx.data(Login);
    /// ```
    pub fn data(self: ActionContext, comptime T: type) T {
        comptime if (@typeInfo(T) != .@"struct") @compileError("ctx.data() requires a struct type, got: " ++ @typeName(T));

        const content_type = self.request.headers.get("content-type") orelse "";
        var result: T = undefined;

        if (std.mem.indexOf(u8, content_type, "multipart/form-data") != null) {
            const mfd = self.request.multiFormData();
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime field.type == zx.File) {
                    const val = mfd.get(field.name);
                    @field(result, field.name) = if (val) |v|
                        zx.File.fromBytes(v.data, v.filename orelse "", "", self.arena)
                    else
                        zx.File{};
                } else if (comptime field.type == ?zx.File) {
                    const val = mfd.get(field.name);
                    @field(result, field.name) = if (val) |v|
                        zx.File.fromBytes(v.data, v.filename orelse "", "", self.arena)
                    else
                        null;
                } else {
                    @field(result, field.name) = parseFormField(field.type, mfd.getValue(field.name), self.arena);
                }
            }
        } else {
            const fd = self.request.formData();
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime field.type == zx.File or field.type == ?zx.File) {
                    // Files are not available in url-encoded submissions.
                    @field(result, field.name) = if (comptime field.type == zx.File) zx.File{} else null;
                } else {
                    @field(result, field.name) = parseFormField(field.type, fd.get(field.name), self.arena);
                }
            }
        }

        return result;
    }
};

/// Coerce a raw form string value into a comptime-known type.
/// Called by ActionContext.data() for each struct field.
fn parseFormField(comptime T: type, raw: ?[]const u8, allocator: std.mem.Allocator) T {
    _ = allocator; // reserved for future heap types (e.g. []i32)
    switch (@typeInfo(T)) {
        .optional => |opt| {
            const val = raw orelse return null;
            // coerce child value → ?Child implicitly
            return parseFormField(opt.child, val, undefined);
        },
        .pointer => {
            comptime if (T != []const u8) @compileError("ctx.data(): only []const u8 is supported for pointer fields, got: " ++ @typeName(T));
            return raw orelse "";
        },
        .bool => {
            const val = raw orelse return false;
            return std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "on");
        },
        .int => {
            const val = raw orelse return 0;
            return std.fmt.parseInt(T, val, 10) catch 0;
        },
        .float => {
            const val = raw orelse return 0;
            return std.fmt.parseFloat(T, val) catch 0;
        },
        else => @compileError("ctx.data(): unsupported field type '" ++ @typeName(T) ++ "'"),
    }
}

/// A handle to a single state value inside a ServerEventContext handler.
/// Returned by `sc.state(T)` — call `.get()` to read, `.set(val)` to write back.
pub fn StateHandle(comptime T: type) type {
    return struct {
        _ctx: *StateContext,
        _index: usize,
        _value: T,

        pub fn get(self: @This()) T {
            return self._value;
        }

        pub fn set(self: @This(), val: T) void {
            if (self._index >= self._ctx._outputs.len) return;
            var aw = std.Io.Writer.Allocating.init(self._ctx._allocator);
            zx.util.zxon.serialize(val, &aw.writer, .{}) catch return;
            self._ctx._outputs[self._index] = aw.written();
        }
    };
}

/// Server-side accessor for component states round-tripped through a server event.
/// Passed as the second argument to handlers with signature:
///   fn(ctx: zx.server.Event, sc: *zx.StateContext) void
///
/// Call `sc.state(T)` in the same order as `ctx.state(T)` in the render function
/// to access each bound state — no index needed.
pub const StateContext = struct {
    arena: std.mem.Allocator,
    _allocator: std.mem.Allocator,
    /// Positional JSON values received from the client, one per bound state.
    _inputs: []const []const u8,
    /// Positional JSON values to return to the client (pre-seeded from _inputs).
    _outputs: [][]u8,
    /// Auto-incremented by each call to state().
    _index: usize = 0,

    /// Access the next bound state in call order, deserializing it to type `T`.
    /// Returns a StateHandle with `.get()` / `.set()` — same ergonomics as EventContext.state().
    pub fn state(self: *StateContext, comptime T: type) StateHandle(T) {
        const i = self._index;
        self._index += 1;
        const val: T = if (i < self._inputs.len)
            zx.util.zxon.parse(T, self._allocator, self._inputs[i], .{}) catch std.mem.zeroes(T)
        else
            std.mem.zeroes(T);
        return StateHandle(T){ ._ctx = self, ._index = i, ._value = val };
    }

    pub fn fmt(self: StateContext, comptime format: []const u8, args: anytype) ![]u8 {
        return fmtInner(self.arena, format, args);
    }
};

pub const ServerEventContext = struct {
    allocator: std.mem.Allocator = undefined,
    arena: std.mem.Allocator = undefined,
    action_ref: u64 = 0,
    payload: zx.EventHandler.ServerEventPayload = .{},
    /// Set by the comptime-generated wrapper when the handler uses StateContext.
    _state_ctx: ?*StateContext = null,

    pub fn init(action_ref: u64) ServerEventContext {
        return .{ .action_ref = action_ref };
    }

    pub fn value(self: ServerEventContext) ?[]const u8 {
        return self.payload.value;
    }
};

pub fn ComponentCtx(comptime PropsType: type) type {
    return struct {
        const Self = @This();
        props: PropsType,
        allocator: Allocator,
        children: ?Component = null,
        /// Legacy field – kept for backward-compat with Client.zig which still sets it.
        _id: u16 = 0,
        /// Stable string identifier for this component instance (e.g., the DOM marker ID).
        _component_id: []const u8 = "",
        /// Slot counter for signal() – separate from _state_index to avoid store collisions.
        _signal_index: u32 = 0,
        /// Slot counter for state().
        _state_index: u32 = 0,
        /// Slot counter for server event handlers to ensure stable IDs across re-renders.
        _handler_index: u32 = 0,

        // /// Fine-grained reactive signal – persisted across re-renders.
        // /// Use `{&mySignal}` in templates for text-node binding.
        // pub fn signal(self: *Self, comptime T: type, initial: T) reactivity.SignalInstance(T) {
        //     const slot = self._signal_index;
        //     self._signal_index += 1;
        //     return reactivity.Signal(T).getOrCreate(self.allocator, self._component_id, slot, initial) catch @panic("Signal(T).getOrCreate");
        // }

        /// Pure component state – persisted across re-renders.
        /// `.set(v)` and `.update(fn)` trigger a full component re-render.
        /// NOT for text binding; use `signal()` for that.
        pub fn state(self: *Self, comptime T: type, initial: T) reactivity.StateInstance(T) {
            // Offset by 1<<20 so state slots never collide with signal slots in the store.
            const slot = (1 << 20) + self._state_index;
            self._state_index += 1;
            return reactivity.State(T).getOrCreate(self.allocator, self._component_id, slot, initial) catch @panic("State(T).getOrCreate");
        }

        /// Bind a server event handler with only the explicitly listed states.
        /// Prefer `ctx.bind(handler)` which auto-binds all component states.
        /// Use this only when you want a smaller payload by sending a subset.
        ///
        /// `handler` must have the signature:
        ///   fn(ctx: zx.server.Event, sc: *zx.StateContext) void
        ///
        /// `states` is a tuple of `*State(T)` values (from `ctx.state()`).
        /// Access them via `sc.state(T)` in the same order as listed in the tuple.
        pub fn sbind(
            self: *Self,
            comptime handler: anytype,
            states: anytype,
        ) zx.EventHandler {
            const HandlerInfo = @typeInfo(@TypeOf(handler));
            const params = HandlerInfo.@"fn".params;

            comptime {
                if (params.len != 2 or
                    params[0].type.? != zx.server.Event or
                    params[1].type.? != *zx.StateContext)
                {
                    @compileError("sbind: handler must be fn(zx.server.Event, *zx.StateContext) void");
                }
            }

            const StatesType = @TypeOf(states);
            const state_fields = @typeInfo(StatesType).@"struct".fields;

            // Server-side wrapper: builds a StateContext from the parsed payload states,
            const ServerWrapper = struct {
                fn wrap(ctx: *zx.server.Event) void {
                    const n = ctx.payload.states.len;
                    const outputs = ctx.allocator.alloc([]u8, n) catch return;
                    for (ctx.payload.states, 0..) |s, i| {
                        outputs[i] = ctx.allocator.dupe(u8, s) catch "";
                    }
                    const sc = ctx.allocator.create(zx.StateContext) catch return;
                    sc.* = zx.StateContext{
                        .arena = ctx.arena,
                        ._allocator = ctx.allocator,
                        ._inputs = ctx.payload.states,
                        ._outputs = outputs,
                    };
                    handler(ctx.*, sc);
                    ctx._state_ctx = sc;
                }
            };

            // Client-side: build BoundStateEntry vtable for each bound state.
            const alloc = if (platform == .browser) client_allocator else self.allocator;
            const bound_states_arr = alloc.alloc(zx.EventHandler.BoundStateEntry, state_fields.len) catch @panic("OOM");

            inline for (state_fields, 0..) |field, i| {
                const s = @field(states, field.name); // *State(T)
                const T = @typeInfo(@TypeOf(s)).pointer.child.ValueType;

                bound_states_arr[i] = zx.EventHandler.BoundStateEntry{
                    .state_ptr = @ptrCast(s),
                    .getJson = &struct {
                        fn get(get_alloc: std.mem.Allocator, ptr: *anyopaque) []const u8 {
                            const st: *reactivity.State(T) = @ptrCast(@alignCast(ptr));
                            var aw = std.Io.Writer.Allocating.init(get_alloc);
                            zx.util.zxon.serialize(st.get(), &aw.writer, .{}) catch return "null";
                            return aw.written();
                        }
                    }.get,
                    .applyJson = &struct {
                        fn apply(ptr: *anyopaque, json: []const u8) void {
                            const st: *reactivity.State(T) = @ptrCast(@alignCast(ptr));
                            const val = zx.util.zxon.parse(T, client_allocator, json, .{}) catch return;
                            st.set(val);
                        }
                    }.apply,
                };
            }

            const h_id = blk: {
                self._handler_index += 1;
                break :blk self._handler_index;
            };

            const server_evt_ctx = alloc.create(zx.EventHandler.ServerEventCallbackCtx) catch @panic("OOM");
            server_evt_ctx.* = .{
                .handler_id = h_id,
                .bound_states = bound_states_arr,
            };

            return zx.EventHandler.createServerEvent(
                h_id,
                &ServerWrapper.wrap,
                @ptrCast(server_evt_ctx),
                bound_states_arr,
            );
        }

        /// Bind an event handler. Signature is detected at comptime:
        ///
        ///   fn(*EventContext) void
        ///     → client-side handler; state accessed via `e.state(T)` in call order.
        ///
        ///   fn(*zx.StateContext) void
        ///     → server-side handler (no event data needed); ALL component states are
        ///       automatically serialized and round-tripped. Access them via `sc.state(T)`
        ///       in the same order as `ctx.state(T)` in the render function.
        ///
        ///   fn(zx.server.Event, *zx.StateContext) void
        ///     → same as above but also receives the event context (value, payload, etc.).
        ///
        /// Use `sbind(handler, .{state1, state2})` to bind only specific states.
        pub fn bind(self: *Self, comptime handler: anytype) zx.EventHandler {
            const HandlerType = @TypeOf(handler);
            const FnType = switch (@typeInfo(HandlerType)) {
                .@"fn" => HandlerType,
                .pointer => |p| p.child,
                else => @compileError("bind: expected a function or function pointer"),
            };
            const params = @typeInfo(FnType).@"fn".params;

            if (comptime params.len == 1 and params[0].type.? == *EventContext) {
                // Client-side binding
                const alloc = if (platform == .browser) client_allocator else self.allocator;
                const cid_ptr = alloc.create([]const u8) catch @panic("OOM");
                cid_ptr.* = alloc.dupe(u8, self._component_id) catch @panic("OOM");

                return .{
                    .callback = &struct {
                        fn wrapper(ctx: *anyopaque, event: EventContext) void {
                            const cid_p: *[]const u8 = @ptrCast(@alignCast(ctx));
                            var e = event;
                            e._component_id = cid_p.*;
                            e._state_index = 0;
                            handler(&e);
                        }
                    }.wrapper,
                    .context = @ptrCast(cid_ptr),
                };
            } else if (comptime (params.len == 2 and
                params[0].type.? == zx.server.Event and
                params[1].type.? == *zx.StateContext) or
                (params.len == 1 and params[0].type.? == *zx.StateContext))
            {
                // Server-side binding (auto-bind all states)
                const ServerWrapper = struct {
                    fn wrap(ctx: *zx.server.Event) void {
                        const n = ctx.payload.states.len;
                        const outputs = ctx.allocator.alloc([]u8, n) catch return;
                        for (ctx.payload.states, 0..) |s, i| {
                            outputs[i] = ctx.allocator.dupe(u8, s) catch "";
                        }
                        const sc = ctx.allocator.create(zx.StateContext) catch return;
                        sc.* = zx.StateContext{
                            .arena = ctx.arena,
                            ._allocator = ctx.allocator,
                            ._inputs = ctx.payload.states,
                            ._outputs = outputs,
                        };
                        if (comptime params.len == 2) {
                            handler(ctx.*, sc);
                        } else {
                            handler(sc);
                        }
                        ctx._state_ctx = sc;
                    }
                };

                const alloc = if (platform == .browser) client_allocator else self.allocator;
                const bound_states = reactivity.collectStateBoundEntries(
                    alloc,
                    self._component_id,
                    self._state_index,
                );

                const h_id = blk: {
                    self._handler_index += 1;
                    break :blk self._handler_index;
                };

                const server_evt_ctx = alloc.create(zx.EventHandler.ServerEventCallbackCtx) catch @panic("OOM");
                server_evt_ctx.* = .{
                    .handler_id = h_id,
                    .bound_states = bound_states,
                    .send_event_value = comptime params.len == 2,
                };

                return zx.EventHandler.createServerEvent(
                    h_id,
                    &ServerWrapper.wrap,
                    @ptrCast(server_evt_ctx),
                    bound_states,
                );
            } else if (comptime (params.len == 2 and
                params[0].type.? == zx.ActionContext and
                params[1].type.? == *zx.StateContext) or
                (params.len == 2 and
                    @typeInfo(params[0].type.?) == .@"struct" and
                    params[0].type.? != zx.ActionContext and
                    params[1].type.? == *zx.StateContext))
            {
                // Form action with state binding.
                // Wraps into fn(*ActionContext)void: reads __zx_states from multipart,
                // creates StateContext, calls the real handler, stores sc on _state_ctx.
                const arg0 = params[0].type.?;
                const FormActionWrapper = struct {
                    fn wrap(action_ctx_ptr: *zx.ActionContext) void {
                        const mfd = action_ctx_ptr.request.multiFormData();
                        const states_raw = mfd.getValue("__zx_states") orelse "[]";
                        const states = zx.util.zxon.parse(
                            []const []const u8,
                            action_ctx_ptr.arena,
                            states_raw,
                            .{},
                        ) catch return;
                        const outputs = action_ctx_ptr.arena.alloc([]u8, states.len) catch return;
                        for (states, 0..) |s, i| {
                            outputs[i] = action_ctx_ptr.arena.dupe(u8, s) catch "";
                        }
                        const sc = action_ctx_ptr.arena.create(zx.StateContext) catch return;
                        sc.* = .{
                            .arena = action_ctx_ptr.arena,
                            ._allocator = action_ctx_ptr.arena,
                            ._inputs = states,
                            ._outputs = outputs,
                        };
                        action_ctx_ptr._state_ctx = sc;
                        if (comptime arg0 == zx.ActionContext) {
                            handler(action_ctx_ptr.*, sc);
                        } else {
                            handler(action_ctx_ptr.data(arg0), sc);
                        }
                    }
                };

                const alloc = if (platform == .browser) client_allocator else self.allocator;
                const bound_states = reactivity.collectStateBoundEntries(
                    alloc,
                    self._component_id,
                    self._state_index,
                );

                return zx.EventHandler{
                    .callback = &reactivity.EventHandler.serverActionHandler,
                    .context = @as(*anyopaque, @ptrFromInt(1)),
                    .action_fn = &FormActionWrapper.wrap,
                    .bound_states = bound_states,
                };
            } else {
                @compileError("bind: handler must be fn(*EventContext) void, fn(*StateContext) void, fn(ServerEventContext, *StateContext) void, fn(ActionContext, *StateContext) void, or fn(FormData, *StateContext) void");
            }
        }
    };
}

inline fn fmtInner(allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    aw.writer.print(format, args) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}
