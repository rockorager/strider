//! Small helpers for building nodes with siv's C API.

const std = @import("std");
const siv = @import("siv");
const c = siv.c;
const Node = siv.Node;
const Txn = siv.Txn;

pub fn commit(txn: Txn) bool {
    const r = c.siv_txn_commit(txn);
    if (r != .ok) std.log.warn("transaction failed: {s}", .{std.mem.span(c.siv_result_name(r))});
    return r == .ok;
}

pub fn px(v: f32) siv.Dimension {
    return .{ .unit = .px, .value = v };
}

pub fn fill() siv.Dimension {
    return .{ .unit = .fraction, .value = 1 };
}

/// One line of text, cut short with an ellipsis when it does not fit.
pub fn text(txn: Txn, parent: Node, s: []const u8, token: siv.ColorToken, role: siv.SizeRole) Node {
    const n = c.siv_text(txn, parent, s.ptr, s.len);
    _ = c.siv_set_text_style(txn, n, &.{ .color_token = token, .size_role = role, .flags = .{ .no_wrap = true, .ellipsize = true } });
    return n;
}

/// Wrapping text.
pub fn paragraph(txn: Txn, parent: Node, s: []const u8, token: siv.ColorToken, role: siv.SizeRole) Node {
    const n = c.siv_text(txn, parent, s.ptr, s.len);
    _ = c.siv_set_text_style(txn, n, &.{ .color_token = token, .size_role = role });
    return n;
}

/// An image node for a themed icon (D19), decorative: rows are named by
/// their text.
pub fn iconView(txn: Txn, parent: Node, size: f32) Node {
    const n = c.siv_image_view(txn, parent, &.{ .icon_size = size });
    _ = c.siv_set_layout(txn, n, &.{ .width = px(size), .height = px(size), .flags = .{ .no_shrink = true }, .align_y = .center });
    _ = c.siv_set_semantics(txn, n, &.{ .role = .none });
    return n;
}

pub fn icon(txn: Txn, parent: Node, name: []const u8, size: f32, token: siv.ColorToken) Node {
    const n = iconView(txn, parent, size);
    _ = c.siv_set_image_view(txn, n, &.{ .icon = name.ptr, .icon_len = name.len, .icon_size = size, .color_token = token });
    return n;
}

/// A horizontal rule.
pub fn rule(txn: Txn, parent: Node) Node {
    const r = c.siv_box(txn, parent);
    _ = c.siv_set_layout(txn, r, &.{ .height = px(1), .flags = .{ .no_shrink = true } });
    _ = c.siv_set_visual(txn, r, &.{ .background_token = .separator });
    _ = c.siv_set_semantics(txn, r, &.{ .role = .none });
    return r;
}

/// A vertical rule.
pub fn vrule(txn: Txn, parent: Node) Node {
    const r = c.siv_box(txn, parent);
    _ = c.siv_set_layout(txn, r, &.{ .width = px(1), .flags = .{ .no_shrink = true } });
    _ = c.siv_set_visual(txn, r, &.{ .background_token = .separator });
    _ = c.siv_set_semantics(txn, r, &.{ .role = .none });
    return r;
}

pub fn button(txn: Txn, parent: Node, label: []const u8, style: siv.ButtonStyle) Node {
    return c.siv_push_button(txn, parent, &.{ .label = label.ptr, .label_len = label.len, .style = style });
}

pub fn iconButton(txn: Txn, parent: Node, label: []const u8, icon_name: []const u8) Node {
    return c.siv_push_button(txn, parent, &.{ .label = label.ptr, .label_len = label.len, .style = .flat, .icon = icon_name.ptr, .icon_len = icon_name.len, .flags = .{ .icon_only = true } });
}

/// Removes every child of `node`.
pub fn clear(txn: Txn, node: Node) void {
    while (true) {
        const child = c.siv_node_get_related(node, .first_child);
        if (child == .null) break;
        _ = c.siv_remove(txn, child);
    }
}

/// Text of an editor or text node, into `buf`.
pub fn getText(node: Node, buf: []u8) []const u8 {
    var len: usize = 0;
    if (c.siv_node_get_text(node, buf.ptr, buf.len, &len) != .ok) return "";
    return buf[0..@min(len, buf.len)];
}
