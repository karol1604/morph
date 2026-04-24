const liveness = @import("liveness.zig");
const std = @import("std");

// zig fmt: off
pub const RegisterName = enum {
    x0, x1, x2, x3, x4, x5, x6, x7, x8, x9,
    x10, x11, x12, x13, x14, x15,
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
        CallerSaved,
        CalleeSaved,
    },

    pub fn format(self: Register, writer: *std.io.Writer) !void {
        try writer.print("{s}", .{self.name.toString()});
    }
};

pub const ALLOCATABLE = [_]Register{
    // caller-saved, non-argument
    .{ .name = .x9, .kind = .CallerSaved },
    .{ .name = .x10, .kind = .CallerSaved },
    .{ .name = .x11, .kind = .CallerSaved },
    .{ .name = .x12, .kind = .CallerSaved },
    .{ .name = .x13, .kind = .CallerSaved },
    .{ .name = .x14, .kind = .CallerSaved },
    .{ .name = .x15, .kind = .CallerSaved },
    // callee-saved
    .{ .name = .x19, .kind = .CalleeSaved },
    .{ .name = .x20, .kind = .CalleeSaved },
    .{ .name = .x21, .kind = .CalleeSaved },
    .{ .name = .x22, .kind = .CalleeSaved },
    .{ .name = .x23, .kind = .CalleeSaved },
    .{ .name = .x24, .kind = .CalleeSaved },
    .{ .name = .x25, .kind = .CalleeSaved },
    .{ .name = .x26, .kind = .CalleeSaved },
    .{ .name = .x27, .kind = .CalleeSaved },
    .{ .name = .x28, .kind = .CalleeSaved },
};

pub const Allocation = union(enum) {
    Reg: Register,
    Spill: usize, // stack slot index

    pub fn format(self: Allocation, writer: *std.io.Writer) !void {
        switch (self) {
            .Reg => |reg| try reg.format(writer),
            .Spill => |slot| try writer.print("spill{d}", .{slot}),
        }
    }
};

// based on the poletto sarkar paper
pub const RegisterAllocator = struct {
    intervals: []liveness.LiveInterval,
    availableRegisters: std.ArrayList(Register),
    activeIntervals: std.ArrayList(liveness.LiveInterval),
    allocations: std.HashMap(
        liveness.LivenessKey,
        Allocation,
        liveness.LivenessKeyContext,
        std.hash_map.default_max_load_percentage,
    ),
    spill: usize,
    alloc: std.mem.Allocator,

    pub fn init(intervals: []liveness.LiveInterval, alloc: std.mem.Allocator) !RegisterAllocator {
        var availableRegisters: std.ArrayList(Register) = .empty;
        for (ALLOCATABLE) |reg| {
            try availableRegisters.append(alloc, reg);
        }

        return RegisterAllocator{
            .intervals = intervals,
            .availableRegisters = availableRegisters,
            .activeIntervals = .empty,
            .allocations = std.HashMap(
                liveness.LivenessKey,
                Allocation,
                liveness.LivenessKeyContext,
                std.hash_map.default_max_load_percentage,
            ).init(alloc),
            .spill = 0,
            .alloc = alloc,
        };
    }

    pub fn allocate(self: *RegisterAllocator) !void {
        RegisterAllocator.sortLiveIntervals(self.intervals);

        for (self.intervals) |interval| {
            try self.exprireOldIntervals(interval);

            if (self.availableRegisters.items.len == 0) {
                // no registers available, need to spill
                try self.spillAtInterval(interval);
            } else {
                // allocate a register
                const reg = self.availableRegisters.items[self.availableRegisters.items.len - 1];
                _ = try self.allocations.put(interval.key, .{ .Reg = reg });
                self.availableRegisters.items = self.availableRegisters.items[0 .. self.availableRegisters.items.len - 1];
                try self.insertSortedByEndIntoActive(interval);
                std.debug.print("allocated register {f} to interval {f}\n", .{ reg, interval });
            }
        }
    }

    fn exprireOldIntervals(self: *RegisterAllocator, current: liveness.LiveInterval) !void {
        for (self.activeIntervals.items, 0..) |active, idx| {
            if (active.end >= current.start) return; // active intervals are sorted by end so we can stop here
            _ = self.activeIntervals.swapRemove(idx);
            const reg = self.allocations.get(active.key);
            if (reg) |r| {
                std.debug.print("expiring interval {f} from register {f}\n", .{ active, r });
                try self.availableRegisters.append(self.alloc, r.Reg); // is this safe?
            }
        }
    }

    fn spillAtInterval(self: *RegisterAllocator, interval: liveness.LiveInterval) !void {
        const spill = self.activeIntervals.items[self.activeIntervals.items.len - 1]; // spill the interval with the furthest end
        if (spill.end > interval.end) {
            // evict spill
            const reg = self.allocations.get(spill.key);
            if (reg) |r| {
                _ = try self.allocations.put(interval.key, .{ .Reg = r.Reg }); // NOTE: is this safe?
                std.debug.print("spilling interval {f} from register {f} to make room for {f}\n", .{ spill, r, interval });
                _ = try self.allocations.put(spill.key, .{ .Spill = self.newSpillSlot() });
                _ = self.activeIntervals.swapRemove(self.activeIntervals.items.len - 1);
                try self.insertSortedByEndIntoActive(interval);
            }
        } else {
            // spill current
            _ = try self.allocations.put(interval.key, .{ .Spill = self.newSpillSlot() });
            std.debug.print("spilling interval {f} to stack slot {d}\n", .{ interval, self.spill - 1 });
        }
    }

    fn newSpillSlot(self: *RegisterAllocator) usize {
        const slot = self.spill;
        self.spill += 1;
        return slot;
    }

    fn insertSortedByEndIntoActive(self: *RegisterAllocator, interval: liveness.LiveInterval) !void {
        var i: usize = 0;
        while (i < self.activeIntervals.items.len) : (i += 1) {
            if (self.activeIntervals.items[i].end > interval.end) break;
        }
        try self.activeIntervals.insert(self.alloc, i, interval);
    }

    fn sortLiveIntervals(intervals: []liveness.LiveInterval) void {
        std.sort.block(liveness.LiveInterval, intervals, {}, compareLiveIntervals);
        for (intervals) |interval| {
            std.debug.print("live interval: {f}", .{interval});
        }
    }
};

fn compareLiveIntervals(_: void, a: liveness.LiveInterval, b: liveness.LiveInterval) bool {
    return a.start < b.start;
}
