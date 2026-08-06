-module(erlsp_host_erl_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture/1, rebar3_compile/2]).

compile_file_succeeds_with_no_ebin_dirs_needed_test() ->
  Root = fixture("parse_transform_project"),
  Path = filename:join(Root, "src/pt_fixture_transform.erl"),
  Result = erlsp_host_erl:compile_file(Path, [basic_validation, return_errors, return_warnings], []),
  ?assertMatch({ok, [], []}, Result).

compile_file_resolves_parse_transform_with_ebin_dir_on_path_test() ->
  Root = fixture("parse_transform_project"),
  ok = rebar3_compile(Root, []),
  Path = filename:join(Root, "src/pt_fixture_user.erl"),
  EbinDir = filename:join(Root, "_build/default/lib/parse_transform_project/ebin"),
  Result = erlsp_host_erl:compile_file(Path, [basic_validation, return_errors, return_warnings], [EbinDir]),
  ?assertMatch({ok, [], []}, Result).

compile_file_fails_without_ebin_dir_on_path_test() ->
  Root = fixture("parse_transform_project"),
  ok = rebar3_compile(Root, []),
  Path = filename:join(Root, "src/pt_fixture_user.erl"),
  Result = erlsp_host_erl:compile_file(Path, [basic_validation, return_errors, return_warnings], []),
  ?assertMatch({error, _Errors, _Warnings}, Result).

compile_file_reports_real_syntax_errors_test() ->
  Root = fixture("parse_transform_project"),
  TmpPath = filename:join(Root, "src/host_erl_broken_tmp.erl"),
  ok = file:write_file(TmpPath, <<
    "-module(host_erl_broken_tmp).\n"
    "go() -> .\n"
  >>),
  try
    Result = erlsp_host_erl:compile_file(TmpPath, [basic_validation, return_errors, return_warnings], []),
    ?assertMatch({error, [{_File, [_ | _]}], _Warnings}, Result)
  after
    file:delete(TmpPath)
  end.

skips_a_broken_erl_ahead_on_path_and_finds_the_real_one_test() ->
  ScratchDir = fake_erl_dir(),
  ok = filelib:ensure_dir(filename:join(ScratchDir, "placeholder")),
  FakeErlPath = filename:join(ScratchDir, "erl"),
  ok = file:write_file(FakeErlPath, <<"#!/bin/sh\nexit 1\n">>),
  ok = file:change_mode(FakeErlPath, 8#755),
  RealPath = os:getenv("PATH"),
  true = os:putenv("PATH", ScratchDir ++ ":" ++ RealPath),
  try
    Root = fixture("parse_transform_project"),
    Path = filename:join(Root, "src/pt_fixture_transform.erl"),
    Result = erlsp_host_erl:compile_file(Path, [basic_validation, return_errors, return_warnings], []),
    ?assertMatch({ok, [], []}, Result)
  after
    os:putenv("PATH", RealPath),
    file:del_dir_r(ScratchDir)
  end.

fake_erl_dir() ->
  {A, B, C} = erlang:timestamp(),
  filename:join(["/tmp", lists:flatten(io_lib:format("erlsp_fake_erl_~b_~b_~b", [A, B, C]))]).
