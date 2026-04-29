const std = @import("std");
const Emitter = @import("emitters/emitter.zig").Emitter;

pub const Arch = enum {
    x86_64,
    aarch64,

    pub fn format(self: Arch, writer: *std.Io.Writer) !void {
        return switch (self) {
            .x86_64 => writer.print("x86_64", .{}),
            .aarch64 => writer.print("aarch64", .{}),
        };
    }
};

pub const OS = enum {
    linux,
    macos,

    pub fn format(self: OS, writer: *std.Io.Writer) !void {
        return switch (self) {
            .linux => writer.print("linux", .{}),
            .macos => writer.print("macos", .{}),
        };
    }
};

pub const Target = struct {
    arch: Arch,
    os: OS,

    pub fn current() Target {
        const arch = switch (@import("builtin").cpu.arch) {
            .x86_64 => Arch.x86_64,
            .aarch64 => Arch.aarch64,
            else => @compileError("Unsupported architecture"),
        };

        const os = switch (@import("builtin").os.tag) {
            .linux => OS.linux,
            .macos => OS.macos,
            else => @compileError("Unsupported operating system"),
        };

        return Target{
            .arch = arch,
            .os = os,
        };
    }

    pub fn getEmitter(tgt: Target) Emitter {
        return switch (tgt.arch) {
            .x86_64 => @panic("x86_64 code generation not implemented yet"),
            .aarch64 => switch (tgt.os) {
                .linux => @panic("aarch64 Linux code generation not implemented yet"),
                .macos => @import("emitters/emit_aarch64_macos.zig").emitter,
            },
        };
    }
};
