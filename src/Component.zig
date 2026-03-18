const std = @import("std");

const zx = @import("root.zig");
const prp = @import("props.zig");

const ElementTag = zx.ElementTag;
const Allocator = std.mem.Allocator;
const BuiltinAttribute = zx.BuiltinAttribute;
const devtool = zx.devtool;

pub const Component = union(enum) {
    pub const Serializable = devtool.ComponentSerializable;

    none,
    text: []const u8,
    element: Element,
    component_fn: ComponentFn,
    component_csr: ComponentCsr,
    /// Reactive signal text - updates automatically when signal changes
    signal_text: SignalText,

    /// A text node bound to a Signal for fine-grained reactivity
    pub const SignalText = struct {
        /// The signal's unique ID for DOM binding
        signal_id: u64,
        /// The current text value (for initial render)
        current_text: []const u8,
    };

    pub const ComponentCsr = struct {
        name: []const u8,
        id: []const u8,
        props_ptr: ?*const anyopaque = null,
        writeProps: ?*const fn (*std.Io.Writer, *const anyopaque) anyerror!void = null,
        getStateItems: ?*const anyopaque = null,
        /// SSR-rendered content of the component (for hydration)
        children: ?*const Component = null,
        /// Whether this is a React component (uses JSON) or Zig component (uses ZON)
        is_react: bool = false,
    };

    pub const ComponentFn = struct {
        propsPtr: ?*const anyopaque,
        callFn: *const fn (propsPtr: ?*const anyopaque, allocator: Allocator) anyerror!Component,
        getStateItems: ?*const anyopaque = null,
        allocator: Allocator,
        deinitFn: ?*const fn (propsPtr: ?*const anyopaque, allocator: Allocator) void,
        async_mode: BuiltinAttribute.Async = .sync,
        fallback: ?*const Component = null,
        caching: ?BuiltinAttribute.Caching = null,
        name: []const u8,

        pub fn init(comptime func: anytype, name: []const u8, allocator: Allocator, props: anytype) ComponentFn {
            const FuncInfo = @typeInfo(@TypeOf(func));
            const param_count = FuncInfo.@"fn".params.len;
            const fn_name = @typeName(@TypeOf(func));

            // Validation of parameters
            if (param_count != 1 and param_count != 2)
                @compileError(std.fmt.comptimePrint("{s} must have 1 or 2 parameters found {d} parameters", .{ fn_name, param_count }));

            const FirstPropType = FuncInfo.@"fn".params[0].type.?;
            const first_is_allocator = FirstPropType == std.mem.Allocator;
            const first_is_ctx_ptr = @typeInfo(FirstPropType) == .pointer and
                @hasField(@typeInfo(FirstPropType).pointer.child, "allocator") and
                @hasField(@typeInfo(FirstPropType).pointer.child, "children");

            if (!first_is_allocator and !first_is_ctx_ptr)
                @compileError("Component " ++ fn_name ++ " must have allocator or *ComponentCtx as the first parameter");

            // If two parameters are passed with allocator first, the props type must be a struct
            if (first_is_allocator and param_count == 2) {
                const SecondPropType = FuncInfo.@"fn".params[1].type.?;
                if (@typeInfo(SecondPropType) != .@"struct")
                    @compileError("Component" ++ fn_name ++ " must have a struct as the second parameter, found " ++ @typeName(SecondPropType));
            }

            // Context-based components should only have 1 parameter
            if (first_is_ctx_ptr and param_count != 1)
                @compileError("Component " ++ fn_name ++ " with *ComponentCtx must have exactly 1 parameter");

            // Allocate props on heap to persist
            const props_copy = if (first_is_allocator and param_count == 2) blk: {
                const SecondPropType = FuncInfo.@"fn".params[1].type.?;
                const coerced = prp.coerceProps(SecondPropType, props);
                const p = allocator.create(SecondPropType) catch @panic("OOM");
                p.* = coerced;
                break :blk p;
            } else if (first_is_ctx_ptr) blk: {
                // Contexted components
                const CtxType = @typeInfo(FirstPropType).pointer.child;
                const ctx = allocator.create(CtxType) catch @panic("OOM");
                // allocator.create() does NOT run field default initializers, so explicitly
                // set all fields that ComponentCtx defines with defaults.
                ctx.allocator = allocator;
                if (@hasField(CtxType, "_component_id")) ctx._component_id = "";
                if (@hasField(CtxType, "_id")) ctx._id = 0;
                if (@hasField(CtxType, "_state_index")) ctx._state_index = 0;
                if (@hasField(CtxType, "_signal_index")) ctx._signal_index = 0;
                // Children from props if present
                ctx.children = if (@hasField(@TypeOf(props), "children")) props.children else null;
                // fn Component(ctx: *ComponentCtx(Props)) zx.Component
                if (@hasField(CtxType, "props")) {
                    const PropsFieldType = @FieldType(CtxType, "props");
                    if (PropsFieldType != void) {
                        ctx.props = prp.coerceProps(PropsFieldType, props);
                    }
                }
                break :blk ctx;
            } else null;

            const Wrapper = struct {
                // Check if the function returns an optional type
                const ReturnType = FuncInfo.@"fn".return_type.?;
                const returns_optional = @typeInfo(ReturnType) == .optional;
                const returns_error_union = @typeInfo(ReturnType) == .error_union;
                const inner_is_optional = returns_error_union and @typeInfo(@typeInfo(ReturnType).error_union.payload) == .optional;

                /// Normalize any return type (Component, ?Component, !Component, !?Component) to anyerror!Component
                fn normalize(result: anytype) anyerror!Component {
                    const T = @TypeOf(result);
                    if (T == Component) {
                        return result;
                    }
                    // ?Component -> return .none if null
                    if (@typeInfo(T) == .optional) {
                        return result orelse .none;
                    }
                    // !Component or !?Component
                    if (@typeInfo(T) == .error_union) {
                        const payload = try result;
                        // Check if payload is optional
                        if (@typeInfo(@TypeOf(payload)) == .optional) {
                            return payload orelse .none;
                        }
                        return payload;
                    }
                    return result;
                }

                fn call(propsPtr: ?*const anyopaque, alloc: Allocator) anyerror!Component {
                    if (first_is_ctx_ptr) {
                        const CtxType = @typeInfo(FirstPropType).pointer.child;
                        const ctx_ptr: *CtxType = @ptrCast(@alignCast(@constCast(propsPtr orelse @panic("ctx is null"))));
                        // Reset slot counters on every call so hooks run in stable order.
                        if (@hasField(CtxType, "_state_index")) ctx_ptr._state_index = 0;
                        if (@hasField(CtxType, "_signal_index")) ctx_ptr._signal_index = 0;
                        if (@hasField(CtxType, "_handler_index")) ctx_ptr._handler_index = 0;
                        return normalize(func(ctx_ptr));
                    }
                    if (first_is_allocator and param_count == 1) {
                        return normalize(func(alloc));
                    }
                    if (first_is_allocator and param_count == 2) {
                        const SecondPropType = FuncInfo.@"fn".params[1].type.?;
                        const p = propsPtr orelse @panic("propsPtr is null for function with props");
                        const typed_p: *const SecondPropType = @ptrCast(@alignCast(p));
                        return normalize(func(alloc, typed_p.*));
                    }
                    unreachable;
                }

                fn deinit(propsPtr: ?*const anyopaque, alloc: Allocator) void {
                    if (first_is_ctx_ptr) {
                        const CtxType = @typeInfo(FirstPropType).pointer.child;
                        const ctx_ptr: *CtxType = @ptrCast(@alignCast(@constCast(propsPtr orelse return)));
                        alloc.destroy(ctx_ptr);
                        return;
                    }
                    if (first_is_allocator and param_count == 2) {
                        const SecondPropType = FuncInfo.@"fn".params[1].type.?;
                        const p = propsPtr orelse @panic("propsPtr is null for function with props");
                        const typed_p: *const SecondPropType = @ptrCast(@alignCast(p));
                        alloc.destroy(typed_p);
                    }
                }
            };

            return .{
                .propsPtr = props_copy,
                .callFn = Wrapper.call,
                .getStateItems = @ptrCast(devtool.ComponentSerializable.createGetStateItemsFn(func)),
                .allocator = allocator,
                .deinitFn = Wrapper.deinit,
                .name = name,
            };
        }

        pub fn call(self: ComponentFn) anyerror!Component {
            return self.callFn(self.propsPtr, self.allocator);
        }

        pub fn deinit(self: ComponentFn) void {
            if (self.deinitFn) |deinit_fn| {
                deinit_fn(self.propsPtr, self.allocator);
            }
        }
    };

    /// Free allocated memory recursively
    /// Note: Only frees what was allocated by ZxContext.zx()
    /// Inline struct data is not freed (and will cause no issues as it's stack data)
    pub fn deinit(self: Component, allocator: std.mem.Allocator) void {
        switch (self) {
            .none, .text, .signal_text => {},
            .element => |elem| {
                if (elem.children) |children| {
                    // Recursively free children (e.g., Button() results)
                    for (children) |child| {
                        child.deinit(allocator);
                    }
                    // Free the children array itself
                    allocator.free(children);
                }
                if (elem.attributes) |attributes| {
                    allocator.free(attributes);
                }
            },
            .component_fn => |func| {
                // Free the props that were allocated
                func.deinit();
            },
            .component_csr => |component_csr| {
                allocator.free(component_csr.name);
                allocator.free(component_csr.id);
            },
        }
    }

    //TODO: Move these to runtime/server
    pub const render = @import("runtime/server/render.zig").render;
    pub const stream = @import("runtime/server/render.zig").stream;

    /// Recursively search for an element by tag name
    /// Returns a mutable pointer to the Component if found, null otherwise
    /// Note: Resolves component_fn lazily during search
    /// Note: Requires allocator to make children mutable if needed
    pub fn getElementByName(self: *Component, allocator: std.mem.Allocator, tag: ElementTag) ?*Component {
        switch (self.*) {
            .element => |*elem| {
                if (elem.tag == tag) {
                    return self;
                }
                // Search in children - need to make children mutable first if they're const
                if (elem.children) |children| {
                    // Allocate mutable copy of children for searching
                    const mutable_children = allocator.alloc(Component, children.len) catch return null;
                    @memcpy(mutable_children, children);
                    elem.children = mutable_children;

                    for (0..mutable_children.len) |i| {
                        var child_mut = &mutable_children[i];
                        if (child_mut.getElementByName(allocator, tag)) |found| {
                            return found;
                        }
                    }
                }
                return null;
            },
            .component_fn => |*func| {
                // Resolve the component function and replace self with the result
                const resolved = func.call() catch return null;
                self.* = resolved;
                // Now search the resolved component
                return self.getElementByName(allocator, tag);
            },
            .none, .text, .component_csr, .signal_text => return null,
        }
    }

    /// Append a child component to an element
    /// Only works if this Component is an element variant
    /// Note: Allocates a new array since children may be const
    pub fn appendChild(self: *Component, allocator: std.mem.Allocator, child: Component) !void {
        switch (self.*) {
            .element => |*elem| {
                if (elem.children) |existing_children| {
                    // Allocate new array and copy existing children + new child
                    const new_children = try allocator.alloc(Component, existing_children.len + 1);
                    @memcpy(new_children[0..existing_children.len], existing_children);
                    new_children[existing_children.len] = child;
                    elem.children = new_children;
                } else {
                    // Allocate new array
                    const new_children = try allocator.alloc(Component, 1);
                    new_children[0] = child;
                    elem.children = new_children;
                }
            },
            else => return error.NotAnElement,
        }
    }

    pub const SerializeOptions = struct {
        only_components: bool = true,
        include_props: bool = true,
        include_attributes: bool = true,
    };

    pub fn format(
        self: *const Component,
        w: *std.Io.Writer,
    ) error{WriteFailed}!void {
        self.formatWithOptions(w, .{}) catch return error.WriteFailed;
    }

    pub fn formatWithOptions(
        self: *const Component,
        w: *std.Io.Writer,
        options: SerializeOptions,
    ) anyerror!void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var serializable = try devtool.ComponentSerializable.init(allocator, self.*, options);
        try serializable.serialize(w);
    }
};

pub const Element = struct {
    pub const Attribute = struct {
        name: []const u8,
        value: ?[]const u8 = null,
        handler: ?zx.EventHandler = null,
    };

    tag: ElementTag,
    children: ?[]const Component = null,
    attributes: ?[]const Element.Attribute = null,

    escaping: ?BuiltinAttribute.Escaping = .html,
    rendering: ?BuiltinAttribute.Rendering = .server,
    async: ?BuiltinAttribute.Async = .sync,
    fallback: ?*const Component = null,
};
