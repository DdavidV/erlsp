-module(erlsp_index_otp_job_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  {IndexPid, ConfigPid}.

teardown({IndexPid, ConfigPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(ConfigPid).

erlsp_index_otp_job_test_() ->
  {timeout, 60, {foreach, fun setup/0, fun teardown/1, [
    fun indexes_a_real_stdlib_module/1,
    fun a_file_referencing_an_otp_app_erlsp_itself_does_not_depend_on_is_indexed_with_its_include_resolved/1,
    fun otp_apps_exclude_skips_the_named_app/1
  ]}}.

indexes_a_real_stdlib_module(_IndexPid) ->
  Token = make_ref(),
  ok = erlsp_index_otp_job:run(<<"file:///unused">>, Token),
  [
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:module_location(lists)),
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:function_location(lists, reverse, 1))
  ].

a_file_referencing_an_otp_app_erlsp_itself_does_not_depend_on_is_indexed_with_its_include_resolved(_IndexPid) ->
  Token = make_ref(),
  ok = erlsp_index_otp_job:run(<<"file:///unused">>, Token),
  TmpPath = filename:join(filename:absname("."), "eunit_include_tmp.erl"),
  ok = file:write_file(TmpPath, <<
    "-module(eunit_include_tmp).\n"
    "-include_lib(\"eunit/include/eunit.hrl\").\n"
  >>),
  try
    ok = erlsp_index:index_file(TmpPath),
    Uri = erlsp_utils:path_to_uri(TmpPath),
    IncludedUris = erlsp_index:included_uris(Uri),
    ResolvedBasenames = [filename:basename(binary_to_list(U)) || U <- IncludedUris],
    ?_assert(lists:member("eunit.hrl", ResolvedBasenames))
  after
    file:delete(TmpPath)
  end.

otp_apps_exclude_skips_the_named_app(_IndexPid) ->
  WorkspaceRoot = filename:join(filename:absname("."), "eunit_otp_exclude_tmp"),
  ok = filelib:ensure_dir(filename:join(WorkspaceRoot, "placeholder")),
  ConfigPath = filename:join(WorkspaceRoot, "erlsp.config"),
  ok = file:write_file(ConfigPath, "[{otp_apps_exclude, [eunit]}].\n"),
  try
    ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(WorkspaceRoot)),
    Token = make_ref(),
    ok = erlsp_index_otp_job:run(<<"file:///unused">>, Token),
    [
      ?_assertEqual(error, erlsp_index:module_location(eunit)),
      ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:module_location(lists))
    ]
  after
    file:del_dir_r(WorkspaceRoot)
  end.
