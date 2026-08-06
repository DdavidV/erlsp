-module(erlsp_config_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixtures_root/0, fixture/1, rebar3_compile/2]).

setup() ->
  {ok, Pid} = erlsp_config:start_link(),
  Pid.

teardown(Pid) ->
  gen_server:stop(Pid).

erlsp_config_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun single_app_project_root/1,
    fun umbrella_own_app_names/1,
    fun umbrella_source_dirs/1,
    fun umbrella_own_app_parent_dirs/1,
    fun umbrella_include_paths_include_parent_dirs/1,
    fun project_roots_finds_nested_projects/1,
    fun build_tools_detects_rebar3/1,
    fun project_root_for_path_walks_up_from_a_file/1,
    fun ebin_paths_dedupes_by_app_name_preferring_default/1,
    fun dep_source_dirs_excludes_own_apps/1,
    fun dep_source_dirs_excludes_configured_deps_exclude_apps/1,
    fun clear_project_caches_keeps_root_path_but_forgets_cached_lookups/1,
    fun missing_config_file_yields_all_defaults/1,
    fun include_dirs_from_config_are_appended_to_the_built_in_list/1,
    fun source_dirs_from_config_are_appended_to_the_built_in_list/1,
    fun otp_path_defaults_to_undefined/1,
    fun otp_path_from_config_is_returned_verbatim/1,
    fun otp_apps_exclude_defaults_to_empty/1,
    fun otp_apps_exclude_accepts_atoms/1,
    fun deps_exclude_accepts_atoms/1,
    fun rebar_profile_defaults_to_default/1,
    fun rebar_profile_from_config_prefers_that_profile/1,
    fun clear_project_caches_keeps_loaded_user_config/1,
    fun malformed_config_file_falls_back_to_defaults/1
  ]}.

single_app_project_root(_Pid) ->
  Root = fixture("parse_transform_project"),
  FilePath = filename:join(Root, "src/pt_fixture_user.erl"),
  [
    ?_assertEqual(Root, erlsp_config:project_root_for_path(FilePath)),
    ?_assertEqual([filename:join(Root, "src")], erlsp_config:source_dirs_for_root(Root))
  ].

umbrella_own_app_names(_Pid) ->
  Root = fixture("umbrella_project"),
  SubAppA = filename:join(Root, "apps/umbrella_app_a/src/umbrella_app_a.erl"),
  SubAppB = filename:join(Root, "apps/umbrella_app_b/src/umbrella_app_b.erl"),
  [
    ?_assertEqual(Root, erlsp_config:project_root_for_path(SubAppA)),
    ?_assertEqual(Root, erlsp_config:project_root_for_path(SubAppB))
  ].

umbrella_source_dirs(_Pid) ->
  Root = fixture("umbrella_project"),
  SourceDirs = lists:sort(erlsp_config:source_dirs_for_root(Root)),
  Expected = lists:sort([
    filename:join(Root, "apps/umbrella_app_a/src"),
    filename:join(Root, "apps/umbrella_app_b/src")
  ]),
  ?_assertEqual(Expected, SourceDirs).

umbrella_own_app_parent_dirs(_Pid) ->
  Root = fixture("umbrella_project"),
  IncludePaths = erlsp_config:include_paths_for_root(Root),
  ?_assert(lists:member(filename:join(Root, "apps"), IncludePaths)).

umbrella_include_paths_include_parent_dirs(_Pid) ->
  Root = fixture("umbrella_project"),
  IncludePaths = erlsp_config:include_paths_for_root(Root),
  ?_assert(lists:member(filename:join(Root, "apps/umbrella_app_b/include"), IncludePaths)).

project_roots_finds_nested_projects(_Pid) ->
  ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(fixtures_root())),
  Roots = erlsp_config:project_roots(),
  ExpectedRoots = [
    fixture("behaviour_dep_project"),
    fixture("include_lib_project"),
    fixture("parse_transform_project"),
    fixture("test_dir_project"),
    fixture("umbrella_project")
  ],
  [?_assertEqual([], ExpectedRoots -- Roots)].

build_tools_detects_rebar3(_Pid) ->
  Root = fixture("include_lib_project"),
  ?_assertEqual([rebar3], erlsp_config:build_tools_for_root(Root)).

project_root_for_path_walks_up_from_a_file(_Pid) ->
  Root = fixture("include_lib_project"),
  HeaderPath = filename:join(Root, "include/fixture.hrl"),
  ?_assertEqual(Root, erlsp_config:project_root_for_path(HeaderPath)).

ebin_paths_dedupes_by_app_name_preferring_default(_Pid) ->
  Root = fixture("behaviour_dep_project"),
  ok = rebar3_compile(Root, []),
  ok = rebar3_compile(Root, ["as", "test"]),
  EbinDirs = erlsp_config:ebin_paths_for_root(Root),
  AppNames = [filename:basename(filename:dirname(Dir)) || Dir <- EbinDirs],
  [
    ?_assertEqual(lists:sort(AppNames), lists:usort(AppNames)),
    ?_assert(lists:all(fun is_default_profile_dir/1, EbinDirs))
  ].

is_default_profile_dir(EbinDir) ->
  filename:basename(filename:dirname(filename:dirname(filename:dirname(EbinDir)))) =:= "default".

dep_source_dirs_excludes_own_apps(_Pid) ->
  Root = fixture("parse_transform_project"),
  ok = rebar3_compile(Root, []),
  DepDirs = erlsp_config:dep_source_dirs_for_root(Root),
  OwnSrcDir = filename:join(Root, "_build/default/lib/parse_transform_project/src"),
  ?_assertNot(lists:member(OwnSrcDir, DepDirs)).

dep_source_dirs_excludes_configured_deps_exclude_apps(_Pid) ->
  Root = fixture("parse_transform_project"),
  ok = rebar3_compile(Root, []),
  FakeDepSrcDir = filename:join(Root, "_build/default/lib/fake_dep_fixture/src"),
  ok = filelib:ensure_dir(filename:join(FakeDepSrcDir, "placeholder")),
  ConfigPath = filename:join(Root, "erlsp.config"),
  ok = file:write_file(ConfigPath, "[{deps_exclude, [fake_dep_fixture]}].\n"),
  try
    ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(Root)),
    DepDirs = erlsp_config:dep_source_dirs_for_root(Root),
    ?_assertNot(lists:member(FakeDepSrcDir, DepDirs))
  after
    file:del_dir_r(FakeDepSrcDir),
    file:delete(ConfigPath)
  end.

clear_project_caches_keeps_root_path_but_forgets_cached_lookups(_Pid) ->
  Root = fixture("include_lib_project"),
  ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(Root)),
  %% Populate every cache this module keeps.
  _ = erlsp_config:project_root_for_path(filename:join(Root, "src/include_lib_fixture.erl")),
  _ = erlsp_config:include_paths_for_root(Root),
  _ = erlsp_config:build_tools_for_root(Root),
  CachedBefore = ets:tab2list(erlsp_config),
  ok = erlsp_config:clear_project_caches(),
  CachedAfter = ets:tab2list(erlsp_config),
  [
    ?_assert(length(CachedBefore) > 1),
    ?_assertEqual([{root_path, Root}, {user_config, []}], lists:sort(CachedAfter)),
    ?_assertEqual(Root, erlsp_config:root_path())
  ].

-spec with_workspace_config(ConfigContents, TestFun) -> Result when
  ConfigContents :: iodata() | none,
  TestFun :: fun((file:filename()) -> Result),
  Result :: term().
with_workspace_config(ConfigContents, TestFun) ->
  WorkspaceRoot = filename:join(
    filename:absname("."),
    "eunit_config_tmp_" ++ integer_to_list(erlang:unique_integer([positive]))
  ),
  ok = filelib:ensure_dir(filename:join(WorkspaceRoot, "placeholder")),
  case ConfigContents of
    none -> ok;
    _Contents -> ok = file:write_file(filename:join(WorkspaceRoot, "erlsp.config"), ConfigContents)
  end,
  try
    ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(WorkspaceRoot)),
    TestFun(WorkspaceRoot)
  after
    file:del_dir_r(WorkspaceRoot)
  end.

missing_config_file_yields_all_defaults(_Pid) ->
  with_workspace_config(none, fun(_WorkspaceRoot) ->
    [
      ?_assertEqual(undefined, erlsp_config:otp_path()),
      ?_assertEqual([], erlsp_config:otp_apps_exclude()),
      ?_assertEqual([], erlsp_config:deps_exclude()),
      ?_assertEqual("default", erlsp_config:rebar_profile())
    ]
  end).

include_dirs_from_config_are_appended_to_the_built_in_list(_Pid) ->
  with_workspace_config("[{include_dirs, [\"vendor/include\"]}].\n", fun(WorkspaceRoot) ->
    ok = filelib:ensure_dir(filename:join([WorkspaceRoot, "vendor", "include", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([WorkspaceRoot, "src", "placeholder"])),
    IncludePaths = erlsp_config:include_paths_for_root(WorkspaceRoot),
    [
      ?_assert(lists:member(filename:join(WorkspaceRoot, "vendor/include"), IncludePaths)),
      ?_assert(lists:member(filename:join(WorkspaceRoot, "src"), IncludePaths))
    ]
  end).

source_dirs_from_config_are_appended_to_the_built_in_list(_Pid) ->
  with_workspace_config("[{source_dirs, [\"lib\"]}].\n", fun(WorkspaceRoot) ->
    ok = filelib:ensure_dir(filename:join([WorkspaceRoot, "lib", "placeholder"])),
    ok = filelib:ensure_dir(filename:join([WorkspaceRoot, "src", "placeholder"])),
    SourceDirs = erlsp_config:source_dirs_for_root(WorkspaceRoot),
    [
      ?_assert(lists:member(filename:join(WorkspaceRoot, "lib"), SourceDirs)),
      ?_assert(lists:member(filename:join(WorkspaceRoot, "src"), SourceDirs))
    ]
  end).

otp_path_defaults_to_undefined(_Pid) ->
  with_workspace_config(none, fun(_WorkspaceRoot) ->
    ?_assertEqual(undefined, erlsp_config:otp_path())
  end).

otp_path_from_config_is_returned_verbatim(_Pid) ->
  with_workspace_config("[{otp_path, \"/opt/otp-27\"}].\n", fun(_WorkspaceRoot) ->
    ?_assertEqual("/opt/otp-27", erlsp_config:otp_path())
  end).

otp_apps_exclude_defaults_to_empty(_Pid) ->
  with_workspace_config(none, fun(_WorkspaceRoot) ->
    ?_assertEqual([], erlsp_config:otp_apps_exclude())
  end).

otp_apps_exclude_accepts_atoms(_Pid) ->
  with_workspace_config("[{otp_apps_exclude, [wx, observer]}].\n", fun(_WorkspaceRoot) ->
    ?_assertEqual(["wx", "observer"], erlsp_config:otp_apps_exclude())
  end).

deps_exclude_accepts_atoms(_Pid) ->
  with_workspace_config("[{deps_exclude, [meck]}].\n", fun(_WorkspaceRoot) ->
    ?_assertEqual(["meck"], erlsp_config:deps_exclude())
  end).

rebar_profile_defaults_to_default(_Pid) ->
  with_workspace_config(none, fun(_WorkspaceRoot) ->
    ?_assertEqual("default", erlsp_config:rebar_profile())
  end).

rebar_profile_from_config_prefers_that_profile(_Pid) ->
  with_workspace_config("[{rebar_profile, test}].\n", fun(WorkspaceRoot) ->
    AppEbin = filename:join([WorkspaceRoot, "_build", "default", "lib", "myapp", "ebin"]),
    TestEbin = filename:join([WorkspaceRoot, "_build", "test", "lib", "myapp", "ebin"]),
    ok = filelib:ensure_dir(filename:join(AppEbin, "placeholder")),
    ok = filelib:ensure_dir(filename:join(TestEbin, "placeholder")),
    EbinDirs = erlsp_config:ebin_paths_for_root(WorkspaceRoot),
    ?_assertEqual([TestEbin], EbinDirs)
  end).

clear_project_caches_keeps_loaded_user_config(_Pid) ->
  with_workspace_config("[{otp_path, \"/opt/otp-27\"}].\n", fun(_WorkspaceRoot) ->
    ok = erlsp_config:clear_project_caches(),
    ?_assertEqual("/opt/otp-27", erlsp_config:otp_path())
  end).

malformed_config_file_falls_back_to_defaults(_Pid) ->
  with_workspace_config("not valid erlang terms }{\n", fun(_WorkspaceRoot) ->
    [
      ?_assertEqual(undefined, erlsp_config:otp_path()),
      ?_assertEqual([], erlsp_config:otp_apps_exclude())
    ]
  end).
