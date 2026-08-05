load("@bazel_lib//lib:write_source_files.bzl", "write_source_file")
load("//tools:defaults.bzl", "js_binary", "js_run_binary")

_CompatibilityTestInfo = provider(
    fields = [
        "compilation_mode",
        "linker_mode",
        "module_format",
        "typescript_version",
    ],
)

def _compatibility_case_impl(ctx):
    return [
        DefaultInfo(files = depset([ctx.file.src])),
        _CompatibilityTestInfo(
            compilation_mode = ctx.attr.compilation_mode,
            linker_mode = ctx.attr.linker_mode,
            module_format = ctx.attr.module_format,
            typescript_version = ctx.attr.typescript_version,
        ),
    ]

_compatibility_case = rule(
    implementation = _compatibility_case_impl,
    attrs = {
        "compilation_mode": attr.string(mandatory = True),
        "linker_mode": attr.string(mandatory = True),
        "module_format": attr.string(mandatory = True),
        "src": attr.label(allow_single_file = True, mandatory = True),
        "typescript_version": attr.string(mandatory = True),
    },
)

def compatibility_test_matrix(name, srcs, typescript_versions, module_formats, compilation_modes, linker_modes):
    targets = []

    for typescript in typescript_versions:
        for module in module_formats:
            for mode in compilation_modes:
                for linker in linker_modes:
                    for src in srcs:
                        target = "compatibility/%s/%s/%s/%s/%s" % (typescript, module, mode, linker, src)
                        _compatibility_case(
                            name = target,
                            src = src,
                            typescript_version = typescript,
                            module_format = module,
                            compilation_mode = mode,
                            linker_mode = linker,
                            tags = ["manual"],
                        )
                        targets.append(target)

    native.filegroup(
        name = name,
        srcs = targets,
    )

def partial_compliance_golden(filePath):
    """Creates the generate and testing targets for partial compile results.
    """

    # Remove the "TEST_CASES.json" substring from the end of the provided path.
    path = filePath[:-len("/TEST_CASES.json")]
    generate_partial_name = "partial_%s" % path
    data = [
        "//packages/compiler-cli/test/compliance/partial:generate_golden_partial_lib",
        "//packages/core:npm_package",
        "//packages:package_json",
        filePath,
    ] + native.glob(["%s/*.ts" % path, "%s/**/*.html" % path, "%s/**/*.css" % path], allow_empty = True)

    js_binary(
        name = generate_partial_name,
        testonly = True,
        data = data,
        visibility = [":__pkg__"],
        entry_point = "//packages/compiler-cli/test/compliance/partial:cli.js",
        fixed_args = ["$(rootpath %s)" % filePath],
    )

    js_run_binary(
        name = "_generated_%s" % path,
        tool = generate_partial_name,
        testonly = True,
        outs = ["%s/_generated.js" % path],
        # Relativize execpath to be relative to bazel-bin (bazel-out/k8-fastbuild/bin).
        args = ["../../../$(@)"],
        visibility = [":__pkg__"],
        mnemonic = "GeneratePartialGolden",
        progress_message = "Generating partial golden: %{label}",
    )

    write_source_file(
        visibility = ["//visibility:public"],
        name = "%s.golden" % path,
        tags = [
            "partial-golden-compliance-test",
        ],
        testonly = True,
        out_file = "//packages/compiler-cli/test/compliance/test_cases:%s/GOLDEN_PARTIAL.js" % path,
        in_file = "_generated_%s" % path,
    )
