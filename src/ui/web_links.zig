//! Web links surface — curated legal free-content sites, one click to the
//! system browser. The native embedded browser is macOS/iOS only, so on
//! Windows this surface is how the saved catalog sites stay reachable
//! inside Opal (see docs/FREE-SOURCES.md for the research behind it).

const std = @import("std");
const dvui = @import("dvui");
const icons = @import("icons");
const theme = @import("theme.zig");
const state = @import("../core/state.zig");
const io_global = @import("../core/io_global.zig");
const pure = @import("../services/web_links_pure.zig");

const alloc = @import("../core/alloc.zig").allocator;

/// Hand `url` to the OS browser. Fire-and-forget: the launched browser lives
/// past this call, so the child is never waited on (rare one-shot).
fn openExternal(url: []const u8) bool {
    var buf: [512]u8 = undefined;
    const u = std.fmt.bufPrint(&buf, "{s}", .{url}) catch return false;
    const argv: []const []const u8 = switch (@import("builtin").os.tag) {
        .windows => &.{ "cmd", "/c", "start", "", u },
        .macos => &.{ "open", u },
        else => &.{ "xdg-open", u },
    };
    var child = io_global.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    return true;
}

pub fn renderContent() void {
    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(12) });
    defer page.deinit();

    _ = dvui.label(@src(), "Web links", .{}, .{
        .font = dvui.themeGet().font_body.withSize(18),
        .color_text = .{ .color = theme.colors.text_primary },
    });
    _ = dvui.label(@src(), "Legalni brezplacni viri — en klik odpre sajt v sistemskem brskalniku (katalog pregledan 12.11.2026, docs/FREE-SOURCES.md).", .{}, .{
        .font = dvui.themeGet().font_body.withSize(12),
        .color_text = .{ .color = theme.colors.text_secondary },
    });

    var scroll = dvui.scrollArea(@src(), .{ .vertical = .auto }, .{ .expand = .both });
    defer scroll.deinit();

    var list = dvui.box(@src(), .{ .dir = .vertical }, .{ .padding = dvui.Rect.all(4) });
    defer list.deinit();

    for (pure.LINKS, 0..) |l, i| {
        var card = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = 1000 + i, .expand = .horizontal });
        defer card.deinit();
        var button: dvui.ButtonWidget = undefined;
        button.init(@src(), .{}, .{
            .id_extra = 2000 + i,
            .expand = .horizontal,
            .padding = dvui.Rect.all(10),
            .background = true,
            .color_fill = .{ .color = theme.colors.bg_elevated },
            .corners = theme.dims.rad_md,
        });
        button.processEvents();
        button.drawBackground();

        var inner = dvui.box(@src(), .{ .dir = .vertical }, .{});
        _ = dvui.label(@src(), "{s}", .{l.name}, .{
            .font = dvui.themeGet().font_body.withSize(14),
            .color_text = .{ .color = theme.colors.text_primary },
        });
        _ = dvui.label(@src(), "{s}", .{l.note}, .{
            .font = dvui.themeGet().font_body.withSize(11),
            .color_text = .{ .color = theme.colors.text_secondary },
        });
        inner.deinit();

        if (button.clicked()) {
            if (openExternal(l.url)) {
                state.showToast("Opening in system browser…");
            } else {
                state.showToast("Could not open system browser");
            }
        }
        button.drawFocus();
        button.deinit();
    }
}
