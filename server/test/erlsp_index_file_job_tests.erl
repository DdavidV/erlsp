-module(erlsp_index_file_job_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture_compiled/1]).

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  {IndexPid, ConfigPid}.

teardown({IndexPid, ConfigPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(ConfigPid).

erlsp_index_file_job_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun reindexes_a_single_saved_file/1
  ]}.

reindexes_a_single_saved_file(_Pids) ->
  Root = fixture_compiled("parse_transform_project"),
  Path = filename:join(Root, "src/pt_fixture_user.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  ok = erlsp_index_file_job:run(Uri),
  ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:function_location(pt_fixture_user, go, 0)).
