//! Curated legal free-content web sites shown on the Web links surface.
//! Pure data — no dvui, no state. The UI (ui/web_links.zig) renders the
//! list and hands each URL to the system browser (the native embedded
//! browser is macOS/iOS only, so Windows has no in-app page renderer).
//! Liveness-checked 2026-11-12/13; full research catalog in
//! docs/FREE-SOURCES.md.

const std = @import("std");

pub const Link = struct {
    name: []const u8,
    url: []const u8,
    note: []const u8,
};

pub const LINKS = [_]Link{
    .{ .name = "Cinetimes", .url = "https://cinetimes.org", .note = "Evropska klasika (javna domena)" },
    .{ .name = "RetroFlix", .url = "https://retroflix.org", .note = "Klasicni filmi" },
    .{ .name = "The Classic Movies", .url = "https://www.the-classic-movies.com", .note = "Klasika" },
    .{ .name = "moonflix", .url = "https://moonflix.com", .note = "Restavrirana klasika" },
    .{ .name = "RareFilmm", .url = "https://rarefilmm.com", .note = "Redki filmi" },
    .{ .name = "NFB Kanada", .url = "https://www.nfb.ca", .note = "Ogromen brezplacen arhiv" },
    .{ .name = "Filmzie", .url = "https://filmzie.com", .note = "Indie + klasika (z oglasi)" },
    .{ .name = "Shout! TV", .url = "https://shout-tv.com", .note = "Kult filmi in serije" },
    .{ .name = "RaiPlay", .url = "https://www.raiplay.it", .note = "10.000+ naslovov (tokovi geo-Italija)" },
    .{ .name = "ARTE", .url = "https://www.arte.tv", .note = "FR/DE dokumentarci + filmi" },
    .{ .name = "Red Bull TV", .url = "https://www.redbull.tv", .note = "Sport, v zivo" },
    .{ .name = "Internet Archive filmi", .url = "https://archive.org/details/moviesandfilms", .note = "Javna domena (v Opalu tudi nativno)" },
};

pub fn count() usize {
    return LINKS.len;
}

test "web links: https urls, unique names, nonempty notes" {
    var seen: []const []const u8 = &.{};
    for (LINKS) |l| {
        try std.testing.expect(std.mem.startsWith(u8, l.url, "https://"));
        try std.testing.expect(l.name.len > 0 and l.note.len > 0);
        for (seen) |s| try std.testing.expect(!std.mem.eql(u8, s, l.name));
        seen = seen ++ &[_][]const u8{l.name};
    }
    try std.testing.expect(LINKS.len >= 10);
}
