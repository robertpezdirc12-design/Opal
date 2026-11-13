//! Pure helpers for the cast LAN bridge (src/services/lan_bridge.zig).
//! Kept std-only so the unit-test step can compile them standalone.

const std = @import("std");

/// True when a URL can be pushed to a TV as-is (it names a network resource).
/// Everything else — Windows paths, UNC, POSIX paths, file:// — is a local
/// file the TV cannot open and needs the bridge.
pub fn isRemoteUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://");
}

/// Pick the local interface IP for the pushed URL: prefer the candidate in
/// the same /24 as the TV (VPN/virtual adapters otherwise win on multi-homed
/// machines), else the first candidate. Returns a slice of `buf`.
pub fn pickHostIp(device_ip: []const u8, candidates: []const []const u8, buf: []u8) ?[]const u8 {
    if (candidates.len == 0) return null;
    var chosen = candidates[0];
    const dev_a = subnetPrefix(device_ip);
    if (dev_a) |prefix| {
        for (candidates) |cand| {
            if (subnetPrefix(cand)) |cp| {
                if (std.mem.eql(u8, prefix, cp)) {
                    chosen = cand;
                    break;
                }
            }
        }
    }
    const n = @min(chosen.len, buf.len);
    @memcpy(buf[0..n], chosen[0..n]);
    return buf[0..n];
}

/// First three octets of a dotted quad, "a.b.c", or null when `ip` isn't one.
fn subnetPrefix(ip: []const u8) ?[]const u8 {
    var dots: usize = 0;
    for (ip) |ch| {
        if (ch == '.') dots += 1;
    }
    if (dots != 3) return null;
    const third = std.mem.lastIndexOfScalar(u8, ip, '.') orelse return null;
    return ip[0..third];
}

test "pickHostIp prefers the TV's subnet" {
    var buf: [46]u8 = undefined;
    const cands = [_][]const u8{ "10.8.0.2", "192.168.1.20" };
    const picked = pickHostIp("192.168.1.55", &cands, &buf);
    try std.testing.expectEqualStrings("192.168.1.20", picked.?);
    try std.testing.expectEqualStrings("10.8.0.2", pickHostIp("10.8.0.99", &cands, &buf).?);
    // No matching subnet → first candidate, never null.
    try std.testing.expectEqualStrings("10.8.0.2", pickHostIp("172.16.0.5", &cands, &buf).?);
    // Non-IP device string still picks a candidate.
    try std.testing.expectEqualStrings("10.8.0.2", pickHostIp("", &cands, &buf).?);
}

test "isRemoteUrl classifies pushable vs local" {
    try std.testing.expect(isRemoteUrl("https://example.com/v.mp4"));
    try std.testing.expect(!isRemoteUrl("C:\\Movies\\film.mkv"));
    try std.testing.expect(!isRemoteUrl("/home/user/film.mkv"));
    try std.testing.expect(!isRemoteUrl("file:///home/user/film.mkv"));
    try std.testing.expect(!isRemoteUrl("\\\\NAS\\share\\film.mkv"));
}
