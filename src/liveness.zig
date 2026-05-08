const std = @import("std");
const ir = @import("ir.zig");
const IRFunction = ir.IRFunction;

// NOTE: is this good?
pub const LivenessKey = union(enum) {
    temp: usize,
    variable: []const u8,

    pub fn format(self: LivenessKey, writer: *std.Io.Writer) !void {
        switch (self) {
            .temp => |id| try writer.print("Temp(t{d})", .{id}),
            .variable => |name| try writer.print("Var({s})", .{name}),
        }
    }
};

pub const LiveInterval = struct {
    key: LivenessKey,
    start: usize, // instruction index of def
    end: usize, // instruction index of last use

    pub fn format(self: LiveInterval, writer: *std.Io.Writer) !void {
        try writer.print("LiveInterval {{ ", .{});
        switch (self.key) {
            .temp => |id| try writer.print("Temp(t{d}) ", .{id}),
            .variable => |name| try writer.print("Var({s}) ", .{name}),
        }
        try writer.print("start: {d}, end: {d} }}", .{ self.start, self.end });
    }
};

pub const LivenessKeyContext = struct {
    pub fn hash(_: LivenessKeyContext, key: LivenessKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .temp => |id| {
                hasher.update("t");
                hasher.update(std.mem.asBytes(&id));
            },
            .variable => |name| {
                hasher.update("v");
                hasher.update(name);
            },
        }
        return hasher.final();
    }

    pub fn eql(_: LivenessKeyContext, a: LivenessKey, b: LivenessKey) bool {
        return switch (a) {
            .temp => |a_id| switch (b) {
                .temp => |b_id| a_id == b_id,
                .variable => false,
            },
            .variable => |a_name| switch (b) {
                .variable => |b_name| std.mem.eql(u8, a_name, b_name),
                .temp => false,
            },
        };
    }
};

// basically a hashset
const LivenessSet = std.HashMap(
    LivenessKey,
    void,
    LivenessKeyContext,
    std.hash_map.default_max_load_percentage,
);

pub const BlockInfo = struct {
    use: LivenessSet,
    def: LivenessSet,
    live_in: LivenessSet,
    live_out: LivenessSet,
    successors: []const usize, // indices of successor blocks
    instr_start: usize, // index of first instruction in block
    instr_end: usize, // index of last instruction in block

    pub fn format(self: BlockInfo, writer: *std.Io.Writer) !void {
        try writer.print("  instrs: [{d}, {d}]\n", .{ self.instr_start, self.instr_end });

        try writer.print("  successors: [", .{});
        for (self.successors, 0..) |succ, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("{d}", .{succ});
        }
        try writer.print("]\n", .{});

        try writer.print("  use:      ", .{});
        try formatKeySet(self.use, writer);

        try writer.print("  def:      ", .{});
        try formatKeySet(self.def, writer);

        try writer.print("  live_in:  ", .{});
        try formatKeySet(self.live_in, writer);

        try writer.print("  live_out: ", .{});
        try formatKeySet(self.live_out, writer);
    }

    fn formatKeySet(set: LivenessSet, writer: *std.Io.Writer) !void {
        try writer.print("{{ ", .{});
        var it = set.keyIterator();
        while (it.next()) |key| {
            switch (key.*) {
                .temp => |id| try writer.print("t{d} ", .{id}),
                .variable => |name| try writer.print("{s} ", .{name}),
            }
        }
        try writer.print("}}\n", .{});
    }
};

pub fn analyze(func: *const IRFunction, alloc: std.mem.Allocator) ![]LiveInterval {
    const blocks = try alloc.alloc(BlockInfo, func.blocks.items.len);
    numberInstructions(func, blocks, alloc);
    const index_map = try buildBlockIndexMap(func, alloc);
    buildCFG(func, blocks, alloc, index_map);
    try computeUseDefSets(func, blocks);
    try computeLiveness(blocks, alloc);
    return try buildIntervals(func, blocks, alloc);
}

fn numberInstructions(
    func: *const IRFunction,
    blocks: []BlockInfo,
    allocator: std.mem.Allocator,
) void {
    var counter: usize = 0;
    for (func.blocks.items, 0..) |block, i| {
        blocks[i] = BlockInfo{
            .instr_start = 0,
            .instr_end = 0,
            .successors = &.{},
            .use = LivenessSet.init(allocator),
            .def = LivenessSet.init(allocator),
            .live_in = LivenessSet.init(allocator),
            .live_out = LivenessSet.init(allocator),
        };
        blocks[i].instr_start = counter;
        counter += block.instructions.items.len;
        counter += 1; // terminator
        blocks[i].instr_end = counter - 1;
    }
}

fn buildBlockIndexMap(
    func: *const IRFunction,
    alloc: std.mem.Allocator,
) !std.AutoHashMap(usize, usize) {
    var map = std.AutoHashMap(usize, usize).init(alloc);
    for (func.blocks.items, 0..) |block, localIdx| {
        try map.put(block.id, localIdx);
    }
    return map;
}

fn buildCFG(
    func: *const IRFunction,
    blocks: []BlockInfo,
    alloc: std.mem.Allocator,
    index_map: std.AutoHashMap(usize, usize),
) void {
    for (func.blocks.items, 0..) |block, i| {
        const term = block.terminator.?; // TODO: is this safe?
        switch (term) {
            .@"return", .exit => {
                blocks[i].successors = &[_]usize{};
            },
            .jump => |target| {
                const s = alloc.alloc(usize, 1) catch @panic("allocation failed");
                s[0] = index_map.get(target).?; // get local index of target block
                blocks[i].successors = s;
            },
            .cond_jump => |cj| {
                const s = alloc.alloc(usize, 2) catch @panic("allocation failed");
                s[0] = index_map.get(cj.true_target).?;
                s[1] = index_map.get(cj.false_target).?;
                blocks[i].successors = s;
            },
        }
    }
}

pub const InstrOperands = struct {
    inputs: [2]?ir.Operand,
    output: ?ir.Operand,
};

fn instrInputsAndOutput(instr: ir.Instr) InstrOperands {
    return switch (instr) {
        .add => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .sub => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .mul => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .div => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .eq => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .neq => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .lt => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .lt_eq => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .gt => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .gt_eq => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .assign => |op| .{ .inputs = .{ op.value, null }, .output = op.target },
        .unary_minus => |op| .{ .inputs = .{ op.operand, null }, .output = op.result },
        .unary_not => |op| .{ .inputs = .{ op.operand, null }, .output = op.result },
        .call, .tail_call => unreachable, // handled separately
    };
}

fn terminatorInput(term: ir.Terminator) ?ir.Operand {
    return switch (term) {
        .@"return" => |op| op,
        .exit => |op| op,
        .jump => null,
        .cond_jump => |cj| cj.condition,
    };
}

fn operandToKey(op: ir.Operand) ?LivenessKey {
    return switch (op.value) {
        .temp => |id| LivenessKey{ .temp = id },
        .variable => |name| LivenessKey{ .variable = name },
        else => null,
    };
}

fn computeUseDefSets(func: *const IRFunction, blocks: []BlockInfo) !void {
    for (func.blocks.items, 0..) |block, i| {
        for (block.instructions.items) |instr| {
            switch (instr) {
                .call => |call| {
                    for (call.args) |arg| {
                        if (operandToKey(arg)) |key| {
                            if (!blocks[i].def.contains(key)) try blocks[i].use.put(key, {});
                        }
                    }
                    if (operandToKey(call.result)) |key| {
                        if (!blocks[i].use.contains(key)) try blocks[i].def.put(key, {});
                    }
                },
                .tail_call => |call| {
                    for (call.args) |arg| {
                        if (operandToKey(arg)) |key| {
                            if (!blocks[i].def.contains(key)) try blocks[i].use.put(key, {});
                        }
                    }
                    // no need to def anything here since tail call result is not used
                },
                else => {
                    const ops = instrInputsAndOutput(instr);
                    for (ops.inputs) |input| {
                        if (input) |op| {
                            if (operandToKey(op)) |key| {
                                if (!blocks[i].def.contains(key)) try blocks[i].use.put(key, {});
                            }
                        }
                    }
                    if (ops.output) |op| {
                        if (operandToKey(op)) |key| {
                            if (!blocks[i].use.contains(key)) try blocks[i].def.put(key, {});
                        }
                    }
                },
            }
        }
        if (block.terminator) |term| {
            if (terminatorInput(term)) |input| {
                if (operandToKey(input)) |key| {
                    if (!blocks[i].def.contains(key)) try blocks[i].use.put(key, {});
                }
            }
        }
    }
}

fn computeLiveness(blocks: []BlockInfo, alloc: std.mem.Allocator) !void {
    var changed = true;
    while (changed) {
        changed = false;
        for (0..blocks.len) |i| {
            const rev_idx = blocks.len - 1 - i;
            var new_live_out = LivenessSet.init(alloc);
            for (blocks[rev_idx].successors) |succ| {
                new_live_out = try mapUnion(new_live_out, blocks[succ].live_in, alloc);
            }

            var new_live_in = LivenessSet.init(alloc);
            new_live_in = try mapUnion(
                blocks[rev_idx].use,
                try mapSubstraction(new_live_out, blocks[rev_idx].def, alloc),
                alloc,
            );

            changed = changed or
                !setsEqual(new_live_out, blocks[rev_idx].live_out) or
                !setsEqual(new_live_in, blocks[rev_idx].live_in);

            blocks[rev_idx].live_out = new_live_out;
            blocks[rev_idx].live_in = new_live_in;
        }
    }
}

fn buildIntervals(
    func: *const IRFunction,
    blocks: []BlockInfo,
    alloc: std.mem.Allocator,
) ![]LiveInterval {
    var interval_map = std.HashMap(
        LivenessKey,
        LiveInterval,
        LivenessKeyContext,
        std.hash_map.default_max_load_percentage,
    ).init(alloc);
    for (blocks, func.blocks.items) |blockInfo, irBlock| {
        var it = blockInfo.live_in.keyIterator();
        while (it.next()) |key| {
            const entry = try interval_map.getOrPut(key.*);
            if (!entry.found_existing) {
                entry.value_ptr.* = LiveInterval{
                    .key = key.*,
                    .start = blockInfo.instr_start,
                    .end = blockInfo.instr_end,
                };
            } else {
                entry.value_ptr.end = @max(entry.value_ptr.end, blockInfo.instr_end);
            }
        }

        for (irBlock.instructions.items, 0..) |instr, i| {
            const idx = blockInfo.instr_start + i;

            switch (instr) {
                .call => |call| {
                    // inputs: all args
                    for (call.args) |arg| {
                        if (operandToKey(arg)) |key| {
                            const entry = try interval_map.getOrPut(key);
                            if (!entry.found_existing) {
                                entry.value_ptr.* = .{ .key = key, .start = idx, .end = idx };
                            } else {
                                entry.value_ptr.end = @max(entry.value_ptr.end, idx);
                            }
                        }
                    }
                    // output: result
                    if (operandToKey(call.result)) |key| {
                        const entry = try interval_map.getOrPut(key);
                        if (!entry.found_existing) {
                            entry.value_ptr.* = .{ .key = key, .start = idx, .end = idx };
                        }
                    }
                },
                .tail_call => |call| {
                    for (call.args) |arg| {
                        if (operandToKey(arg)) |key| {
                            const entry = try interval_map.getOrPut(key);
                            if (!entry.found_existing) {
                                entry.value_ptr.* = .{ .key = key, .start = idx, .end = idx };
                            } else {
                                entry.value_ptr.end = @max(entry.value_ptr.end, idx);
                            }
                        }
                    }
                    // no result operand so nothing to def
                },
                else => {
                    const ops = instrInputsAndOutput(instr);

                    for (ops.inputs) |maybeInput| {
                        if (maybeInput) |op| {
                            if (operandToKey(op)) |key| {
                                const entry = try interval_map.getOrPut(key);
                                if (!entry.found_existing) {
                                    entry.value_ptr.* = LiveInterval{
                                        .key = key,
                                        .start = idx,
                                        .end = idx,
                                    };
                                } else {
                                    entry.value_ptr.end = @max(entry.value_ptr.end, idx);
                                }
                            }
                        }
                    }

                    if (ops.output) |op| {
                        if (operandToKey(op)) |key| {
                            const entry = try interval_map.getOrPut(key);
                            if (!entry.found_existing) {
                                entry.value_ptr.* = LiveInterval{
                                    .key = key,
                                    .start = idx,
                                    .end = idx,
                                };
                            }
                            // entry.value_ptr.end = @max(entry.value_ptr.end, idx);
                        }
                    }
                },
            }
        }

        if (irBlock.terminator) |term| {
            if (terminatorInput(term)) |op| {
                if (operandToKey(op)) |key| {
                    const entry = try interval_map.getOrPut(key);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = LiveInterval{
                            .key = key,
                            .start = blockInfo.instr_end, // terminator is after all instructions
                            .end = blockInfo.instr_end,
                        };
                    } else {
                        entry.value_ptr.end = @max(entry.value_ptr.end, blockInfo.instr_end);
                    }
                }
            }
        }
    }

    var result = try alloc.alloc(LiveInterval, interval_map.count());
    var it2 = interval_map.valueIterator();
    var idx: usize = 0;
    while (it2.next()) |entry| {
        result[idx] = entry.*;
        idx += 1;
    }

    return result;
}

fn mapUnion(a: LivenessSet, b: LivenessSet, alloc: std.mem.Allocator) !LivenessSet {
    var result = LivenessSet.init(alloc);
    var it = a.keyIterator();
    while (it.next()) |key| {
        try result.put(key.*, {});
    }
    it = b.keyIterator();
    while (it.next()) |key| {
        if (!result.contains(key.*)) try result.put(key.*, {});
    }
    return result;
}

fn mapSubstraction(a: LivenessSet, b: LivenessSet, alloc: std.mem.Allocator) !LivenessSet {
    var result = LivenessSet.init(alloc);
    var it = a.keyIterator();
    while (it.next()) |key| {
        if (!b.contains(key.*)) try result.put(key.*, {});
    }
    return result;
}

fn setsEqual(a: LivenessSet, b: LivenessSet) bool {
    var it = a.keyIterator();
    while (it.next()) |key| {
        if (!b.contains(key.*)) return false;
    }
    it = b.keyIterator();
    while (it.next()) |key| {
        if (!a.contains(key.*)) return false;
    }
    return true;
}
