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
    fun dep_source_dirs_excludes_own_apps/1
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
