-module(erlsp_index_workspace_job_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture_compiled/1]).

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  {IndexPid, ConfigPid}.

teardown({IndexPid, ConfigPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(ConfigPid).

erlsp_index_workspace_job_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun indexes_every_workspace_source_file/1
  ]}.

indexes_every_workspace_source_file(_Pids) ->
  Root = fixture_compiled("umbrella_project"),
  Token = make_ref(),
  ok = erlsp_index_workspace_job:run(erlsp_utils:path_to_uri(Root), Token),
  [
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:module_location(umbrella_app_a)),
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:module_location(umbrella_app_b))
  ].
