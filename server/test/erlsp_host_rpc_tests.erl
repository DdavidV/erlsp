-module(erlsp_host_rpc_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture/1, rebar3_compile/2]).

compile_file_succeeds_test() ->
  Root = fixture("parse_transform_project"),
  Path = filename:join(Root, "src/pt_fixture_transform.erl"),
  Result = erlsp_host_rpc:compile_file(Path, [basic_validation, return_errors, return_warnings]),
  ?assertMatch({ok, [], []}, Result).

compile_file_reports_real_syntax_errors_test() ->
  Root = fixture("parse_transform_project"),
  TmpPath = filename:join(Root, "src/host_rpc_broken_tmp.erl"),
  ok = file:write_file(TmpPath, <<
    "-module(host_rpc_broken_tmp).\n"
    "go() -> .\n"
  >>),
  try
    Result = erlsp_host_rpc:compile_file(TmpPath, [basic_validation, return_errors, return_warnings]),
    ?assertMatch({error, [{_File, [_ | _]}], _Warnings}, Result)
  after
    file:delete(TmpPath)
  end.

run_elvis_finds_a_real_violation_test() ->
  Root = fixture("elvis_project"),
  ConfigPath = filename:join(Root, "elvis.config"),
  {ok, OriginalCwd} = file:get_cwd(),
  ok = file:set_cwd(Root),
  try
    {ok, RuleGroups} = erlsp_host_rpc:run_elvis(ConfigPath, "src/elvis_fixture.erl"),
    Items = lists:append([elvis_result:get_items(Rule) || Rule <- RuleGroups]),
    ?assert(length(Items) > 0)
  after
    ok = file:set_cwd(OriginalCwd)
  end.

run_elvis_finds_no_violations_in_a_clean_file_test() ->
  Root = fixture("elvis_project"),
  ConfigPath = filename:join(Root, "elvis.config"),
  {ok, OriginalCwd} = file:get_cwd(),
  ok = file:set_cwd(Root),
  try
    {ok, RuleGroups} = erlsp_host_rpc:run_elvis(ConfigPath, "src/elvis_clean_fixture.erl"),
    Items = lists:append([elvis_result:get_items(Rule) || Rule <- RuleGroups]),
    ?assertEqual([], Items)
  after
    ok = file:set_cwd(OriginalCwd)
  end.

run_elvis_returns_no_rule_groups_for_an_unmatched_file_test() ->
  Root = fixture("elvis_project"),
  ConfigPath = filename:join(Root, "elvis.config"),
  {ok, OriginalCwd} = file:get_cwd(),
  ok = file:set_cwd(Root),
  try
    Result = erlsp_host_rpc:run_elvis(ConfigPath, "elvis.config"),
    ?assertEqual({ok, []}, Result)
  after
    ok = file:set_cwd(OriginalCwd)
  end.

root_dir_returns_a_real_directory_test() ->
  RootDir = erlsp_host_rpc:root_dir(),
  ?assert(filelib:is_dir(RootDir)).
