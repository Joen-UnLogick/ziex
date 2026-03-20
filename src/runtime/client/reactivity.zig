//! Reactive primitives for client-side state management.
//! Provides fine-grained reactivity where only DOM nodes that depend on
//! changed signals are updated (no full re-render or tree diffing).

const std = @import("std");
const builtin = @import("builtin");

const Client = @import("Client.zig");
const zx = @import("../../root.zig");
const js = zx.client.js;

const BindingList = std.ArrayList(js.Object);
const EffectList = std.ArrayList(EffectCallback);

var signal_bindings = std.ArrayList(BindingList).empty;
var effect_callbacks = std.ArrayList(EffectList).empty;
var next_signal_id: u64 = 0;

const is_wasm = builtin.os.tag == .freestanding;
fn getGlobalAllocator() std.mem.Allocator {
    return zx.client_allocator;
}

const ComponentSubKey = struct {
    signal_id: u64,
    component_id: []const u8,

    const Context = struct {
        pub fn hash(_: Context, k: ComponentSubKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&k.signal_id));
            h.update(k.component_id);
            return h.final();
        }
        pub fn eql(_: Context, a: ComponentSubKey, b: ComponentSubKey) bool {
            return a.signal_id == b.signal_id and std.mem.eql(u8, a.component_id, b.component_id);
        }
    };
};

var component_subscriptions = std.HashMapUnmanaged(
    ComponentSubKey,
    void,
    ComponentSubKey.Context,
    std.hash_map.default_max_load_percentage,
){};

pub var active_component_id: ?[]const u8 = null;

/// Register a component for re-render when a signal changes.
pub fn subscribeComponent(signal_id: u64, component_id: []const u8) void {
    if (!is_wasm) return;
    const key = ComponentSubKey{ .signal_id = signal_id, .component_id = component_id };
    const g_alloc = getGlobalAllocator();
    const result = component_subscriptions.getOrPut(g_alloc, key) catch return;
    if (result.found_existing) return;

    const id_copy = g_alloc.dupe(u8, component_id) catch return;
    const ctx_ptr = g_alloc.create([]const u8) catch return;
    ctx_ptr.* = id_copy;
    registerEffect(signal_id, @ptrCast(ctx_ptr), &struct {
        fn run(ctx: *anyopaque) void {
            const id_ptr: *[]const u8 = @ptrCast(@alignCast(ctx));
            scheduleRender(id_ptr.*);
        }
    }.run);
}

/// Key for the per-component per-slot state store.
const StateKey = struct {
    component_id: []const u8,
    slot: u32,

    const Context = struct {
        pub fn hash(_: Context, k: StateKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.component_id);
            h.update(std.mem.asBytes(&k.slot));
            return h.final();
        }
        pub fn eql(_: Context, a: StateKey, b: StateKey) bool {
            return a.slot == b.slot and std.mem.eql(u8, a.component_id, b.component_id);
        }
    };
};

/// Opaque blob of state with a serialization vtable for server event round-trips.
const StateEntry = struct {
    ptr: *anyopaque,
    /// Serialize current value to positional JSON. Only populated on WASM.
    getJson: *const fn (alloc: std.mem.Allocator, ptr: *anyopaque) []const u8 = &noopGetJson,
    /// Apply a positional JSON value back to the state (triggers re-render).
    applyJson: *const fn (ptr: *anyopaque, json: []const u8) void = &noopApplyJson,

    fn noopGetJson(_: std.mem.Allocator, _: *anyopaque) []const u8 {
        return "null";
    }
    fn noopApplyJson(_: *anyopaque, _: []const u8) void {}
};

var state_store = std.HashMapUnmanaged(
    StateKey,
    StateEntry,
    StateKey.Context,
    std.hash_map.default_max_load_percentage,
){};

pub fn signal(comptime T: type, initial: T) Signal(T) {
    return Signal(T).init(initial);
}

/// Pure component state — triggers a full component re-render on change.
/// Unlike Signal, this has NO DOM binding and cannot be used with `{&myState}`.
/// Use `ctx.state()` to create an instance inside a component.
/// This will replace Signal in the future.
pub fn State(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ValueType = T;

        value: T,
        /// The owning component ID — used to call scheduleRender on mutation.
        component_id: []const u8,

        pub fn init(value: T, component_id: []const u8) Self {
            return .{ .value = value, .component_id = component_id };
        }

        /// Get the current value.
        pub inline fn get(self: *const Self) T {
            return self.value;
        }

        /// Set a new value and trigger a component re-render.
        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            scheduleRender(self.component_id);
        }

        /// Update the value using a transform function `fn(T) T` and trigger a re-render.
        /// Example: `count.update(struct { fn f(x: i32) i32 { return x + 1; } }.f)`
        pub fn update(self: *Self, transform: *const fn (T) T) void {
            self.value = transform(self.value);
            scheduleRender(self.component_id);
        }

        /// Create an event handler that updates the state using a transform function.
        pub fn bind(self: *Self, comptime transform: *const fn (T) T) zx.EventHandler {
            return .{
                .callback = &struct {
                    fn handler(ctx: *anyopaque, _: zx.EventContext) void {
                        const s: *Self = @ptrCast(@alignCast(ctx));
                        s.set(transform(s.get()));
                    }
                }.handler,
                .context = self,
            };
        }

        pub fn getOrCreate(alloc: std.mem.Allocator, component_id: []const u8, slot: u32, initial: T) !*Self {
            if (is_wasm) {
                const key = StateKey{ .component_id = component_id, .slot = slot };

                if (state_store.get(key)) |entry| {
                    return @ptrCast(@alignCast(entry.ptr));
                }

                const state_ptr = try getGlobalAllocator().create(Self);
                state_ptr.* = Self.init(initial, component_id);
                const id_copy = try getGlobalAllocator().dupe(u8, component_id);
                const stored_key = StateKey{ .component_id = id_copy, .slot = slot };
                try state_store.put(getGlobalAllocator(), stored_key, .{
                    .ptr = @ptrCast(state_ptr),
                    .getJson = &struct {
                        fn f(a: std.mem.Allocator, ptr: *anyopaque) []const u8 {
                            const s: *Self = @ptrCast(@alignCast(ptr));
                            var aw = std.Io.Writer.Allocating.init(a);
                            zx.util.zxon.serialize(s.get(), &aw.writer, .{}) catch return "null";
                            return aw.written();
                        }
                    }.f,
                    .applyJson = &struct {
                        fn f(ptr: *anyopaque, json: []const u8) void {
                            const s: *Self = @ptrCast(@alignCast(ptr));
                            s.set(zx.util.zxon.parse(T, getGlobalAllocator(), json, .{}) catch return);
                        }
                    }.f,
                });
                return state_ptr;
            } else {
                // Server SSR: return default state
                const state_ptr = try alloc.create(Self);
                state_ptr.* = Self.init(initial, component_id);
                return state_ptr;
            }
        }

        /// Look up an existing state by (component_id, slot). Used by StateContext in event handlers
        /// where the state was already created during render.
        pub fn getExisting(component_id: []const u8, slot: u32) *Self {
            const key = StateKey{ .component_id = component_id, .slot = slot };
            if (state_store.get(key)) |entry| {
                return @ptrCast(@alignCast(entry.ptr));
            }
            @panic("State not found — ensure sc.state() is called in the same order as ctx.state()");
        }
    };
}

/// Top-level alias for State(T) pointer to improve IDE/ZLS type resolution.
pub fn StateInstance(comptime T: type) type {
    return *State(T);
}

/// Collect a BoundStateEntry for every state belonging to `component_id`, in slot order.
/// Used by ctx.bind(serverFn) to auto-bind all component states for server event round-trips.
/// Returns an empty slice on SSR (state_store is not populated server-side).
pub fn collectStateBoundEntries(
    alloc: std.mem.Allocator,
    component_id: []const u8,
    state_count: u32,
) []EventHandler.BoundStateEntry {
    if (!is_wasm) return &.{};

    var list = std.ArrayList(EventHandler.BoundStateEntry).empty;
    for (0..state_count) |i| {
        const slot = (1 << 20) + @as(u32, @intCast(i));
        const key = StateKey{ .component_id = component_id, .slot = slot };
        if (state_store.get(key)) |entry| {
            list.append(alloc, .{
                .state_ptr = entry.ptr,
                .getJson = entry.getJson,
                .applyJson = entry.applyJson,
            }) catch {};
        }
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

pub fn Signal(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const ValueType = T;

        id: u64,
        value: T,
        runtime_id_assigned: bool = false,
        instance_idx: u32 = 0,

        pub fn init(initial: T) Self {
            return .{ .id = 0, .value = initial, .runtime_id_assigned = false };
        }

        pub fn initWithId(initial: T, id: u64) Self {
            return .{ .id = id, .value = initial, .runtime_id_assigned = id != 0 };
        }

        pub fn ensureId(self: anytype) void {
            const mutable = @constCast(self);
            if (!mutable.runtime_id_assigned) {
                mutable.id = next_signal_id;
                next_signal_id += 1;
                mutable.runtime_id_assigned = true;
            }
        }

        pub inline fn get(self: *const Self) T {
            return self.value;
        }

        pub inline fn ptr(self: *Self) *T {
            return &self.value;
        }

        pub fn set(self: *Self, new_value: T) void {
            self.value = new_value;
            self.notifyChange();
        }

        pub fn update(self: *Self, comptime updater: fn (T) T) void {
            self.value = updater(self.value);
            self.notifyChange();
        }

        pub fn notifyChange(self: *const Self) void {
            updateSignalNodes(self.id, self.value);
            runEffects(self.id);
        }

        pub fn subscribeActiveComponent(self: *Self) void {
            self.ensureId();
            if (active_component_id) |cid| {
                subscribeComponent(self.id, cid);
            }
        }

        pub inline fn eql(self: *const Self, other: T) bool {
            return std.meta.eql(self.value, other);
        }

        pub fn format(self: *const Self, buf: []u8) []const u8 {
            return formatValue(T, self.value, buf);
        }

        var instances = std.ArrayList(*Self).empty;
        var initial_values = std.ArrayList(T).empty;

        pub const ComponentSignal = struct {
            signal: *Self,

            /// Get the current value
            pub inline fn get(self: ComponentSignal) T {
                return self.signal.get();
            }

            /// Set a new value
            pub inline fn set(self: ComponentSignal, new_value: T) void {
                self.signal.set(new_value);
            }

            /// Format for template rendering
            pub fn format(self: ComponentSignal, buf: []u8) []const u8 {
                return self.signal.format(buf);
            }

            /// Get a handler to reset to initial value
            pub fn reset(self: ComponentSignal) zx.EventHandler {
                return .{
                    .callback = &struct {
                        fn handler(ctx: *anyopaque, _: zx.EventContext) void {
                            const sig_ptr: *Self = @ptrCast(@alignCast(ctx));
                            sig_ptr.set(initial_values.items[sig_ptr.instance_idx]);
                        }
                    }.handler,
                    .context = self.signal,
                };
            }

            /// Create an event handler that updates the signal using a transform function.
            /// Usage: `<button onclick={count.bind(struct { fn f(x: i32) i32 { return x + 1; } }.f)}>+</button>`
            pub fn bind(self: ComponentSignal, comptime transform: *const fn (T) T) zx.EventHandler {
                return .{
                    .callback = &struct {
                        fn handler(ctx: *anyopaque, _: zx.EventContext) void {
                            const sig_ptr: *Self = @ptrCast(@alignCast(ctx));
                            sig_ptr.set(transform(sig_ptr.get()));
                        }
                    }.handler,
                    .context = self.signal,
                };
            }

            /// Update the value using a transform function `fn(T) T`.
            pub fn update(self: ComponentSignal, transform: *const fn (T) T) void {
                self.signal.set(transform(self.signal.get()));
            }
        };

        /// Create an instance-aware signal for use in ComponentCtx.
        /// Each instance ID gets its own independent storage.
        /// DEPRECATED: Use getOrCreate with a stable component_id instead.
        pub fn create(alloc: std.mem.Allocator, instance_id: u16, initial: T) !ComponentSignal {
            if (!is_wasm) {
                // Server SSR just needs a transient object
                const sig_ptr = try alloc.create(Self);
                sig_ptr.* = Self.init(initial);
                return .{ .signal = sig_ptr };
            }

            const idx = @as(usize, instance_id);
            const g_alloc = getGlobalAllocator();

            if (idx >= instances.items.len) {
                try instances.ensureTotalCapacity(g_alloc, idx + 1);
                while (instances.items.len <= idx) {
                    const new_instance_ptr = try g_alloc.create(Self);
                    new_instance_ptr.* = Self.init(undefined);
                    try instances.append(g_alloc, new_instance_ptr);
                    try initial_values.append(g_alloc, undefined);
                }
            }

            instances.items[idx].* = Self.init(initial);
            instances.items[idx].instance_idx = @intCast(idx);
            initial_values.items[idx] = initial;

            return .{
                .signal = instances.items[idx],
            };
        }

        /// Stable state creation keyed by (component_id, slot).
        /// On the first call for a given (component_id, slot), allocates and initialises with `initial`.
        /// On subsequent calls (re-renders), returns the existing signal pointer unchanged.
        pub fn getOrCreate(alloc: std.mem.Allocator, component_id: []const u8, slot: u32, initial: T) !ComponentSignal {
            if (is_wasm) {
                const key = StateKey{ .component_id = component_id, .slot = slot };

                if (state_store.get(key)) |entry| {
                    // Already exists: return existing signal without touching its value.
                    const existing: *Self = @ptrCast(@alignCast(entry.ptr));
                    return .{ .signal = existing };
                }

                // First render: allocate and initialise.
                const sig_ptr = try getGlobalAllocator().create(Self);
                sig_ptr.* = Self.init(initial);
                const id_copy = try getGlobalAllocator().dupe(u8, component_id);
                const stored_key = StateKey{ .component_id = id_copy, .slot = slot };
                try state_store.put(getGlobalAllocator(), stored_key, .{ .ptr = @ptrCast(sig_ptr) });
                return .{ .signal = sig_ptr };
            } else {
                // Server SSR just needs a transient object
                const sig_ptr = try alloc.create(Self);
                sig_ptr.* = Self.init(initial);
                return .{ .signal = sig_ptr };
            }
        }
    };
}

/// Top-level alias for Signal(T).Instance to improve IDE/ZLS type resolution.
pub fn SignalInstance(comptime T: type) type {
    return Signal(T).ComponentSignal;
}

fn formatValue(comptime T: type, value: T, buf: []u8) []const u8 {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => std.fmt.bufPrint(buf, "{d}", .{value}) catch "?",
        .float, .comptime_float => std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "?",
        .bool => if (value) "true" else "false",
        .pointer => |ptr_info| blk: {
            if (ptr_info.size == .slice and ptr_info.child == u8) {
                break :blk value;
            }
            break :blk std.fmt.bufPrint(buf, "{any}", .{value}) catch "?";
        },
        .@"enum" => @tagName(value),
        .optional => if (value) |v| formatValue(@TypeOf(v), v, buf) else "",
        else => std.fmt.bufPrint(buf, "{any}", .{value}) catch "?",
    };
}

fn updateSignalNodes(signal_id: u64, value: anytype) void {
    if (!is_wasm) return;
    const T = @TypeOf(value);
    const idx = @as(usize, @intCast(signal_id));
    if (idx >= signal_bindings.items.len) return;
    const count = signal_bindings.items[idx].items.len;

    if (count == 0) return;

    var buf: [256]u8 = undefined;
    const text = formatValue(T, value, &buf);

    for (signal_bindings.items[idx].items) |node| {
        node.set("nodeValue", js.string(text)) catch {};
    }
}

/// Check if a type is a Signal type.
pub fn isSignalType(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .pointer) {
        const Child = info.pointer.child;
        if (@typeInfo(Child) == .@"struct") {
            return @hasField(Child, "id") and
                @hasField(Child, "value") and
                @hasDecl(Child, "get") and
                @hasDecl(Child, "set") and
                @hasDecl(Child, "notifyChange");
        }
    }
    return false;
}

/// Get the value type from a Signal pointer type.
pub fn SignalValueType(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer) {
        const Child = info.pointer.child;
        if (@typeInfo(Child) == .@"struct" and @hasField(Child, "value")) {
            return @FieldType(Child, "value");
        }
    }
    @compileError("Expected a pointer to a Signal type");
}

/// Derived/computed value that updates when its source signal changes.
pub fn Computed(comptime T: type, comptime SourceT: type) type {
    return struct {
        const Self = @This();
        pub const ValueType = T;

        id: u64 = 0,
        runtime_id_assigned: bool = false,
        value: T = undefined,
        initialized: bool = false,
        source: *const Signal(SourceT),
        compute: *const fn (SourceT) T,
        subscribed: bool = false,

        pub fn init(source: *const Signal(SourceT), compute: *const fn (SourceT) T) Self {
            return .{
                .id = 0,
                .runtime_id_assigned = false,
                .value = undefined,
                .initialized = false,
                .source = source,
                .compute = compute,
                .subscribed = false,
            };
        }

        pub fn ensureId(self: anytype) void {
            const mutable = @constCast(self);
            if (!mutable.runtime_id_assigned) {
                mutable.id = next_signal_id;
                next_signal_id += 1;
                mutable.runtime_id_assigned = true;
            }
        }

        fn ensureInitialized(self: anytype) void {
            const mutable = @constCast(self);
            if (!mutable.initialized) {
                mutable.value = mutable.compute(mutable.source.get());
                mutable.initialized = true;
            }
        }

        pub fn subscribe(self: *Self) void {
            if (self.subscribed) return;
            self.ensureInitialized();
            self.source.ensureId();
            registerEffect(self.source.id, @ptrCast(self), updateWrapper);
            self.subscribed = true;
        }

        fn updateWrapper(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.recompute();
        }

        fn recompute(self: *Self) void {
            const new_value = self.compute(self.source.get());
            self.value = new_value;
            updateSignalNodes(self.id, new_value);
            runEffects(self.id);
        }

        pub fn get(self: anytype) T {
            const mutable = @constCast(self);
            mutable.subscribe();
            mutable.ensureInitialized();
            return mutable.value;
        }

        pub fn notifyChange(self: *const Self) void {
            updateSignalNodes(self.id, self.value);
        }
    };
}

const EffectCallback = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) void,
};

/// Register a text node binding for a signal (no-op on server).
pub fn registerBinding(signal_id: u64, text_node: js.Object) void {
    if (!is_wasm) return;
    ensureSignalSlot(signal_id) catch return;
    const idx = @as(usize, @intCast(signal_id));
    signal_bindings.items[idx].append(getGlobalAllocator(), text_node) catch {};
}

/// Clear all bindings for a signal (no-op on server).
pub fn clearBindings(signal_id: u64) void {
    if (!is_wasm) return;
    const idx = @as(usize, @intCast(signal_id));
    if (idx >= signal_bindings.items.len) return;

    for (signal_bindings.items[idx].items) |node| {
        node.deinit();
    }
    signal_bindings.items[idx].clearRetainingCapacity();
}

/// Register an effect callback for a signal.
pub fn registerEffect(signal_id: u64, context: *anyopaque, run_fn: *const fn (*anyopaque) void) void {
    if (!is_wasm) return;
    ensureSignalSlot(signal_id) catch return;
    const idx = @as(usize, @intCast(signal_id));
    effect_callbacks.items[idx].append(getGlobalAllocator(), .{ .context = context, .run_fn = run_fn }) catch {};
}

fn runEffects(signal_id: u64) void {
    const idx = @as(usize, @intCast(signal_id));
    if (idx >= effect_callbacks.items.len) return;

    for (effect_callbacks.items[idx].items) |cb| {
        cb.run_fn(cb.context);
    }
}

/// Reset global reactivity state (useful for testing).
pub fn reset() void {
    const g_alloc = getGlobalAllocator();
    if (is_wasm) {
        for (signal_bindings.items) |*list| {
            list.deinit(g_alloc);
        }
        signal_bindings.clearAndFree(g_alloc);
    }
    for (effect_callbacks.items) |*list| {
        list.deinit(g_alloc);
    }
    effect_callbacks.clearAndFree(g_alloc);
    next_signal_id = 0;
}

/// Re-render the whole page using VDOM diffing algorithm like react
pub fn rerender() void {
    if (!is_wasm) return;
    if (Client.global_client) |client| {
        client.renderAll();
    }
}

/// Request a re-render of a specific component by ID.
/// If the component_id is not found in the registry (e.g. a nested ComponentCtx
/// component without @rendering={.client}), falls back to re-rendering all components.
pub fn scheduleRender(component_id: []const u8) void {
    if (!is_wasm) return;
    if (Client.global_client) |client| {
        for (client.components) |cmp| {
            if (std.mem.eql(u8, cmp.id, component_id)) {
                client.render(cmp) catch {};
                return;
            }
        }
        // component_id not registered — nested component inside a CSR parent.
        // Re-render all so the parent picks up the state change.
        client.renderAll();
    }
}

/// Cleanup function type for effects.
pub const CleanupFn = *const fn () void;

pub const EventHandler = struct {
    /// Vtable entry for a single piece of state bound to a server event handler.
    pub const BoundStateEntry = struct {
        state_ptr: *anyopaque,
        /// Serialize the current state value to its positional JSON representation.
        getJson: *const fn (alloc: std.mem.Allocator, ptr: *anyopaque) []const u8,
        /// Apply a positional JSON value back to the local state (triggers re-render).
        applyJson: *const fn (ptr: *anyopaque, json: []const u8) void,
    };

    callback: *const fn (ctx: *anyopaque, event: zx.EventContext) void,
    context: *anyopaque,
    /// Non-null when created from a form `action={}` handler.
    /// Takes a pointer so the server wrapper can write `_state_ctx` back after the call.
    action_fn: ?*const fn (*zx.ActionContext) void = null,
    /// Server-side handler; takes *ServerEventContext so the wrapper can set _state_ctx.
    server_event_fn: ?*const fn (*zx.server.Event) void = null,
    /// Unique ID for this handler instance on the current page.
    handler_id: u32 = 0,
    /// States to serialize/deserialize for server event round-trips.
    bound_states: []const BoundStateEntry = &.{},

    /// Helper to create an EventHandler from a plain function pointer (no context).
    /// Accepts `fn () void`, `fn (zx.EventContext) void`, and `fn (zx.ActionContext) void`.
    /// When the parameter is `zx.ActionContext`, the handler behaves as a server action:
    /// it calls preventDefault() then POSTs to the current page URL (WASM only).
    pub fn fromFn(comptime func: anytype) EventHandler {
        const FnType = @TypeOf(func);
        const fn_info = @typeInfo(FnType);
        const params = fn_info.@"fn".params;

        // Server action: fn (zx.ActionContext) void
        if (comptime params.len == 1) {
            const arg_type = params[0].type.?;
            switch (arg_type) {
                zx.ActionContext => {
                    // Wrap fn(ActionContext)void → fn(*ActionContext)void so the server
                    // can write _state_ctx back after dispatch.
                    const Wrap = struct {
                        fn w(ctx: *zx.ActionContext) void {
                            func(ctx.*);
                        }
                    };
                    return .{
                        .callback = &serverActionHandler,
                        .context = @as(*anyopaque, @ptrFromInt(1)),
                        .action_fn = &Wrap.w,
                    };
                },
                zx.server.Event => {
                    // Wrap to the canonical *ServerEventContext signature used by the registry.
                    const Wrapper = struct {
                        fn w(ctx: *zx.server.Event) void {
                            func(ctx.*);
                        }
                    };
                    return .{
                        .callback = &serverEventHandler,
                        .context = @as(*anyopaque, @ptrFromInt(1)),
                        .server_event_fn = &Wrapper.w,
                    };
                },
                else => {
                    // Guard: user-defined struct arg (not a framework context) is only valid
                    // on `action={}`. Point them at fromActionFn / the action attribute.
                    if (comptime @typeInfo(arg_type) == .@"struct" and
                        arg_type != zx.EventContext)
                    {
                        @compileError(
                            "A struct-typed handler `" ++ @typeName(@TypeOf(func)) ++ "` can only be used " ++
                                "as a form `action={}` attribute, not as an event handler. " ++
                                "Use `fn (zx.EventContext) void` for event handlers.",
                        );
                    }
                },
            }
        }

        const Wrapper = struct {
            fn wrapper(ctx: *anyopaque, event: zx.EventContext) void {
                _ = ctx;
                if (comptime params.len == 0) {
                    func();
                } else {
                    func(event);
                }
            }
        };
        return .{
            .callback = &Wrapper.wrapper,
            .context = @as(*anyopaque, @ptrFromInt(1)),
        };
    }

    /// Helper to create an EventHandler from a form `action={}` attribute.
    /// Accepts both `fn (zx.ActionContext) void` and `fn (SomeStruct) void`.
    /// For the struct form, form fields are automatically parsed via ctx.data(T).
    pub fn fromActionFn(comptime func: anytype) EventHandler {
        const FnType = @TypeOf(func);
        const fn_info = @typeInfo(FnType);
        const params = fn_info.@"fn".params;

        if (comptime params.len == 1) {
            const arg_type = params[0].type.?;
            // Direct typed form: first param is a user struct (not a framework context type).
            if (comptime @typeInfo(arg_type) == .@"struct" and
                arg_type != zx.ActionContext and
                arg_type != zx.EventContext and
                arg_type != zx.server.Event)
            {
                const DirectTyped = struct {
                    fn w(ctx: *zx.ActionContext) void {
                        func(ctx.data(arg_type));
                    }
                };
                return .{
                    .callback = &serverActionHandler,
                    .context = @as(*anyopaque, @ptrFromInt(1)),
                    .action_fn = &DirectTyped.w,
                };
            }
        }

        // Fall back to the standard path (handles ActionContext, ServerEventContext, etc.)
        return fromFn(func);
    }

    /// Helper to create an EventHandler from a runtime function pointer (no context)
    pub fn fromFnRuntime(func: *const fn (zx.EventContext) void) EventHandler {
        return .{
            .callback = &runtimeWrapper,
            .context = @ptrCast(@constCast(func)),
        };
    }

    fn runtimeWrapper(ctx: *anyopaque, event: zx.EventContext) void {
        const func: *const fn (zx.EventContext) void = @ptrCast(@alignCast(ctx));
        func(event);
    }

    /// Create an EventHandler that POSTs to the current page URL with minimal
    /// event data as JSON. In WASM this fires a fetch call to the server; on
    /// the server-side (SSR/native) this is a no-op.
    pub fn serverAction() EventHandler {
        return .{
            .callback = &serverActionHandler,
            .context = @as(*anyopaque, @ptrFromInt(1)),
        };
    }

    pub fn serverActionHandler(ctx: *anyopaque, event: zx.EventContext) void {
        _ = ctx;
        if (!is_wasm) return;

        // Prevent default browser behavior (e.g. form navigation).
        event.preventDefault();

        // const ext = @import("window/extern.zig");
        const client_fetch = @import("fetch.zig");
        const CoreFetch = @import("../core/Fetch.zig");

        // Get current page URL from the browser.
        // var url_buf: [2048]u8 = undefined;
        // const url_len = ext._getLocationHref(&url_buf, url_buf.len);
        // const url = url_buf[0..url_len];

        // Minimal JSON payload — enough for the server to identify the action.
        const headers = [_]CoreFetch.RequestInit.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-ZX-Action", .value = "1" },
        };

        client_fetch.fetchAsync(
            getGlobalAllocator(),
            "",
            .{
                .method = .GET,
                .headers = &headers,
                .body = "{}",
            },
            onServerActionResponse,
        );
    }

    /// Opaque context stored per-request when bound states need round-tripping.
    pub const ServerEventCallbackCtx = struct {
        handler_id: u32 = 0,
        bound_states: []const BoundStateEntry,
        /// When false (state-only handlers), event value is omitted from the payload.
        send_event_value: bool = true,
    };

    /// Factory used by ComponentCtx.sbind to build a server-event handler
    /// with bound states without exposing the private serverEventHandler symbol.
    pub fn createServerEvent(
        handler_id: u32,
        comptime server_fn: *const fn (*zx.server.Event) void,
        context: *anyopaque,
        bound_states: []const BoundStateEntry,
    ) EventHandler {
        return .{
            .handler_id = handler_id,
            .callback = &serverEventHandler,
            .context = context,
            .server_event_fn = server_fn,
            .bound_states = bound_states,
        };
    }

    fn serverEventHandler(ctx: *anyopaque, event: zx.EventContext) void {
        if (!is_wasm) return;

        // Prevent default browser behavior (e.g. form navigation).
        event.preventDefault();

        const client_fetch = @import("fetch.zig");
        const CoreFetch = @import("../core/Fetch.zig");

        // Resolve bound states and handler ID from context (sentinel 1 means no states/ID).
        var handler_id: u32 = 0;
        const bound_states: []const BoundStateEntry = if (@intFromPtr(ctx) == 1)
            &.{}
        else blk: {
            const ec: *ServerEventCallbackCtx = @ptrCast(@alignCast(ctx));
            handler_id = ec.handler_id;
            break :blk ec.bound_states;
        };

        const send_event_value: bool = if (@intFromPtr(ctx) == 1) true else blk: {
            const ec: *ServerEventCallbackCtx = @ptrCast(@alignCast(ctx));
            break :blk ec.send_event_value;
        };

        // Serialize current values of bound states.
        var state_jsons = std.ArrayList([]const u8).empty;
        for (bound_states) |bs| {
            const json = bs.getJson(getGlobalAllocator(), bs.state_ptr);
            state_jsons.append(getGlobalAllocator(), json) catch {};
        }

        const headers = [_]CoreFetch.RequestInit.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-ZX-Server-Event", .value = "1" },
        };

        const payload = ServerEventPayload{
            .handler_id = handler_id,
            .value = if (send_event_value) event.value() else null,
            .states = state_jsons.items,
        };

        var aw = std.Io.Writer.Allocating.init(getGlobalAllocator());
        zx.util.zxon.serialize(payload, &aw.writer, .{}) catch {};
        const payload_buf = aw.written();

        if (bound_states.len > 0) {
            // Allocate a callback context to carry bound_states into the response handler.
            const cb_ctx = getGlobalAllocator().create(ServerEventCallbackCtx) catch return;
            cb_ctx.* = .{ .bound_states = bound_states };
            client_fetch.fetchAsyncCtx(
                getGlobalAllocator(),
                "",
                .{ .method = .POST, .headers = &headers, .body = payload_buf },
                @ptrCast(cb_ctx),
                onServerEventResponse,
            );
        } else {
            client_fetch.fetchAsync(
                getGlobalAllocator(),
                "",
                .{ .method = .POST, .headers = &headers, .body = payload_buf },
                onServerActionResponse,
            );
        }
    }

    pub const ServerEventPayload = struct {
        handler_id: u32 = 0,
        value: ?[]const u8 = null,
        states: []const []const u8 = &.{},
    };

    fn onServerActionResponse(_: ?*@import("../core/Fetch.zig").Response, _: ?@import("../core/Fetch.zig").FetchError) void {}

    /// Called when a server event with bound states completes.
    /// Parses the returned state JSON array and applies each value to the local state.
    fn onServerEventResponse(ctx_ptr: *anyopaque, response: ?*@import("../core/Fetch.zig").Response, _: ?@import("../core/Fetch.zig").FetchError) void {
        const cb_ctx: *ServerEventCallbackCtx = @ptrCast(@alignCast(ctx_ptr));
        defer getGlobalAllocator().destroy(cb_ctx);

        const resp = response orelse return;
        const body = resp._body;
        if (body.len == 0) return;

        // Body is a JSON array of JSON-string-encoded state values: ["42", "true", ...]
        // Parse as []const []const u8; each element is the raw positional JSON for that state.
        const states = zx.util.zxon.parse([]const []const u8, getGlobalAllocator(), body, .{}) catch return;
        for (states, 0..) |state_json, i| {
            if (i >= cb_ctx.bound_states.len) break;
            cb_ctx.bound_states[i].applyJson(cb_ctx.bound_states[i].state_ptr, state_json);
        }
    }
};

/// Create an effect that runs when the source signal/computed changes.
/// Like SolidJS/React, runs on mount AND on signal changes.
/// Type is inferred from the source.
///
/// ```zig
/// // Runs on mount and on every change (like SolidJS createEffect)
/// zx.effect(&count, onCountChange);
/// ```
pub fn effect(source: anytype, comptime callback: anytype) void {
    effectWithOptions(source, callback, .{ .skip_initial = false });
}

/// Create an effect that only runs when the value changes (skips initial mount).
/// Like SolidJS `createEffect(on(signal, callback, { defer: true }))`.
///
/// ```zig
/// // Skips initial mount, only runs on changes
/// zx.effectDeferred(&count, onCountChange);
/// ```
pub fn effectDeferred(source: anytype, comptime callback: anytype) void {
    effectWithOptions(source, callback, .{ .skip_initial = true });
}

const EffectOptions = struct {
    /// If true, skip the initial run on mount (only run on changes)
    skip_initial: bool = false,
};

/// Effect type (prefer `effect()` function for simpler API).
pub fn Effect(comptime T: type) type {
    return struct {
        const Self = @This();

        var auto_effects = std.ArrayList(*Self).empty;

        source_ptr: *const anyopaque,
        source_get: *const fn (*const anyopaque) T,
        source_id_ptr: *u64,
        callback: *const fn (T) ?CleanupFn,
        last_value: ?T = null,
        registered: bool = false,
        cleanup: ?CleanupFn = null,

        /// Initialize and auto-run the effect.
        /// Callback can return `void` or `?CleanupFn`.
        /// If `skip_initial` is true, skips the initial run (only fires on changes).
        pub fn init(source: anytype, comptime callback: anytype, skip_initial: bool) void {
            if (!is_wasm) return;

            const SourcePtrType = @TypeOf(source);
            const source_info = @typeInfo(SourcePtrType);

            if (source_info != .pointer) {
                @compileError("Effect source must be a pointer to Signal or Computed");
            }

            const SourceType = source_info.pointer.child;

            if (!@hasDecl(SourceType, "get") or !@hasDecl(SourceType, "ensureId")) {
                @compileError("Effect source must have get() and ensureId() methods");
            }

            const CallbackType = @TypeOf(callback);
            const cb_type_info = @typeInfo(CallbackType);

            if (cb_type_info != .pointer or @typeInfo(cb_type_info.pointer.child) != .@"fn") {
                @compileError("Effect callback must be a function pointer");
            }

            const fn_info = @typeInfo(cb_type_info.pointer.child).@"fn";
            const ReturnType = fn_info.return_type orelse void;

            const wrapped_callback: *const fn (T) ?CleanupFn = comptime blk: {
                if (ReturnType == void) {
                    break :blk &struct {
                        fn wrapper(val: T) ?CleanupFn {
                            callback(val);
                            return null;
                        }
                    }.wrapper;
                } else if (ReturnType == CleanupFn) {
                    break :blk callback;
                } else {
                    @compileError("Effect callback must return void or CleanupFn");
                }
            };

            const Wrapper = struct {
                fn get(ptr: *const anyopaque) T {
                    const typed_ptr: *const SourceType = @ptrCast(@alignCast(ptr));
                    return typed_ptr.get();
                }
            };

            source.ensureId();

            const g_alloc = getGlobalAllocator();
            const effect_ptr = g_alloc.create(Self) catch @panic("OOM");

            effect_ptr.* = .{
                .source_ptr = @ptrCast(source),
                .source_get = Wrapper.get,
                .source_id_ptr = &@constCast(source).id,
                .callback = wrapped_callback,
                // If skip_initial, store current value so initial run is skipped
                // If not (default), use null so effect runs on mount
                .last_value = if (skip_initial) source.get() else null,
                .registered = false,
                .cleanup = null,
            };

            auto_effects.append(g_alloc, effect_ptr) catch @panic("OOM");

            effect_ptr.run();
        }

        fn runWrapper(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.execute();
        }

        /// Register the effect without running it immediately.
        /// Effect will only fire when the signal value changes.
        pub fn register(self: *Self) void {
            if (!self.registered) {
                registerEffect(self.source_id_ptr.*, @ptrCast(self), runWrapper);
                self.registered = true;
            }
        }

        /// Register and run the effect immediately (React-like behavior).
        pub fn run(self: *Self) void {
            self.register();
            self.execute();
        }

        fn execute(self: *Self) void {
            const current = self.source_get(self.source_ptr);
            if (self.last_value == null or !std.meta.eql(self.last_value.?, current)) {
                if (self.cleanup) |cleanup_fn| {
                    cleanup_fn();
                }
                self.last_value = current;
                self.cleanup = self.callback(current);
            }
        }

        pub fn dispose(self: *Self) void {
            if (self.cleanup) |cleanup_fn| {
                cleanup_fn();
                self.cleanup = null;
            }
            self.registered = false;
        }
    };
}

fn effectWithOptions(source: anytype, comptime callback: anytype, options: EffectOptions) void {
    const SourcePtrType = @TypeOf(source);
    const source_info = @typeInfo(SourcePtrType);

    if (source_info != .pointer) {
        @compileError("effect source must be a pointer to a Signal or Computed");
    }

    const SourceType = source_info.pointer.child;

    if (!@hasDecl(SourceType, "ValueType")) {
        @compileError("effect source must be a Signal or Computed type");
    }

    if (!is_wasm) return;

    const T = SourceType.ValueType;
    Effect(T).init(source, callback, options.skip_initial);
}

fn ensureSignalSlot(signal_id: u64) !void {
    const idx = @as(usize, @intCast(signal_id));
    const g_alloc = getGlobalAllocator();

    if (is_wasm) {
        if (idx >= signal_bindings.items.len) {
            try signal_bindings.ensureTotalCapacity(g_alloc, idx + 1);
            while (signal_bindings.items.len <= idx) {
                try signal_bindings.append(g_alloc, BindingList.empty);
            }
        }
    }

    if (idx >= effect_callbacks.items.len) {
        try effect_callbacks.ensureTotalCapacity(g_alloc, idx + 1);
        while (effect_callbacks.items.len <= idx) {
            try effect_callbacks.append(g_alloc, EffectList.empty);
        }
    }
}
