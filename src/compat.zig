//! Cross-version compatibility shims for Zig 0.16.0 / 0.17.0.
//!
//! Every helper here has an implementation that compiles on BOTH toolchains,
//! so no `@hasField` gating is needed at the call sites.
const std = @import("std");

/// Zig 0.17 removed `Allocator.dupeZ`. Allocate a NUL-terminated copy.
/// `Allocator.allocSentinel` exists in both 0.16 and 0.17.
pub fn dupeZ(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![:0]u8 {
    const out = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

/// Zig 0.17 removed `std.ascii.indexOfIgnoreCase`.
/// `std.ascii.eqlIgnoreCase` exists in both versions.
pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    const last = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= last) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Debug is tag 0 of the optimize enum in every Zig release, but the tag is
/// spelled `.Debug` in 0.16 (`std.builtin.OptimizeMode`) and `.debug` in 0.17
/// (`std.lang.Optimize`). Comparing the ordinal is version-agnostic.
pub const is_debug_build = @backingInt(@import("builtin").mode) == 0;

/// Canonical optimize-mode label normalized across Zig 0.16 (`.ReleaseFast`)
/// and Zig 0.17 (`.fast`) by enum ordinal.
pub const optimize_mode_name: []const u8 = switch (@backingInt(@import("builtin").mode)) {
    0 => "Debug",
    1 => "ReleaseSafe",
    2 => "ReleaseFast",
    3 => "ReleaseSmall",
};

/// Monotonic timestamp in nanoseconds using POSIX `clock_gettime(.MONOTONIC)`.
/// Identical signature and behavior across Zig 0.16.0 and Zig 0.17.x.
pub fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
