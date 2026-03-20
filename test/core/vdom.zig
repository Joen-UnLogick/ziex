const std = @import("std");
const zx = @import("zx");

const testing = std.testing;
const VDOMTree = zx.util.vdom.VDOMTree;
const VNode = zx.util.vdom.VNode;
const Patch = zx.util.vdom.Patch;

test "same" {
    const allocator = testing.allocator;

    const comp1 = zx.Component{ .element = .{ .tag = .div } };
    const comp2 = zx.Component{ .element = .{ .tag = .div } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), patches.items.len);
}

test "replace tag" {
    const allocator = testing.allocator;

    const child1 = zx.Component{ .element = .{ .tag = .div } };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child1} } };

    const child2 = zx.Component{ .element = .{ .tag = .span } };
    const comp2 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child2} } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.REPLACE, patches.items[0].type);

    if (patches.items.len > 0) {
        patches.items[0].data.REPLACE.new_vnode.deinit(allocator);
    }
}

test "root replace" {
    const allocator = testing.allocator;

    const comp1 = zx.Component{ .element = .{ .tag = .div } };
    const comp2 = zx.Component{ .element = .{ .tag = .span } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    // Parent is null for root, so no REPLACE patch is appended.
    try testing.expectEqual(@as(usize, 0), patches.items.len);
}

test "text update" {
    const allocator = testing.allocator;

    const child1 = zx.Component{ .text = "Hello" };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child1} } };

    const child2 = zx.Component{ .text = "World" };
    const comp2 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child2} } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.TEXT, patches.items[0].type);
    try testing.expectEqualStrings("World", patches.items[0].data.TEXT.new_text);
}

test "attributes update" {
    const allocator = testing.allocator;

    const attr1 = zx.Element.Attribute{ .name = "id", .value = "app" };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .attributes = &[_]zx.Element.Attribute{attr1} } };

    const attr2_1 = zx.Element.Attribute{ .name = "id", .value = "app2" };
    const attr2_2 = zx.Element.Attribute{ .name = "class", .value = "container" };
    const comp2 = zx.Component{ .element = .{ .tag = .div, .attributes = &[_]zx.Element.Attribute{ attr2_1, attr2_2 } } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.UPDATE, patches.items[0].type);

    var update_data = patches.items[0].data.UPDATE;
    defer {
        update_data.attributes.deinit();
        update_data.removed_attributes.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 2), update_data.attributes.count());
    try testing.expectEqualStrings("app2", update_data.attributes.get("id").?);
    try testing.expectEqualStrings("container", update_data.attributes.get("class").?);
}

test "remove attr" {
    const allocator = testing.allocator;

    const attr1 = zx.Element.Attribute{ .name = "class", .value = "btn" };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .attributes = &[_]zx.Element.Attribute{attr1} } };

    const comp2 = zx.Component{ .element = .{ .tag = .div, .attributes = null } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.UPDATE, patches.items[0].type);

    var update_data = patches.items[0].data.UPDATE;
    defer {
        update_data.attributes.deinit();
        update_data.removed_attributes.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 0), update_data.attributes.count());
    try testing.expectEqual(@as(usize, 1), update_data.removed_attributes.items.len);
    try testing.expectEqualStrings("class", update_data.removed_attributes.items[0]);
}

test "placement" {
    const allocator = testing.allocator;

    const comp1 = zx.Component{ .element = .{ .tag = .div, .children = null } };

    const child2 = zx.Component{ .element = .{ .tag = .span } };
    const comp2 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child2} } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.PLACEMENT, patches.items[0].type);

    if (patches.items.len > 0) {
        patches.items[0].data.PLACEMENT.vnode.deinit(allocator);
    }
}

test "deletion" {
    const allocator = testing.allocator;

    const child1 = zx.Component{ .element = .{ .tag = .span } };
    const comp1 = zx.Component{ .element = .{ .tag = .div, .children = &[_]zx.Component{child1} } };

    const comp2 = zx.Component{ .element = .{ .tag = .div, .children = null } };

    var tree = VDOMTree.init(allocator, comp1);
    defer tree.deinit(allocator);

    var patches = try tree.diffWithComponent(allocator, comp2);
    defer patches.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), patches.items.len);
    try testing.expectEqual(.DELETION, patches.items[0].type);
}
