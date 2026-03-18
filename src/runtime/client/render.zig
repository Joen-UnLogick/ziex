const vdom = @import("../core/vdom.zig");

pub const VDOMTree = vdom;
pub const VNode = vdom.VNode;
pub const VElement = vdom.VElement;
pub const PatchType = vdom.PatchType;
pub const PatchData = vdom.PatchData;
pub const Patch = vdom.Patch;
pub const DiffError = vdom.DiffError;
pub const areComponentsSameType = vdom.areComponentsSameType;

/// Apply a list of patches to the live DOM.
pub fn applyPatches(
    allocator: zx.Allocator,
    client: anytype, // *Client
    patches: std.ArrayList(Patch),
) !void {
    for (patches.items) |*patch| {
        switch (patch.type) {
            .UPDATE => {
                const data = patch.data.UPDATE;
                var attr_iter = data.attributes.iterator();
                while (attr_iter.next()) |entry| {
                    const name = entry.key_ptr.*;
                    const val = entry.value_ptr.*;
                    ext._sa(data.vnode_id, name.ptr, name.len, val.ptr, val.len);
                }
                for (data.removed_attributes.items) |name| {
                    ext._ra(data.vnode_id, name.ptr, name.len);
                }
            },
            .TEXT => {
                const data = patch.data.TEXT;
                ext._snv(data.vnode_id, data.new_text.ptr, data.new_text.len);
            },
            .PLACEMENT => {
                const data = &patch.data.PLACEMENT;

                _ = try createPlatformNodes(allocator, data.vnode, client);

                if (data.reference_id) |ref_id| {
                    ext._ib(data.parent_id, data.vnode.id, ref_id);
                } else {
                    ext._ac(data.parent_id, data.vnode.id);
                }

                if (client.getVElementById(data.parent_id)) |parent_vnode| {
                    const index = @min(data.index, parent_vnode.children.items.len);
                    try parent_vnode.children.insert(allocator, index, data.vnode);
                }
            },
            .DELETION => {
                const data = patch.data.DELETION;

                ext._rc(data.parent_id, data.vnode_id);

                if (client.getVElementById(data.vnode_id)) |vnode| {
                    client.unregisterVElement(vnode);
                }

                if (client.getVElementById(data.parent_id)) |parent_vnode| {
                    for (parent_vnode.children.items, 0..) |child, i| {
                        if (child.id == data.vnode_id) {
                            var removed = parent_vnode.children.orderedRemove(i);
                            removed.deinit(allocator);
                            break;
                        }
                    }
                }
            },
            .REPLACE => {
                const data = &patch.data.REPLACE;

                _ = try createPlatformNodes(allocator, data.new_vnode, client);

                ext._rpc(data.parent_id, data.new_vnode.id, data.old_vnode_id);

                if (client.getVElementById(data.old_vnode_id)) |old_vnode| {
                    client.unregisterVElement(old_vnode);
                }

                if (client.getVElementById(data.parent_id)) |parent_vnode| {
                    for (parent_vnode.children.items, 0..) |child, i| {
                        if (child.id == data.old_vnode_id) {
                            const old = parent_vnode.children.items[i];
                            parent_vnode.children.items[i] = data.new_vnode;
                            old.deinit(allocator);
                            break;
                        }
                    }
                }
            },
            .MOVE => {
                const data = patch.data.MOVE;

                if (data.reference_id) |ref_id| {
                    ext._ib(data.parent_id, data.vnode_id, ref_id);
                } else {
                    ext._ac(data.parent_id, data.vnode_id);
                }

                if (client.getVElementById(data.parent_id)) |parent_vnode| {
                    var old_idx: ?usize = null;
                    for (parent_vnode.children.items, 0..) |child, i| {
                        if (child.id == data.vnode_id) {
                            old_idx = i;
                            break;
                        }
                    }
                    if (old_idx) |idx| {
                        const removed = parent_vnode.children.orderedRemove(idx);
                        const new_idx = @min(data.new_index, parent_vnode.children.items.len);
                        try parent_vnode.children.insert(allocator, new_idx, removed);
                    }
                }
            },
        }
    }
}

/// Build DOM nodes for a VNode subtree and register every node in the JS
pub fn createPlatformNodes(allocator: zx.Allocator, vnode: *VNode, client: anytype) anyerror!Document.HTMLNode {
    if (!is_wasm) return .{ .text = Document.HTMLText.init(allocator, {}) };

    const resolved_component = try vdom.resolveComponent(allocator, vnode.component);

    const node: Document.HTMLNode = switch (resolved_component) {
        .none => blk: {
            const ref_id = ext._ct("".ptr, 0, vnode.id);
            break :blk .{ .text = htmlTextFromRef(allocator, ref_id) };
        },
        .text => |t| blk: {
            const ref_id = ext._ct(t.ptr, t.len, vnode.id);
            break :blk .{ .text = htmlTextFromRef(allocator, ref_id) };
        },
        .element => |elem| blk: {
            const ref_id = ext._ce(@intFromEnum(elem.tag), vnode.id);

            if (elem.attributes) |attrs| {
                var has_action_handler = false;
                var has_method = false;

                for (attrs) |attr| {
                    if (std.mem.eql(u8, attr.name, "key")) continue;
                    if (attr.handler) |handler| {
                        if (handler.action_fn != null) has_action_handler = true;
                        continue;
                    }
                    if (std.mem.eql(u8, attr.name, "method")) has_method = true;
                    const val = attr.value orelse "";
                    ext._sa(vnode.id, attr.name.ptr, attr.name.len, val.ptr, val.len);
                }

                // Mimic Next.js: auto-inject method="post" on form elements with an action handler
                if (elem.tag == .form and has_action_handler and !has_method) {
                    const method = "method";
                    const post = "post";
                    ext._sa(vnode.id, method.ptr, method.len, post.ptr, post.len);
                }
            }

            for (vnode.children.items) |child| {
                _ = try createPlatformNodes(allocator, child, client);
                ext._ac(vnode.id, child.id);
            }

            break :blk .{ .element = htmlElementFromRef(allocator, ref_id) };
        },
        .signal_text => |sig| blk: {
            const ref_id = ext._ct(sig.current_text.ptr, sig.current_text.len, vnode.id);
            const text_node = htmlTextFromRef(allocator, ref_id);
            const reactivity = @import("reactivity.zig");
            reactivity.registerBinding(sig.signal_id, text_node.ref);
            break :blk .{ .text = text_node };
        },
        .component_csr => |csr| blk: {
            // CSR islands: plain <div id="..." data-name="..."> placeholder.
            const ref_id = ext._ce(@intFromEnum(zx.ElementTag.div), vnode.id);
            ext._sa(vnode.id, "id".ptr, "id".len, csr.id.ptr, csr.id.len);
            ext._sa(vnode.id, "data-name".ptr, "data-name".len, csr.name.ptr, csr.name.len);
            break :blk .{ .element = htmlElementFromRef(allocator, ref_id) };
        },
        .component_fn => unreachable,
    };

    // Register VElement for event delegation (id_to_velement, handler_registry).
    client.registerVElement(vnode);
    return node;
}

inline fn htmlElementFromRef(allocator: zx.Allocator, ref_id: u64) Document.HTMLElement {
    const js = @import("js");
    const val: js.Value = @enumFromInt(ref_id);
    return Document.HTMLElement.init(allocator, js.Object{ .value = val });
}

inline fn htmlTextFromRef(allocator: zx.Allocator, ref_id: u64) Document.HTMLText {
    const js = @import("js");
    const val: js.Value = @enumFromInt(ref_id);
    return Document.HTMLText.init(allocator, js.Object{ .value = val });
}

const is_wasm = @import("window.zig").is_wasm;
const ext = @import("window/extern.zig");
const zx = @import("../../root.zig");
const std = @import("std");
const Document = zx.client.Document;
