# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""An aspect attached to `proto_library` targets to generate Swift artifacts."""

load("@build_bazel_rules_swift//swift/internal:api.bzl", "swift_common")
load("@build_bazel_rules_swift//swift/internal:providers.bzl", "SwiftProtoInfo", "SwiftToolchainInfo")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:paths.bzl", "paths")

# The paths of well known type protos that should not be generated by the aspect
# because they are already included in the SwiftProtobuf runtime. The plugin
# provides the mapping from these protos to the SwiftProtobuf module for us.
# TODO(b/63389580): Once we migrate to proto_lang_toolchain, this information
# can go in the blacklisted_protos list instead.
_WELL_KNOWN_TYPE_PATHS = [
    "google/protobuf/any.proto",
    "google/protobuf/api.proto",
    "google/protobuf/duration.proto",
    "google/protobuf/empty.proto",
    "google/protobuf/field_mask.proto",
    "google/protobuf/source_context.proto",
    "google/protobuf/struct.proto",
    "google/protobuf/timestamp.proto",
    "google/protobuf/type.proto",
    "google/protobuf/wrappers.proto",
]

def _workspace_relative_path(f):
    """Returns the path of a file relative to its workspace.

    Args:
      f: The File object.

    Returns:
      The path of the file relative to its workspace.
    """
    wpath = paths.join(f.root.path, f.owner.workspace_root)
    return paths.relativize(f.path, wpath)

def _filter_out_well_known_types(srcs):
    """Returns the given list of files, excluding any well-known type protos.

    Args:
      srcs: A list of `.proto` files.

    Returns:
      The given list of files with any well-known type protos (those living under
      the `google.protobuf` package) removed.
    """
    return [
        f
        for f in srcs
        if _workspace_relative_path(f) not in _WELL_KNOWN_TYPE_PATHS
    ]

def _pbswift_file_path(target, proto_file = None):
    """Returns the `.pb.swift` short path corresponding to a `.proto` file.

    The returned workspace-relative path should be used to declare output files so
    that they are generated relative to the target's package in the output
    directory tree.

    If `proto_file` is `None` (or unspecified), then this function returns the
    workspace-relative path to the `%{target_name}.protoc_gen_swift` directory
    where the `.pb.swift` files would be generated.

    Args:
      target: The target currently being analyzed.
      proto_file: The `.proto` file whose `.pb.swift` path should be computed.

    Returns:
      The workspace-relative path of the `.pb.swift` file that will be generated
      for the given `.proto` file, or the workspace-relative path to the
      `.protoc_gen_swift` that contains the declared `.pb.swift` files if
      `proto_file` is `None`.
    """
    dir_path = target.label.name + ".protoc_gen_swift"
    if proto_file:
        pbswift_path = paths.replace_extension(
            _workspace_relative_path(proto_file),
            ".pb.swift",
        )
        return paths.join(dir_path, pbswift_path)
    return dir_path

def _declare_pbswift_files(target, actions, proto_srcs):
    """Declares `.pb.swift` files that correspond to a list of `.proto` files.

    Args:
      target: The target relative to which the files should be declared.
      actions: The context's actions object.
      proto_srcs: A list of `.proto` files.

    Returns:
      A list of files that map one-to-one to `proto_srcs` but with `.pb.swift`
      extensions instead of `.proto`.
    """
    return [
        actions.declare_file(_pbswift_file_path(target, f))
        for f in proto_srcs
    ]

def _extract_pbswift_dir_path(target, pbswift_files):
    """Extracts the full path to the `.protoc_gen_swift` directory.

    This dance is required because we cannot get the full (repository-relative)
    path to the directory that we need to pass to `protoc` unless we either create
    the directory as a tree artifact or extract it from a file within that
    directory. We cannot do the former because we also want to declare individual
    outputs for the files we generate, and we can't declare a directory that has
    the same prefix as any of the files we generate. So, we assume we have at
    least one file and we extract the path from it.

    Args:
      target: The target being analyzed.
      pbswift_files: A list of `.pb.swift` files, one of which will be used to
          extract the directory path.

    Returns:
      The repository-relative path to the `.protoc_gen_swift` directory underneath
      the output directory for the given target.
    """
    if not pbswift_files:
        return None

    first_path = pbswift_files[0].path
    dir_name = _pbswift_file_path(target)
    offset = first_path.find(dir_name)
    return first_path[:offset + len(dir_name)]

def _register_pbswift_generate_action(
        target,
        actions,
        direct_srcs,
        transitive_descriptor_sets,
        module_mapping_file,
        mkdir_and_run,
        protoc_executable,
        protoc_gen_swift_executable):
    """Registers the actions that generate `.pb.swift` files from `.proto` files.

    Args:
      target: The `proto_library` target being analyzed.
      actions: The context's actions object.
      direct_srcs: The direct `.proto` sources belonging to the target being
          analyzed, which will be passed to `protoc-gen-swift`.
      transitive_descriptor_sets: The transitive `DescriptorSet`s from the
          `proto_library` being analyzed.
      module_mapping_file: The `File` containing the mapping between `.proto`
          files and Swift modules for the transitive dependencies of the target
          being analyzed. May be `None`, in which case no module mapping will be
          passed (the case for leaf nodes in the dependency graph).
      mkdir_and_run: The `File` representing the `mkdir_and_run` executable.
      protoc_executable: The `File` representing the `protoc` executable.
      protoc_gen_swift_executable: The `File` representing the `protoc-gen-swift`
          plugin executable.

    Returns:
      A list of generated `.pb.swift` files corresponding to the `.proto` sources.
    """
    pbswift_files = _declare_pbswift_files(target, actions, direct_srcs)
    pbswift_dir_path = _extract_pbswift_dir_path(target, pbswift_files)

    mkdir_args = actions.args()
    mkdir_args.add(pbswift_dir_path)

    protoc_executable_args = actions.args()
    protoc_executable_args.add(protoc_executable)

    protoc_args = actions.args()

    # protoc takes an arg of @NAME as something to read, and expects one
    # arg per line in that file.
    protoc_args.set_param_file_format("multiline")
    protoc_args.use_param_file("@%s")

    protoc_args.add(
        protoc_gen_swift_executable,
        format = "--plugin=protoc-gen-swift=%s",
    )
    protoc_args.add(pbswift_dir_path, format = "--swift_out=%s")
    protoc_args.add("--swift_opt=FileNaming=FullPath")
    protoc_args.add("--swift_opt=Visibility=Public")
    if module_mapping_file:
        protoc_args.add(
            module_mapping_file,
            format = "--swift_opt=ProtoPathModuleMappings=%s",
        )
    protoc_args.add("--descriptor_set_in")
    protoc_args.add_joined(transitive_descriptor_sets, join_with = ":")
    protoc_args.add_all([_workspace_relative_path(f) for f in direct_srcs])

    additional_command_inputs = [
        mkdir_and_run,
        protoc_executable,
        protoc_gen_swift_executable,
    ]
    if module_mapping_file:
        additional_command_inputs.append(module_mapping_file)

    # TODO(b/23975430): This should be a simple `actions.run_shell`, but until the
    # cited bug is fixed, we have to use the wrapper script.
    actions.run(
        arguments = [mkdir_args, protoc_executable_args, protoc_args],
        executable = mkdir_and_run,
        # TODO(b/79093417): Remove the Darwin requirement when we're building the
        # generator on Linux.
        execution_requirements = {"requires-darwin": ""},
        inputs = depset(
            direct = additional_command_inputs,
            transitive = [transitive_descriptor_sets],
        ),
        mnemonic = "ProtocGenSwift",
        outputs = pbswift_files,
        progress_message = "Generating Swift sources for {}".format(target.label),
    )

    return pbswift_files

def _build_swift_proto_info_provider(
        pbswift_files,
        transitive_module_mappings,
        deps):
    """Builds the `SwiftProtoInfo` provider to propagate for a proto library.

    Args:
      pbswift_files: The `.pb.swift` files that were generated for the propagating
          target. This sequence should only contain the direct sources.
      transitive_module_mappings: A sequence of `structs` with `module_name` and
          `proto_file_paths` fields that denote the transitive mappings from
          `.proto` files to Swift modules.
      deps: The direct dependencies of the propagating target, from which the
          transitive sources will be computed.

    Returns:
      An instance of `SwiftProtoInfo`.
    """
    return SwiftProtoInfo(
        module_mappings = transitive_module_mappings,
        pbswift_files = depset(
            direct = pbswift_files,
            transitive = [dep[SwiftProtoInfo].pbswift_files for dep in deps],
        ),
    )

def _build_module_mapping_from_srcs(target, proto_srcs):
    """Returns the sequence of module mapping `struct`s for the given sources.

    Args:
      target: The `proto_library` target whose module mapping is being rendered.
      proto_srcs: The `.proto` files that belong to the target.

    Returns:
      A string containing the module mapping for the target in protobuf text
      format.
    """

    # TODO(allevato): The previous use of f.short_path here caused problems with
    # cross-repo references; protoc-gen-swift only processes the file correctly if
    # the workspace-relative path is used (which is the same as the short_path for
    # same-repo references, so this issue had never been caught). However, this
    # implies that if two repos have protos with the same workspace-relative
    # paths, there will be a clash. Figure out what to do here; it may require an
    # update to protoc-gen-swift?
    return struct(
        module_name = swift_common.derive_module_name(target.label),
        proto_file_paths = [_workspace_relative_path(f) for f in proto_srcs],
    )

def _gather_transitive_module_mappings(targets):
    """Returns the set of transitive module mappings for the given targets.

    This function eliminates duplicates among the targets so that if two or more
    targets transitively depend on the same `proto_library`, the mapping is only
    present in the sequence once.

    Args:
      targets: The targets whose module mappings should be returned.

    Returns:
      A sequence containing the transitive module mappings for the given targets,
      without duplicates.
    """
    unique_mappings = {}

    for target in targets:
        mappings = target[SwiftProtoInfo].module_mappings
        for mapping in mappings:
            module_name = mapping.module_name
            if module_name not in unique_mappings:
                unique_mappings[module_name] = mapping.proto_file_paths

    return [struct(
        module_name = module_name,
        proto_file_paths = file_paths,
    ) for module_name, file_paths in unique_mappings.items()]

def _render_text_module_mapping(mapping):
    """Renders the text format proto for a module mapping.

    Args:
      mapping: A single module mapping `struct`.

    Returns:
      A string containing the module mapping for the target in protobuf text
      format.
    """
    module_name = mapping.module_name
    proto_file_paths = mapping.proto_file_paths

    content = "mapping {\n"
    content += '  module_name: "%s"\n' % module_name
    if len(proto_file_paths) == 1:
        content += '  proto_file_path: "%s"\n' % proto_file_paths[0]
    else:
        # Use list form to avoid parsing and looking up the fieldname for
        # each entry.
        content += '  proto_file_path: [\n    "%s"' % proto_file_paths[0]
        for path in proto_file_paths[1:]:
            content += ',\n    "%s"' % path
        content += "\n  ]\n"
    content += "}\n"

    return content

def _register_module_mapping_write_action(target, actions, module_mappings):
    """Registers an action that generates a module mapping for a proto library.

    Args:
      target: The `proto_library` target whose module mapping is being generated.
      actions: The context's actions object.
      module_mappings: The sequence of module mapping `struct`s to be rendered.
          This sequence should already have duplicates removed.

    Returns:
      The `File` representing the module mapping that will be generated in
      protobuf text format.
    """
    mapping_file = actions.declare_file(
        target.label.name + ".protoc_gen_swift_modules.asciipb",
    )
    content = "".join([_render_text_module_mapping(m) for m in module_mappings])

    actions.write(
        content = content,
        output = mapping_file,
    )

    return mapping_file

def _swift_protoc_gen_aspect_impl(target, aspect_ctx):
    toolchain = aspect_ctx.attr._toolchain[SwiftToolchainInfo]

    direct_srcs = _filter_out_well_known_types(target.proto.direct_sources)

    # Direct sources are passed as arguments to protoc to generate *only* the
    # files in this target, but we need to pass the transitive sources as inputs
    # to the generating action so that all the dependent files are available for
    # protoc to parse.
    # Instead of providing all those files and opening/reading them, we use
    # protoc's support for reading descriptor sets to resolve things.
    transitive_descriptor_sets = target.proto.transitive_descriptor_sets
    deps = [dep for dep in aspect_ctx.rule.attr.deps if SwiftProtoInfo in dep]

    minimal_module_mappings = []
    if direct_srcs:
        minimal_module_mappings.append(
            _build_module_mapping_from_srcs(target, direct_srcs),
        )
    if deps:
        minimal_module_mappings.extend(_gather_transitive_module_mappings(deps))

    transitive_module_mapping_file = _register_module_mapping_write_action(
        target,
        aspect_ctx.actions,
        minimal_module_mappings,
    )

    if direct_srcs:
        # Generate the Swift sources from the .proto files.
        pbswift_files = _register_pbswift_generate_action(
            target,
            aspect_ctx.actions,
            direct_srcs,
            transitive_descriptor_sets,
            transitive_module_mapping_file,
            aspect_ctx.executable._mkdir_and_run,
            aspect_ctx.executable._protoc,
            aspect_ctx.executable._protoc_gen_swift,
        )

        # Compile the generated Swift sources and produce a static library and a
        # .swiftmodule as outputs. In addition to the other proto deps, we also pass
        # support libraries like the SwiftProtobuf runtime as deps to the compile
        # action.
        compile_deps = deps + aspect_ctx.attr._proto_support

        feature_configuration = swift_common.configure_features(
            toolchain = toolchain,
            requested_features = aspect_ctx.features + ["swift.no_generated_header"],
            unsupported_features = aspect_ctx.disabled_features,
        )

        compile_results = swift_common.compile_as_library(
            actions = aspect_ctx.actions,
            bin_dir = aspect_ctx.bin_dir,
            compilation_mode = aspect_ctx.var["COMPILATION_MODE"],
            label = target.label,
            module_name = swift_common.derive_module_name(target.label),
            srcs = pbswift_files,
            swift_fragment = aspect_ctx.fragments.swift,
            toolchain = toolchain,
            allow_testing = False,
            configuration = aspect_ctx.configuration,
            deps = compile_deps,
            feature_configuration = feature_configuration,
            genfiles_dir = aspect_ctx.genfiles_dir,
            # Prevent conflicts with C++ protos in the same output directory, which
            # use the `lib{name}.a` pattern. This will produce `lib{name}.swift.a`
            # instead.
            library_name = "{}.swift".format(target.label.name),
            # The generated protos themselves are not usable in Objective-C, but we
            # still need the Objective-C provider that it propagates since it
            # carries the static libraries that apple_binary will want to link on
            # those platforms.
            objc_fragment = aspect_ctx.fragments.objc,
        )
        providers = compile_results.providers
    else:
        # If there are no srcs, merge the SwiftInfo providers and propagate them. Do
        # likewise for apple_common.Objc providers if the toolchain supports
        # Objective-C interop.
        pbswift_files = []
        providers = [swift_common.merge_swift_info_providers(deps)]

        if toolchain.supports_objc_interop:
            objc_providers = [
                dep[apple_common.Objc]
                for dep in deps
                if apple_common.Objc in dep
            ]
            objc_provider = apple_common.new_objc_provider(providers = objc_providers)
            providers.append(objc_provider)

    providers.append(_build_swift_proto_info_provider(
        pbswift_files,
        minimal_module_mappings,
        deps,
    ))

    return providers

swift_protoc_gen_aspect = aspect(
    attr_aspects = ["deps"],
    attrs = dicts.add(
        swift_common.toolchain_attrs(),
        {
            "_mkdir_and_run": attr.label(
                cfg = "host",
                default = Label(
                    "@build_bazel_rules_swift//tools/mkdir_and_run",
                ),
                executable = True,
            ),
            # TODO(b/63389580): Migrate to proto_lang_toolchain.
            "_protoc": attr.label(
                cfg = "host",
                default = Label("@com_google_protobuf//:protoc"),
                executable = True,
            ),
            "_protoc_gen_swift": attr.label(
                cfg = "host",
                default = Label(
                    "//swift:protoc-gen-swift",
                ),
                executable = True,
            ),
            "_proto_support": attr.label_list(
                default = [
                    Label("@com_github_apple_swift_swift_protobuf//:SwiftProtobuf"),
                ],
            ),
        },
    ),
    doc = """
Generates Swift artifacts for a `proto_library` target.

For each `proto_library` (more specifically, any target that propagates a
`proto` provider) to which this aspect is applied, the aspect will register
actions that generate Swift artifacts and propagate them in a `SwiftProtoInfo`
provider.

Most users should not need to use this aspect directly; it is an implementation
detail of the `swift_proto_library` rule.
""",
    fragments = [
        "objc",
        "swift",
    ],
    implementation = _swift_protoc_gen_aspect_impl,
)