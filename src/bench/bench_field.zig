const benchmark = @import("bench.zig").benchmark;
const Felt252 = @import("../math/fields/starknet.zig").Felt252;
const std = @import("std");

const debug = std.debug;
const io = std.io;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const time = std.time;

test "benchmark" {
    try benchmark(struct {
        // How many iterations to run each benchmark.
        // If not present then a default will be used.
        pub const min_iterations = 1;
        pub const max_iterations = 1;

        const a = Felt252.fromInt(
            u256,
            0x6606d7dccf23a0f61182da8d1149497f01b909036384bedb3e4c3284e2f2c1e1,
        );

        const b = Felt252.fromInt(
            u256,
            0x4cd366c0feadabcd6c61a395f6d9f91484ac4e51c3f8aede6c0ab49e2a55446a,
        );

        pub fn bench_add() void {
            _ = a.mul(b);

            // std.debug.print("EMPTY_UNCLE_HASH = {any}\n", .{res});
        }
    });
}
