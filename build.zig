const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const zigx_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zigx",
        .branch = null,
        .sha = "5a46e3ee7956739dc678efd82e4fe04b4d349cd2",
    });

    const remoteview_exe = blk: {
        const exe = b.addExecutable("xremoteview", "xremoteview.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();

        exe.step.dependOn(&zigx_repo.step);
        exe.addPackagePath("x", b.pathJoin(&.{ zigx_repo.getPath(&exe.step), "x.zig" }));

        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("remoteview", "Run the xremoteview server");
        run_step.dependOn(&run_cmd.step);
        break :blk exe;
    };

    const snoop_exe = blk: {
        const exe = b.addExecutable("xsnoop", "xsnoop.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();

        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("snoop", "Run the xsnoop server");
        run_step.dependOn(&run_cmd.step);
        break :blk exe;
    };

    {
        const exe = b.addExecutable("both", "both.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();

        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addArtifactArg(remoteview_exe);
        run_cmd.addArtifactArg(snoop_exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("both", "Run both xremoteview and xsnoop");
        run_step.dependOn(&run_cmd.step);
    }
}
