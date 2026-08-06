-module(erlsp_test_dir_project_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture/1, rebar3_compile/2, ensure_checkout_symlink/2]).

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  {IndexPid, ConfigPid}.

teardown({IndexPid, ConfigPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(ConfigPid).

erlsp_test_dir_project_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun source_dirs_include_test_directory/1,
    fun workspace_job_indexes_the_test_suite/1,
    fun test_only_dependency_is_not_seen_under_the_default_profile/1,
    fun test_only_dependency_is_indexed_once_built_under_the_test_profile/1
  ]}.

source_dirs_include_test_directory(_Pids) ->
  Root = fixture("test_dir_project"),
  SourceDirs = erlsp_config:source_dirs_for_root(Root),
  ?_assert(lists:member(filename:join(Root, "test"), SourceDirs)).

workspace_job_indexes_the_test_suite(_Pids) ->
  Root = fixture("test_dir_project"),
  ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(Root)),
  Token = make_ref(),
  ok = erlsp_index_workspace_job:run(erlsp_utils:path_to_uri(Root), Token),
  [
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:module_location(test_dir_fixture_tests)),
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:function_location(test_dir_fixture_tests, add_test, 0))
  ].

test_only_dependency_is_not_seen_under_the_default_profile(_Pids) ->
  Root = fixture("test_dir_project"),
  BuildDir = filename:join(Root, "_build"),
  ok = remove_dir(BuildDir),
  ok = rebar3_compile(Root, []),
  DepDirs = erlsp_config:dep_source_dirs_for_root(Root),
  ?_assertNot(lists:any(fun(Dir) -> string:find(Dir, "test_only_dep_fixture") =/= nomatch end, DepDirs)).

remove_dir(Dir) ->
  case file:del_dir_r(Dir) of
    ok -> ok;
    {error, enoent} -> ok
  end.

test_only_dependency_is_indexed_once_built_under_the_test_profile(_Pids) ->
  Root = fixture("test_dir_project"),
  ok = ensure_checkout_symlink(Root, "test_only_dep_fixture"),
  ok = rebar3_compile(Root, ["as", "test"]),
  ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(Root)),
  EbinDirs = erlsp_config:ebin_paths_for_root(Root),
  code:add_pathsz(EbinDirs),
  DepDirs = erlsp_config:dep_source_dirs_for_root(Root),
  DepFiles = lists:append([filelib:wildcard(filename:join(Dir, "*.erl")) || Dir <- DepDirs]),
  [erlsp_index:index_file(F) || F <- DepFiles],
  ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:function_location(test_only_dep_fixture, stub, 0)).
