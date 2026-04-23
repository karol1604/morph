const std = @import("std");
const ir = @import("ir.zig");
const IRFunction = ir.IRFunction;

// NOTE: is this good?
pub const LivenessKey = union(enum) {
    Temp: usize,
    Var: []const u8,
};

pub const LiveInterval = struct {
    key: LivenessKey,
    start: usize, // instruction index of def
    end: usize, // instruction index of last use
};

const LivenessKeyContext = struct {
    pub fn hash(_: LivenessKeyContext, key: LivenessKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .Temp => |id| {
                hasher.update("t");
                hasher.update(std.mem.asBytes(&id));
            },
            .Var => |name| {
                hasher.update("v");
                hasher.update(name);
            },
        }
        return hasher.final();
    }

    pub fn eql(_: LivenessKeyContext, a: LivenessKey, b: LivenessKey) bool {
        return switch (a) {
            .Temp => |a_id| switch (b) {
                .Temp => |b_id| a_id == b_id,
                .Var => false,
            },
            .Var => |a_name| switch (b) {
                .Var => |b_name| std.mem.eql(u8, a_name, b_name),
                .Temp => false,
            },
        };
    }
};

// basically a hashset
const LivenessSet = std.HashMap(LivenessKey, void, LivenessKeyContext, std.hash_map.default_max_load_percentage);

pub const BlockInfo = struct {
    use: LivenessSet,
    def: LivenessSet,
    liveIn: LivenessSet,
    liveOut: LivenessSet,
    successors: []const usize, // indices of successor blocks
    instrStart: usize, // index of first instruction in block
    instrEnd: usize, // index of last instruction in block

    pub fn format(self: BlockInfo, writer: *std.io.Writer) !void {
        try writer.print("  instrs: [{d}, {d}]\n", .{ self.instrStart, self.instrEnd });

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
        try formatKeySet(self.liveIn, writer);

        try writer.print("  live_out: ", .{});
        try formatKeySet(self.liveOut, writer);
    }

    fn formatKeySet(set: LivenessSet, writer: *std.io.Writer) !void {
        try writer.print("{{ ", .{});
        var it = set.keyIterator();
        while (it.next()) |key| {
            switch (key.*) {
                .Temp => |id| try writer.print("t{d} ", .{id}),
                .Var => |name| try writer.print("{s} ", .{name}),
            }
        }
        try writer.print("}}\n", .{});
    }
};

pub fn analyze(func: *const IRFunction, alloc: std.mem.Allocator) ![]BlockInfo {
    const blocks = try alloc.alloc(BlockInfo, func.blocks.items.len);
    numberInstructions(func, blocks, alloc);
    buildCFG(func, blocks, alloc);
    try computeUseDefSets(func, blocks);
    try computeLiveness(blocks, alloc);
    return blocks;
}

fn numberInstructions(func: *const IRFunction, blocks: []BlockInfo, allocator: std.mem.Allocator) void {
    var counter: usize = 0;
    for (func.blocks.items, 0..) |block, i| {
        blocks[i] = BlockInfo{
            .instrStart = 0,
            .instrEnd = 0,
            .successors = &.{},
            .use = LivenessSet.init(allocator),
            .def = LivenessSet.init(allocator),
            .liveIn = LivenessSet.init(allocator),
            .liveOut = LivenessSet.init(allocator),
        };
        blocks[i].instrStart = counter;
        counter += block.instructions.items.len;
        counter += 1; // terminator
        blocks[i].instrEnd = counter - 1;
    }
}

fn buildCFG(func: *const IRFunction, blocks: []BlockInfo, alloc: std.mem.Allocator) void {
    for (func.blocks.items, 0..) |block, i| {
        const term = block.terminator.?; // TODO: is this safe?
        switch (term) {
            .Return, .Exit => {
                blocks[i].successors = &[_]usize{};
            },
            .Jump => |target| {
                const s = alloc.alloc(usize, 1) catch @panic("allocation failed");
                s[0] = target;
                blocks[i].successors = s;
            },
            .ConditionalJump => |cj| {
                const s = alloc.alloc(usize, 2) catch @panic("allocation failed");
                s[0] = cj.trueTarget;
                s[1] = cj.falseTarget;
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
        .Add => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .Sub => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .Mul => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .Div => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .Eq => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .Neq => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .Lt => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .LtEq => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .Gt => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .GtEq => |op| .{ .inputs = .{ op.left, op.right }, .output = op.result },
        .Assign => |op| .{ .inputs = .{ op.value, null }, .output = op.target },
        .UnaryMinus => |op| .{ .inputs = .{ op.operand, null }, .output = op.result },
        .Call => unreachable, // handled separately
    };
}

fn terminatorInput(term: ir.Terminator) ?ir.Operand {
    return switch (term) {
        .Return => |op| op,
        .Exit => |op| op,
        .Jump => null,
        .ConditionalJump => |cj| cj.condition,
    };
}

fn operandToKey(op: ir.Operand) ?LivenessKey {
    return switch (op.value) {
        .Temp => |id| LivenessKey{ .Temp = id },
        .Variable => |name| LivenessKey{ .Var = name },
        else => null,
    };
}

fn computeUseDefSets(func: *const IRFunction, blocks: []BlockInfo) !void {
    for (func.blocks.items, 0..) |block, i| {
        for (block.instructions.items) |instr| {
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
            const revIdx = blocks.len - 1 - i;
            var newLiveOut = LivenessSet.init(alloc);
            for (blocks[revIdx].successors) |succ| {
                newLiveOut = try mapUnion(newLiveOut, blocks[succ].liveIn, alloc);
            }

            var newLiveIn = LivenessSet.init(alloc);
            newLiveIn = try mapUnion(blocks[revIdx].use, try mapSubstraction(newLiveOut, blocks[revIdx].def, alloc), alloc);

            changed = !setsEqual(newLiveOut, blocks[revIdx].liveOut) or !setsEqual(newLiveIn, blocks[revIdx].liveIn);

            blocks[revIdx].liveOut = newLiveOut;
            blocks[revIdx].liveIn = newLiveIn;
        }
    }
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
