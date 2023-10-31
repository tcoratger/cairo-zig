const std = @import("std");
const Felt252 = @import("../../../math/fields/starknet.zig").Felt252;
const relocatable = @import("../../memory/relocatable.zig");
const Keccak_instance_def = @import("../../types/keccak_instance_def.zig");
const Segments = @import("../../memory/segments.zig");
const Error = @import("../../error.zig");
const CoreVM = @import("../../../vm/core.zig");
const KeccakPrimitives = @import("../../../math/crypto/keccak.zig");

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Allocator = std.mem.Allocator;
const MemorySegmentManager = Segments.MemorySegmentManager;
const MemoryError = Error.MemoryError;
const KeccakInstanceDef = Keccak_instance_def.KeccakInstanceDef;
const Relocatable = relocatable.Relocatable;
const MaybeRelocatable = relocatable.MaybeRelocatable;
const CairoVM = CoreVM.CairoVM;

const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

/// Keccak built-in runner
pub const KeccakBuiltinRunner = struct {
    const Self = @This();

    /// Ratio
    ratio: ?u32,
    /// Base
    base: usize,
    /// Number of cells per instance
    cells_per_instance: u32,
    /// Number of input cells
    n_input_cells: u32,
    /// Stop pointer
    stop_ptr: ?usize,
    /// Included boolean flag
    included: bool,
    state_rep: ArrayList(u32),
    /// Number of instances per component
    instances_per_component: u32,
    /// Cache
    ///
    /// Hashmap between an address in some memory segment and `Felt252` field element
    cache: AutoHashMap(Relocatable, Felt252),

    /// Create a new KeccakBuiltinRunner instance.
    ///
    /// This function initializes a new `KeccakBuiltinRunner` instance with the provided
    /// `allocator`, `instance_def`, and `included` values.
    ///
    /// # Arguments
    ///
    /// - `allocator`: An allocator for initializing the cache.
    /// - `instance_def`: A pointer to the `KeccakInstanceDef` for this runner.
    /// - `included`: A boolean flag indicating whether this runner is included.
    ///
    /// # Returns
    ///
    /// A new `KeccakBuiltinRunner` instance.
    pub fn new(
        allocator: Allocator,
        instance_def: *KeccakInstanceDef,
        included: bool,
    ) Self {
        return .{
            .ratio = instance_def.ratio,
            .base = 0,
            .n_input_cells = @as(
                u32,
                @intCast(instance_def._state_rep.items.len),
            ),
            .cells_per_instance = instance_def.cells_per_builtin(),
            .stop_ptr = null,
            .included = included,
            .state_rep = instance_def._state_rep,
            .instances_per_component = instance_def._instance_per_component,
            .cache = AutoHashMap(Relocatable, Felt252).init(allocator),
        };
    }

    /// Initializes memory segments and sets the base value for the Keccak runner.
    ///
    /// This function adds a memory segment using the provided `segments` manager and
    /// sets the `base` value to the index of the new segment.
    ///
    /// # Parameters
    /// - `segments`: A pointer to the `MemorySegmentManager` for segment management.
    ///
    /// # Modifies
    /// - `self`: Updates the `base` value to the new segment's index.
    pub fn initialize_segments(self: *Self, segments: *MemorySegmentManager) void {
        // `segments.addSegment()` always returns a positive index
        self.base = @as(
            usize,
            @intCast(segments.addSegment().segment_index),
        );
    }

    /// Initializes and returns an `ArrayList` of `MaybeRelocatable` values.
    ///
    /// If the Keccak runner is included, it appends a `Relocatable` element to the `ArrayList`
    /// with the base value. Otherwise, it returns an empty `ArrayList`.
    ///
    /// # Parameters
    /// - `allocator`: An allocator for initializing the `ArrayList`.
    ///
    /// # Returns
    /// An `ArrayList` of `MaybeRelocatable` values.
    pub fn initial_stack(self: *Self, allocator: Allocator) !ArrayList(MaybeRelocatable) {
        var result = ArrayList(MaybeRelocatable).init(allocator);
        if (self.included) {
            try result.append(.{
                .relocatable = Relocatable.new(
                    @as(
                        u64,
                        @intCast(self.base),
                    ),
                    0,
                ),
            });
            return result;
        }
        return result;
    }

    /// Get the base value of this Keccak runner.
    ///
    /// # Returns
    ///
    /// The base value as a `usize`.
    pub fn get_base(self: *const Self) usize {
        return self.base;
    }

    /// Get the ratio of this Keccak runner.
    ///
    /// # Returns
    ///
    /// The ratio as a `u32`, or `null` if not available.
    pub fn get_ratio(self: *const Self) ?u32 {
        return self.ratio;
    }

    /// Get the number of used cells associated with this Keccak runner.
    ///
    /// # Parameters
    ///
    /// - `segments`: A pointer to a `MemorySegmentManager` for segment size information.
    ///
    /// # Returns
    ///
    /// The number of used cells as a `u32`, or `MemoryError.MissingSegmentUsedSizes` if
    /// the size is not available.
    pub fn get_used_cells(self: *const Self, segments: *MemorySegmentManager) !u32 {
        return segments.get_segment_used_size(@as(
            u32,
            @intCast(self.base),
        )) orelse MemoryError.MissingSegmentUsedSizes;
    }

    /// Retrieves memory segment addresses as a tuple.
    ///
    /// Returns a tuple containing the `base` and `stop_ptr` addresses associated
    /// with the Keccak runner's memory segments. The `stop_ptr` may be `null`.
    ///
    /// # Returns
    /// A tuple of `usize` and `?usize` addresses.
    pub fn get_memory_segment_addresses(self: *Self) std.meta.Tuple(&.{
        usize,
        ?usize,
    }) {
        return .{
            self.base,
            self.stop_ptr,
        };
    }

    /// Calculates the number of used instances for the Keccak runner.
    ///
    /// This function computes the number of used instances based on the available
    /// used cells and the number of cells per instance. It performs a ceiling division
    /// to ensure that any remaining cells are counted as an additional instance.
    ///
    /// # Parameters
    /// - `segments`: A pointer to the `MemorySegmentManager` for segment information.
    ///
    /// # Returns
    /// The number of used instances as a `usize`.
    pub fn get_used_instances(self: *Self, segments: *MemorySegmentManager) !usize {
        const used_cells = try self.get_used_cells(segments);
        return std.math.divCeil(
            usize,
            used_cells,
            @as(
                usize,
                @intCast(self.cells_per_instance),
            ),
        );
    }

    /// Retrieves memory access `Relocatable` for the Keccak runner.
    ///
    /// This function returns an `ArrayList` of `Relocatable` elements, each representing
    /// a memory access within the segment associated with the Keccak runner's base.
    ///
    /// # Parameters
    /// - `allocator`: An allocator for initializing the `ArrayList`.
    /// - `vm`: A pointer to the `CairoVM` containing segment information.
    ///
    /// # Returns
    /// An `ArrayList` of `Relocatable` elements.
    pub fn get_memory_accesses(
        self: *Self,
        allocator: Allocator,
        vm: *CairoVM,
    ) !ArrayList(Relocatable) {
        const segment_size = try (vm.segments.get_segment_used_size(@as(
            u32,
            @intCast(self.base),
        )) orelse MemoryError.MissingSegmentUsedSizes);
        var result = ArrayList(Relocatable).init(allocator);
        for (0..segment_size) |i| {
            try result.append(.{
                .segment_index = self.base,
                .offset = i,
            });
        }
        return result;
    }

    /// Calculates the number of used diluted check units for Keccak hashing.
    ///
    /// This function determines the number of used diluted check units based on the
    /// provided `diluted_n_bits`. It takes into account the allocated virtual columns
    /// and embedded real cells, providing a count of used check units.
    ///
    /// # Parameters
    /// - `diluted_n_bits`: The number of bits for the diluted check.
    ///
    /// # Returns
    /// The number of used diluted check units as a `usize`.
    pub fn get_used_diluted_check_units(diluted_n_bits: u32) usize {
        // The diluted cells are:
        // state - 25 rounds times 1600 elements.
        // parity - 24 rounds times 1600/5 elements times 3 auxiliaries.
        // after_theta_rho_pi - 24 rounds times 1600 elements.
        // theta_aux - 24 rounds times 1600 elements.
        // chi_iota_aux - 24 rounds times 1600 elements times 2 auxiliaries.
        // In total 25 * 1600 + 24 * 320 * 3 + 24 * 1600 + 24 * 1600 + 24 * 1600 * 2 = 216640.
        // But we actually allocate 4 virtual columns, of dimensions 64 * 1024, in which we embed the
        // real cells, and we don't free the unused ones.
        // So the real number is 4 * 64 * 1024 = 262144.
        return std.math.divExact(
            usize,
            @as(
                usize,
                @intCast(262144),
            ),
            @as(
                usize,
                @intCast(diluted_n_bits),
            ),
        ) catch 0;
    }

    /// Right-pads a byte slice to a specified final size.
    ///
    /// This function pads the input `bytes` with zero bytes on the right side
    /// to reach the desired `final_size`. It returns the padded data as an ArrayList.
    ///
    /// # Parameters
    /// - `allocator`: An allocator for initializing the ArrayList.
    /// - `bytes`: A pointer to the byte slice to pad.
    /// - `final_size`: The target size after padding.
    ///
    /// # Returns
    /// An ArrayList containing the right-padded bytes.
    fn right_pad(
        allocator: Allocator,
        bytes: *[]u8,
        final_size: usize,
    ) !ArrayList(u8) {
        var bytes_vector = ArrayList(u8).fromOwnedSlice(
            allocator,
            bytes.*,
        );
        try bytes_vector.appendNTimes(
            @as(
                u8,
                @intCast(0),
            ),
            final_size - bytes.len,
        );
        return bytes_vector;
    }

    /// Calculates the Keccak hash of the input message.
    ///
    /// This function computes the Keccak hash of the provided input message and returns
    /// it as an `ArrayList(u8)`. The Keccak hash function involves multiple steps of data
    /// processing.
    ///
    /// # Arguments
    ///
    /// - `allocator`: An allocator for managing memory.
    /// - `input_message`: A pointer to the input message as an array of bytes.
    ///
    /// # Returns
    ///
    /// An `ArrayList(u8)` containing the Keccak hash.
    fn keccak_f(allocator: Allocator, input_message: *[]const u8) !ArrayList(u8) {
        var result = ArrayList(u8).init(allocator);
        var vec = ArrayList(u64).init(allocator);
        defer vec.deinit();

        var i: usize = 0;
        while (i + @sizeOf(u64) <= input_message.len) {
            try vec.append(std.mem.readIntLittle(
                u64,
                @ptrCast(input_message.*[i .. i + @sizeOf(u64)]),
            ));
            i += @sizeOf(u64);
        }

        try vec.appendNTimes(
            0,
            KeccakPrimitives.PLEN - vec.items.len,
        );

        try KeccakPrimitives.keccak_p(
            @ptrCast(
                vec.items.ptr,
            ),
            KeccakPrimitives.KECCAK_F_ROUND_COUNT,
        );

        for (
            @as(
                *[KeccakPrimitives.PLEN]u64,
                @ptrCast(vec.items.ptr),
            ),
        ) |item| {
            var buf: [8]u8 = undefined;
            std.mem.writeIntLittle(u64, buf[0..], item);
            try result.appendSlice(&buf);
        }

        return result;
    }

    /// Frees the resources owned by this instance of `KeccakBuiltinRunner`.
    pub fn deinit(self: *Self) void {
        self.state_rep.deinit();
        self.cache.deinit();
    }
};

test "KeccakBuiltinRunner: initial_stack should return an empty array list if included is false" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    keccak_instance_def.deinit();
    var keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        false,
    );
    var expected = ArrayList(MaybeRelocatable).init(std.testing.allocator);
    defer expected.deinit();
    var actual = try keccak_builtin.initial_stack(std.testing.allocator);
    defer actual.deinit();
    try expectEqual(
        expected,
        actual,
    );
}

test "KeccakBuiltinRunner: initial_stack should return an a proper array list if included is true" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    keccak_instance_def.deinit();
    var keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    keccak_builtin.base = 10;
    var expected = ArrayList(MaybeRelocatable).init(std.testing.allocator);
    try expected.append(.{ .relocatable = .{
        .segment_index = 10,
        .offset = 0,
    } });
    defer expected.deinit();
    var actual = try keccak_builtin.initial_stack(std.testing.allocator);
    defer actual.deinit();
    try expectEqualSlices(
        MaybeRelocatable,
        expected.items,
        actual.items,
    );
}

test "KeccakBuiltinRunner: initialize_segments should modify base field of Keccak built in" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    defer keccak_instance_def.deinit();
    var keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    keccak_builtin.initialize_segments(memory_segment_manager);
    keccak_builtin.initialize_segments(memory_segment_manager);
    try expectEqual(
        @as(usize, @intCast(1)),
        keccak_builtin.base,
    );
}

test "KeccakBuiltinRunner: get_used_cells should return memory error if segment used size is null" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    defer keccak_instance_def.deinit();
    const keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try expectError(
        MemoryError.MissingSegmentUsedSizes,
        keccak_builtin.get_used_cells(memory_segment_manager),
    );
}

test "KeccakBuiltinRunner: get_used_cells should return the number of used cells" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    defer keccak_instance_def.deinit();
    const keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 10);
    try expectEqual(
        @as(
            u32,
            @intCast(10),
        ),
        try keccak_builtin.get_used_cells(memory_segment_manager),
    );
}

test "KeccakBuiltinRunner: get_memory_segment_addresses should return base and stop pointer" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    defer keccak_instance_def.deinit();
    var keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    keccak_builtin.base = 22;
    try expectEqual(
        @as(
            std.meta.Tuple(&.{ usize, ?usize }),
            .{ 22, null },
        ),
        keccak_builtin.get_memory_segment_addresses(),
    );
}

test "KeccakBuiltinRunner: get_used_instances should return memory error if segment used size is null" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    defer keccak_instance_def.deinit();
    var keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try expectError(
        MemoryError.MissingSegmentUsedSizes,
        keccak_builtin.get_used_instances(memory_segment_manager),
    );
}

test "KeccakBuiltinRunner: get_used_instances should return the number of used instances" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    defer keccak_instance_def.deinit();
    var keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    try memory_segment_manager.segment_used_sizes.put(0, 345);
    try expectEqual(
        @as(usize, @intCast(22)),
        try keccak_builtin.get_used_instances(memory_segment_manager),
    );
}

test "KeccakBuiltinRunner: get_memory_accesses should return memory error if segment used size is null" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    defer keccak_instance_def.deinit();
    var keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();
    try expectError(
        MemoryError.MissingSegmentUsedSizes,
        keccak_builtin.get_memory_accesses(
            std.testing.allocator,
            &vm,
        ),
    );
}

test "KeccakBuiltinRunner: get_memory_accesses should return the memory accesses" {
    var keccak_instance_def = try KeccakInstanceDef.default(std.testing.allocator);
    defer keccak_instance_def.deinit();
    var keccak_builtin = KeccakBuiltinRunner.new(
        std.testing.allocator,
        &keccak_instance_def,
        true,
    );
    keccak_builtin.base = 5;
    var memory_segment_manager = try MemorySegmentManager.init(std.testing.allocator);
    defer memory_segment_manager.deinit();
    var vm = try CairoVM.init(
        std.testing.allocator,
        .{},
    );
    defer vm.deinit();
    try vm.segments.segment_used_sizes.put(5, 4);

    var expected = ArrayList(Relocatable).init(std.testing.allocator);
    defer expected.deinit();
    try expected.append(Relocatable{
        .segment_index = 5,
        .offset = 0,
    });
    try expected.append(Relocatable{
        .segment_index = 5,
        .offset = 1,
    });
    try expected.append(Relocatable{
        .segment_index = 5,
        .offset = 2,
    });
    try expected.append(Relocatable{
        .segment_index = 5,
        .offset = 3,
    });
    var actual = try keccak_builtin.get_memory_accesses(
        std.testing.allocator,
        &vm,
    );
    defer actual.deinit();
    try expectEqualSlices(
        Relocatable,
        expected.items,
        actual.items,
    );
}

test "KeccakBuiltinRunner: get_used_diluted_check_units should return used diluted check units" {
    try expectEqual(
        @as(usize, @intCast(16384)),
        KeccakBuiltinRunner.get_used_diluted_check_units(16),
    );
}

test "KeccakBuiltinRunner: get_used_diluted_check_units should return 0 if division by zero" {
    try expectEqual(
        @as(usize, @intCast(0)),
        KeccakBuiltinRunner.get_used_diluted_check_units(0),
    );
}

test "KeccakBuiltinRunner: get_used_diluted_check_units should return 0 if quotient is not an integer" {
    try expectEqual(
        @as(usize, @intCast(0)),
        KeccakBuiltinRunner.get_used_diluted_check_units(12),
    );
}

test "KeccakBuiltinRunner: right_pad should return right pad result" {
    var num = ArrayList(u8).init(std.testing.allocator);
    try num.append(1);
    var num_slice = try num.toOwnedSlice();
    var expected = ArrayList(u8).init(std.testing.allocator);
    defer expected.deinit();
    try expected.append(1);
    try expected.appendNTimes(0, 4);
    var actual = try KeccakBuiltinRunner.right_pad(
        std.testing.allocator,
        &num_slice,
        5,
    );
    defer actual.deinit();
    try expectEqualSlices(
        u8,
        expected.items,
        actual.items,
    );
}

test "KeccakBuiltinRunner: keccak_f" {
    const expected_output_bytes = "\xf6\x98\x81\xe1\x00!\x1f.\xc4*\x8c\x0c\x7fF\xc8q8\xdf\xb9\xbe\x07H\xca7T1\xab\x16\x17\xa9\x11\xff-L\x87\xb2iY.\x96\x82x\xde\xbb\\up?uz:0\xee\x08\x1b\x15\xd6\n\xab\r\x0b\x87T:w\x0fH\xe7!f},\x08a\xe5\xbe8\x16\x13\x9a?\xad~<9\xf7\x03`\x8b\xd8\xa3F\x8aQ\xf9\n9\xcdD\xb7.X\xf7\x8e\x1f\x17\x9e \xe5i\x01rr\xdf\xaf\x99k\x9f\x8e\x84\\\xday`\xf1``\x02q+\x8e\xad\x96\xd8\xff\xff3<\xb6\x01o\xd7\xa6\x86\x9d\xea\xbc\xfb\x08\xe1\xa3\x1c\x06z\xab@\xa1\xc1\xb1xZ\x92\x96\xc0.\x01\x13g\x93\x87!\xa6\xa8z\x9c@\x0bY'\xe7\xa7Qr\xe5\xc1\xa3\xa6\x88H\xa5\xc0@9k:y\xd1Kw\xd5";

    var input_bytes: []const u8 = "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00";

    var actual = try (KeccakBuiltinRunner.keccak_f(
        std.testing.allocator,
        &input_bytes,
    ));
    defer actual.deinit();
    try expectEqualSlices(
        u8,
        expected_output_bytes,
        actual.items,
    );
}
