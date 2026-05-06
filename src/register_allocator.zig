const liveness = @import("liveness.zig");
const std = @import("std");

// zig fmt: off
pub const RegisterName = enum {
    x0, x1, x2, x3, x4, x5, x6, x7, // x0-x7: argument registers
    x8, // x8: indirect result register (used for large return values)
    x9, x10, x11, x12, x13, x14, x15,
    x16, x17, x18, // reserved by system
    x19, x20, x21, x22, x23, x24, x25, x26, x27, x28,
    x29, // frame pointer
    x30, // link register
    
    pub fn toString(self: RegisterName) []const u8 {
        return @tagName(self);
    }
};

// zig fmt: on
pub const Register = struct {
    name: RegisterName,
    kind: enum {
        caller_saved,
        callee_saved,
    },

    pub fn format(self: Register, writer: *std.Io.Writer) !void {
        try writer.print("{s}", .{self.name.toString()});
    }
};

pub const ARGUMENT_REGISTERS = [_]Register{
    .{ .name = .x0, .kind = .caller_saved },
    .{ .name = .x1, .kind = .caller_saved },
    .{ .name = .x2, .kind = .caller_saved },
    .{ .name = .x3, .kind = .caller_saved },
    .{ .name = .x4, .kind = .caller_saved },
    .{ .name = .x5, .kind = .caller_saved },
    .{ .name = .x6, .kind = .caller_saved },
    .{ .name = .x7, .kind = .caller_saved },
};

pub const ALLOCATABLE = [_]Register{
    .{ .name = .x0, .kind = .caller_saved },
    .{ .name = .x1, .kind = .caller_saved },
    .{ .name = .x2, .kind = .caller_saved },
    .{ .name = .x3, .kind = .caller_saved },
    .{ .name = .x4, .kind = .caller_saved },
    .{ .name = .x5, .kind = .caller_saved },
    .{ .name = .x6, .kind = .caller_saved },
    .{ .name = .x7, .kind = .caller_saved },
    // caller-saved, non-argument
    .{ .name = .x9, .kind = .caller_saved },
    .{ .name = .x10, .kind = .caller_saved },
    .{ .name = .x11, .kind = .caller_saved },
    .{ .name = .x12, .kind = .caller_saved },
    .{ .name = .x13, .kind = .caller_saved },
    .{ .name = .x14, .kind = .caller_saved },
    .{ .name = .x15, .kind = .caller_saved },
    // callee-saved
    .{ .name = .x19, .kind = .callee_saved },
    .{ .name = .x20, .kind = .callee_saved },
    .{ .name = .x21, .kind = .callee_saved },
    .{ .name = .x22, .kind = .callee_saved },
    .{ .name = .x23, .kind = .callee_saved },
    .{ .name = .x24, .kind = .callee_saved },
    .{ .name = .x25, .kind = .callee_saved },
    .{ .name = .x26, .kind = .callee_saved },
    .{ .name = .x27, .kind = .callee_saved },
    .{ .name = .x28, .kind = .callee_saved },
};

pub const SCRATCH_REGISTERS = [_]RegisterName{ .x8, .x9, .x16, .x17 };

pub const ScratchPool = struct {
    available: [SCRATCH_REGISTERS.len]bool,

    pub fn init() ScratchPool {
        return ScratchPool{ .available = .{true} ** SCRATCH_REGISTERS.len };
    }

    /// Borrow one scratch register. Returns its name as a string.
    pub fn borrow(self: *ScratchPool) RegisterName {
        for (&self.available, 0..) |*avail, i| {
            if (avail.*) {
                avail.* = false;
                return SCRATCH_REGISTERS[i];
            }
        }
        @panic("scratchpool exhausted");
    }

    /// Release a previously borrowed register back to the pool.
    pub fn release(self: *ScratchPool, reg: RegisterName) void {
        for (SCRATCH_REGISTERS, 0..) |r, i| {
            if (r == reg) {
                std.debug.assert(!self.available[i]); // double-release
                self.available[i] = true;
                return;
            }
        }
        @panic("scratch pool release: unknown register");
    }
};

pub const PhysicalLocation = union(enum) {
    reg: Register,
    stack: isize, // stack offset

    pub fn format(self: PhysicalLocation, writer: *std.Io.Writer) !void {
        switch (self) {
            .reg => |reg| try writer.print("{s}", .{reg.name.toString()}),
            .stack => |offset| try writer.print("[x29, #{d}]", .{offset}),
        }
    }
};

// based on the poletto sarkar paper
pub const RegisterAllocator = struct {
    intervals: []liveness.LiveInterval,
    available_regs: std.ArrayList(Register),
    active_intervals: std.ArrayList(liveness.LiveInterval),
    allocations: std.HashMap(
        liveness.LivenessKey,
        PhysicalLocation,
        liveness.LivenessKeyContext,
        std.hash_map.default_max_load_percentage,
    ),
    spill_count: usize,
    alloc: std.mem.Allocator,
    log: std.ArrayList(AllocEvent),

    pub fn init(intervals: []liveness.LiveInterval, alloc: std.mem.Allocator) !RegisterAllocator {
        var available_regs: std.ArrayList(Register) = .empty;
        for (ALLOCATABLE) |reg| {
            try available_regs.append(alloc, reg);
        }

        return RegisterAllocator{
            .intervals = intervals,
            .available_regs = available_regs,
            .active_intervals = .empty,
            .log = .empty,
            .allocations = std.HashMap(
                liveness.LivenessKey,
                PhysicalLocation,
                liveness.LivenessKeyContext,
                std.hash_map.default_max_load_percentage,
            ).init(alloc),
            .spill_count = 0,
            .alloc = alloc,
        };
    }

    pub fn allocate(self: *RegisterAllocator) !void {
        RegisterAllocator.sortLiveIntervals(self.intervals);

        for (self.intervals) |interval| {
            if (self.allocations.contains(interval.key)) continue;

            try self.expireOldIntervals(interval);

            if (self.available_regs.items.len == 0) {
                // no registers available, need to spill
                try self.spillAtInterval(interval);
            } else {
                // allocate a register
                const reg = self.available_regs.orderedRemove(0);
                _ = try self.allocations.put(interval.key, .{ .reg = reg });
                try self.insertSortedByEndIntoActive(interval);
                try self.log.append(self.alloc, .{
                    .assigned = .{ .key = interval.key, .reg = reg, .interval = interval },
                });
            }
        }
    }

    pub fn preAllocate(self: *RegisterAllocator, key: liveness.LivenessKey, reg: Register) !void {
        try self.allocations.put(key, .{ .reg = reg });
        for (self.available_regs.items, 0..) |r, i| {
            if (r.name == reg.name) {
                _ = self.available_regs.orderedRemove(i);
                break;
            }
        }

        // NOTE: this is a hack to avoid adding the interval to the log event, but it should be fine since pre-allocated intervals should always be active
        try self.log.append(self.alloc, .{
            .assigned = .{ .key = key, .reg = reg, .interval = self.intervals[0] },
        });

        for (self.intervals) |interval| {
            if (std.meta.eql(interval.key, key)) {
                try self.insertSortedByEndIntoActive(interval);
                break;
            }
        }
    }

    pub fn hintCalleeSaved(self: *RegisterAllocator, key: liveness.LivenessKey) !void {
        for (self.available_regs.items, 0..) |reg, i| {
            if (reg.kind == .callee_saved) {
                // pre-color this key to the first available callee-saved reg
                _ = self.available_regs.orderedRemove(i);
                try self.allocations.put(key, .{ .reg = reg });
                for (self.intervals) |interval| {
                    if (std.meta.eql(interval.key, key)) {
                        try self.insertSortedByEndIntoActive(interval);
                        return;
                    }
                }
                return;
            }
        }
    }

    pub fn dumpLog(self: *RegisterAllocator) void {
        std.debug.print("=== Register Allocator Log ===\n", .{});
        for (self.log.items) |event| {
            switch (event) {
                .assigned => |e| std.debug.print(
                    "  assign  {f} -> {s}\n",
                    .{ e.interval, e.reg.name.toString() },
                ),
                .expired => |e| std.debug.print(
                    "  expire  {f} frees {s}\n",
                    .{ e.key, e.reg.name.toString() },
                ),
                .evicted => |e| std.debug.print(
                    "  evict   {f} -> spill{d}  (replaced by {f})\n",
                    .{ e.key, e.offset, e.replacedBy },
                ),
                .spilled => |e| std.debug.print(
                    "  spill   {f} -> spill{d}\n",
                    .{ e.key, e.offset },
                ),
            }
        }
        std.debug.print("=== Final Allocations ===\n", .{});
        var it = self.allocations.iterator();
        while (it.next()) |entry| {
            std.debug.print("  {f} -> {f}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn expireOldIntervals(self: *RegisterAllocator, current: liveness.LiveInterval) !void {
        while (self.active_intervals.items.len > 0) {
            const active = self.active_intervals.items[0];
            if (active.end > current.start) return;
            _ = self.active_intervals.orderedRemove(0);
            if (self.allocations.get(active.key)) |loc| {
                switch (loc) {
                    .reg => |reg| {
                        try self.available_regs.append(self.alloc, reg);
                        std.sort.insertion(
                            Register,
                            self.available_regs.items,
                            {},
                            compareRegisters,
                        );
                        try self.log.append(self.alloc, .{
                            .expired = .{ .key = active.key, .reg = reg },
                        });
                    },
                    .stack => {}, // spilled values do not free a register
                }
            }
        }
    }

    fn spillAtInterval(self: *RegisterAllocator, interval: liveness.LiveInterval) !void {
        const spill = self.active_intervals.items[self.active_intervals.items.len - 1]; // spill the interval with the furthest end
        if (spill.end > interval.end) {
            // evict spill
            const reg = self.allocations.get(spill.key) orelse
                @panic("active interval without register allocation");

            _ = try self.allocations.put(interval.key, .{ .reg = reg.reg }); // NOTE: is this safe?
            // const slot = self.newSpillSlot();

            const offset = self.newSpillOffset();
            _ = try self.allocations.put(spill.key, .{ .stack = offset });
            try self.log.append(self.alloc, .{ .evicted = .{
                .key = spill.key,
                .offset = offset,
                .replacedBy = interval.key,
            } });

            // NOTE: this works but note for future me
            _ = self.active_intervals.swapRemove(self.active_intervals.items.len - 1);
            try self.insertSortedByEndIntoActive(interval);
        } else {
            // spill current
            // const slot = self.newSpillSlot();

            const offset = self.newSpillOffset();
            _ = try self.allocations.put(interval.key, .{ .stack = offset });
            try self.log.append(self.alloc, .{
                .spilled = .{ .key = interval.key, .offset = offset },
            });
        }
    }

    fn newSpillOffset(self: *RegisterAllocator) isize {
        self.spill_count += 1;
        return -@as(isize, @intCast(self.spill_count * 8));
    }

    pub fn insertSortedByEndIntoActive(
        self: *RegisterAllocator,
        interval: liveness.LiveInterval,
    ) !void {
        var i: usize = 0;
        while (i < self.active_intervals.items.len) : (i += 1) {
            if (self.active_intervals.items[i].end > interval.end) break;
        }
        try self.active_intervals.insert(self.alloc, i, interval);
    }

    fn sortLiveIntervals(intervals: []liveness.LiveInterval) void {
        std.sort.block(liveness.LiveInterval, intervals, {}, compareLiveIntervals);
        for (intervals) |interval| {
            std.debug.print("live interval: {f}\n", .{interval});
        }
    }
};

fn compareLiveIntervals(_: void, a: liveness.LiveInterval, b: liveness.LiveInterval) bool {
    return a.start < b.start;
}

fn compareRegisters(_: void, a: Register, b: Register) bool {
    return @intFromEnum(a.name) < @intFromEnum(b.name);
}

// NOTE: used only for debugging
pub const AllocEvent = union(enum) {
    assigned: struct { key: liveness.LivenessKey, reg: Register, interval: liveness.LiveInterval },
    expired: struct { key: liveness.LivenessKey, reg: Register },
    evicted: struct { key: liveness.LivenessKey, offset: isize, replacedBy: liveness.LivenessKey },
    spilled: struct { key: liveness.LivenessKey, offset: isize },
};
