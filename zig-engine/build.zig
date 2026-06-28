// Ω-落尘AGI Zig演化引擎 - 构建脚本
//
// 构建Zig演化引擎，链接Rust种子核静态库
// 实现真正的Zig+Rust混合架构
// 针对Apple M3芯片ARM64架构优化
// 兼容Zig 0.16.0 API

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ============================================================
    // 目标配置 - 显式指定aarch64-macos目标
    // 解决Zig在macOS 26+上native目标链接libc失败的问题
    // 针对Apple M3芯片ARM64架构优化
    // ============================================================
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
        },
    });

    // 极致优化配置：直接指定ReleaseFast（替代standardOptimizeOption，后者在某些Zig版本中默认回退到Debug）
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseFast,
    });

    // ============================================================
    // 创建可执行文件（Zig 0.16.0 API）
    // ============================================================
    const exe = b.addExecutable(.{
        .name = "omega-falling",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // ============================================================
    // 链接Rust种子核静态库
    // ============================================================
    const rust_lib_dir: std.Build.LazyPath = .{ .cwd_relative = "../seed-kernel/target/release" };
    exe.root_module.addLibraryPath(rust_lib_dir);
    exe.root_module.linkSystemLibrary("seed_kernel", .{});
    const macos_framework_dir: std.Build.LazyPath = .{ .cwd_relative = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks" };
    exe.root_module.addFrameworkPath(macos_framework_dir);
    exe.root_module.linkFramework("Accelerate", .{});

    const include_dir: std.Build.LazyPath = .{ .cwd_relative = "../seed-kernel/include" };
    exe.root_module.addIncludePath(include_dir);

    // ============================================================
    // 安装
    // ============================================================
    b.installArtifact(exe);

    // ============================================================
    // 运行步骤
    // ============================================================
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Ω-落尘AGI evolution engine");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // 测试步骤 - 使用独立Debug模块确保测试块被包含
    // （ReleaseFast模式下Zig会剥离所有test块）
    // 使用 test_root.zig 作为入口，确保所有模块的测试被编译
    // ============================================================
    const test_step = b.step("test", "Run all tests");
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    test_module.addLibraryPath(rust_lib_dir);
    test_module.linkSystemLibrary("seed_kernel", .{});
    test_module.addFrameworkPath(macos_framework_dir);
    test_module.linkFramework("Accelerate", .{});
    test_module.addIncludePath(include_dir);
    // 模块名映射：解决 Zig 0.16 禁止 ../ 相对路径跨目录引用的问题
    // 使 src/emergence/*.zig 等子目录文件可通过模块名引用父目录文件
    // 注意：Zig 0.16 addImport 需要 *Module 而非 LazyPath，暂不使用
    const test_exe = b.addTest(.{
        .root_module = test_module,
    });
    test_step.dependOn(&test_exe.step);
    const run_test_cmd = b.addRunArtifact(test_exe);
    test_step.dependOn(&run_test_cmd.step);

    // ============================================================
    // v4.0：涌现性验证测试步骤（白皮书 8.3 / 任务 T4-2/3/4/5/6）
    // 使用独立的 emergence_test_root.zig 作为根模块，
    // 解决 src/emergence/ 子目录中 @import 的模块根路径问题
    // ============================================================
    const emergence_test_step = b.step("test-emergence", "Run emergence validation tests (白皮书 8.3)");
    const emergence_test_module = b.createModule(.{
        .root_source_file = b.path("src/emergence_test_root.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    emergence_test_module.addLibraryPath(rust_lib_dir);
    emergence_test_module.linkSystemLibrary("seed_kernel", .{});
    emergence_test_module.addFrameworkPath(macos_framework_dir);
    emergence_test_module.linkFramework("Accelerate", .{});
    emergence_test_module.addIncludePath(include_dir);

    // ------------------------------------------------------------
    // 模块名映射：解决 Zig 0.16 禁止 ../ 相对路径跨目录引用的问题
    // ------------------------------------------------------------
    // Zig 0.16 模块系统约束：
    //   - @import("xxx.zig") 中的路径必须相对于当前文件所在目录解析
    //   - 子目录文件 (src/emergence/*.zig) 无法用模块名引用父目录文件
    //   - 也无法用 ../ 相对路径跨目录引用
    // 因此通过 addImport 把 src/ 下的核心模块注册为"模块名"，
    // 使 src/emergence/*.zig 可通过模块名引用父目录的 src/*.zig。
    //
    // addImport 第二个参数在 Zig 0.16 中必须是 *Module 而非 LazyPath，
    // 因此需要为每个被引用模块创建对应的子模块并传递相同的构建配置
    // （target/optimize/link_libc + Rust 静态库/系统框架/头文件路径）。
    // ------------------------------------------------------------

    // 创建 src/ 下被引用模块的子模块（共享链接配置）
    // 1) delta_engine：涌现性验证的核心引擎（白皮书 8.3 全章节依赖）
    const delta_engine_module = b.createModule(.{
        .root_source_file = b.path("src/delta_engine.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    delta_engine_module.addLibraryPath(rust_lib_dir);
    delta_engine_module.linkSystemLibrary("seed_kernel", .{});
    delta_engine_module.addFrameworkPath(macos_framework_dir);
    delta_engine_module.linkFramework("Accelerate", .{});
    delta_engine_module.addIncludePath(include_dir);
    emergence_test_module.addImport("delta_engine", delta_engine_module);

    // 2) dust_graph：尘图数据结构（delta_engine 内部依赖，跨模块引用时仍需注册）
    const dust_graph_module = b.createModule(.{
        .root_source_file = b.path("src/dust_graph.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    dust_graph_module.addLibraryPath(rust_lib_dir);
    dust_graph_module.linkSystemLibrary("seed_kernel", .{});
    dust_graph_module.addFrameworkPath(macos_framework_dir);
    dust_graph_module.linkFramework("Accelerate", .{});
    dust_graph_module.addIncludePath(include_dir);
    emergence_test_module.addImport("dust_graph", dust_graph_module);

    // 3) cdl_expr：CDL 表达式引擎（delta_engine 内部依赖，跨模块引用时仍需注册）
    const cdl_expr_module = b.createModule(.{
        .root_source_file = b.path("src/cdl_expr.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    cdl_expr_module.addLibraryPath(rust_lib_dir);
    cdl_expr_module.linkSystemLibrary("seed_kernel", .{});
    cdl_expr_module.addFrameworkPath(macos_framework_dir);
    cdl_expr_module.linkFramework("Accelerate", .{});
    cdl_expr_module.addIncludePath(include_dir);
    emergence_test_module.addImport("cdl_expr", cdl_expr_module);

    // 4) error_types：强类型错误体系
    const error_types_module = b.createModule(.{
        .root_source_file = b.path("src/error_types.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    error_types_module.addLibraryPath(rust_lib_dir);
    error_types_module.linkSystemLibrary("seed_kernel", .{});
    error_types_module.addFrameworkPath(macos_framework_dir);
    error_types_module.linkFramework("Accelerate", .{});
    error_types_module.addIncludePath(include_dir);
    emergence_test_module.addImport("error_types", error_types_module);

    // 5) splitmix64：可播种 CSPRNG 随机数生成器（保障测试可复现）
    const splitmix64_module = b.createModule(.{
        .root_source_file = b.path("src/splitmix64.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    splitmix64_module.addLibraryPath(rust_lib_dir);
    splitmix64_module.linkSystemLibrary("seed_kernel", .{});
    splitmix64_module.addFrameworkPath(macos_framework_dir);
    splitmix64_module.linkFramework("Accelerate", .{});
    splitmix64_module.addIncludePath(include_dir);
    emergence_test_module.addImport("splitmix64", splitmix64_module);

    // 6) strong_ids：强类型 ID 封装（核心实体必须强类型）
    const strong_ids_module = b.createModule(.{
        .root_source_file = b.path("src/strong_ids.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    strong_ids_module.addLibraryPath(rust_lib_dir);
    strong_ids_module.linkSystemLibrary("seed_kernel", .{});
    strong_ids_module.addFrameworkPath(macos_framework_dir);
    strong_ids_module.linkFramework("Accelerate", .{});
    strong_ids_module.addIncludePath(include_dir);
    emergence_test_module.addImport("strong_ids", strong_ids_module);

    // 7) seed_kernel_ffi：Rust 种子核 FFI 绑定
    const seed_kernel_ffi_module = b.createModule(.{
        .root_source_file = b.path("src/seed_kernel_ffi.zig"),
        .target = target,
        .optimize = .Debug,
        .link_libc = true,
    });
    seed_kernel_ffi_module.addLibraryPath(rust_lib_dir);
    seed_kernel_ffi_module.linkSystemLibrary("seed_kernel", .{});
    seed_kernel_ffi_module.addFrameworkPath(macos_framework_dir);
    seed_kernel_ffi_module.linkFramework("Accelerate", .{});
    seed_kernel_ffi_module.addIncludePath(include_dir);
    emergence_test_module.addImport("seed_kernel_ffi", seed_kernel_ffi_module);

    const emergence_test_exe = b.addTest(.{
        .root_module = emergence_test_module,
    });
    emergence_test_step.dependOn(&emergence_test_exe.step);
    const run_emergence_test_cmd = b.addRunArtifact(emergence_test_exe);
    emergence_test_step.dependOn(&run_emergence_test_cmd.step);
}
