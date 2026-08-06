-module(erlsp_index_deps_job_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture_compiled/1]).

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  {IndexPid, ConfigPid}.

teardown({IndexPid, ConfigPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(ConfigPid).

erlsp_index_deps_job_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun indexes_built_dependency_sources/1,
    fun does_not_index_own_app_as_a_dependency/1
  ]}.

indexes_built_dependency_sources(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  Token = make_ref(),
  ok = erlsp_index_deps_job:run(erlsp_utils:path_to_uri(Root), Token),
  ?_assertEqual([], erlsp_config:dep_source_dirs_for_root(Root)).

does_not_index_own_app_as_a_dependency(_Pids) ->
  Root = fixture_compiled("parse_transform_project"),
  Token = make_ref(),
  ok = erlsp_index_deps_job:run(erlsp_utils:path_to_uri(Root), Token),
  ?_assertEqual(error, erlsp_index:module_location(pt_fixture_user)).
