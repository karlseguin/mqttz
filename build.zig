const std = @import("std");

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const mqttz_module = b.addModule("mqttz", .{
		.root_source_file = b.path("src/mqtt.zig"),
	});

	{
		// Setup Tests
		const lib_test = b.addTest(.{
			.root_source_file = b.path("src/mqtt.zig"),
			.target = target,
			.optimize = optimize,
			.test_runner = b.path("test_runner.zig"),
		});

		const run_test = b.addRunArtifact(lib_test);
		run_test.has_side_effects = true;

		const test_step = b.step("test", "Run unit tests");
		test_step.dependOn(&run_test.step);
	}

	{
		// example
		const exe = b.addExecutable(.{
			.name = "mqttz_example",
			.root_source_file = b.path("example/main.zig"),
			.target = target,
			.optimize = optimize,
		});
		exe.root_module.addImport("mqttz", mqttz_module);
		b.installArtifact(exe);

		const run_cmd = b.addRunArtifact(exe);
		run_cmd.step.dependOn(b.getInstallStep());
		if (b.args) |args| {
				run_cmd.addArgs(args);
		}
		const run_step = b.step("example", "Run the example");
		run_step.dependOn(&run_cmd.step);
	}
}
