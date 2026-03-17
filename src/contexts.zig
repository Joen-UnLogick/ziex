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
    request: Request,
    response: Response,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    action_ref: u64,
    pub fn init(action_ref: u64) ActionContext {
        return .{ .action_ref = action_ref };
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

        /// Fine-grained reactive signal – persisted across re-renders.
        /// Use `{&mySignal}` in templates for text-node binding.
        pub fn signal(self: *Self, comptime T: type, initial: T) reactivity.SignalInstance(T) {
            const slot = self._signal_index;
            self._signal_index += 1;
            return reactivity.Signal(T).getOrCreate(self.allocator, self._component_id, slot, initial) catch @panic("Signal(T).getOrCreate");
        }

        /// Pure component state – persisted across re-renders.
        /// `.set(v)` and `.update(fn)` trigger a full component re-render.
        /// NOT for text binding; use `signal()` for that.
        pub fn state(self: *Self, comptime T: type, initial: T) reactivity.StateInstance(T) {
            // Offset by 1<<20 so state slots never collide with signal slots in the store.
            const slot = (1 << 20) + self._state_index;
            self._state_index += 1;
            return reactivity.State(T).getOrCreate(self.allocator, self._component_id, slot, initial) catch @panic("State(T).getOrCreate");
        }

        /// Bind an event handler with access to all of this component's state.
        /// The handler receives a pointer to an `EventContext` which can access state via `e.state(T)`.
        ///
        /// Re-derive states in the handler using the same order as in the render function:
        /// ```zig
        /// pub fn MyComponent(ctx: *zx.ComponentCtx(void)) zx.Component {
        ///     const count = ctx.state(i32, 0);
        ///     return (<button onclick={ctx.bind(&onClick)}>Click</button>);
        /// }
        ///
        /// fn onClick(e: *zx.EventContext) void {
        ///     const count = e.state(i32);   // same order as render
        ///     e.preventDefault();
        ///     count.set(count.get() + 1);
        /// }
        /// ```
        pub fn bind(self: *Self, comptime handler: *const fn (*EventContext) void) zx.EventHandler {
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
        }
    };
}
