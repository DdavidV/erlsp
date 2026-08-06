-module(erlsp_diag_compiler_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture/1, fixture_compiled/1]).

setup() ->
  {ok, ConfigPid} = erlsp_config:start_link(),
  ConfigPid.

teardown(ConfigPid) ->
  gen_server:stop(ConfigPid).

erlsp_diag_compiler_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun no_diagnostics_before_workspace_initialized/1,
    fun parse_transform_produces_no_false_positive/1,
    fun include_lib_own_headers_produce_no_false_positive/1,
    fun umbrella_sub_app_include_lib_produces_no_false_positive/1,
    fun a_real_syntax_error_still_produces_a_diagnostic/1
  ]}.

no_diagnostics_before_workspace_initialized(_ConfigPid) ->
  Root = fixture("parse_transform_project"),
  Path = filename:join(Root, "src/pt_fixture_user.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  ?_assertEqual([], erlsp_diag_compiler:run(Uri)).

parse_transform_produces_no_false_positive(_ConfigPid) ->
  Root = fixture_compiled("parse_transform_project"),
  Path = filename:join(Root, "src/pt_fixture_user.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  Diagnostics = erlsp_diag_compiler:run(Uri),
  Errors = [D || D = #{severity := 1} <- Diagnostics],
  ?_assertEqual([], Errors).

include_lib_own_headers_produce_no_false_positive(_ConfigPid) ->
  Root = fixture_compiled("include_lib_project"),
  Path = filename:join(Root, "src/include_lib_fixture.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  Diagnostics = erlsp_diag_compiler:run(Uri),
  Errors = [D || D = #{severity := 1} <- Diagnostics],
  ?_assertEqual([], Errors).

umbrella_sub_app_include_lib_produces_no_false_positive(_ConfigPid) ->
  Root = fixture_compiled("umbrella_project"),
  Path = filename:join(Root, "apps/umbrella_app_b/src/umbrella_app_b.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  Diagnostics = erlsp_diag_compiler:run(Uri),
  Errors = [D || D = #{severity := 1} <- Diagnostics],
  ?_assertEqual([], Errors).

a_real_syntax_error_still_produces_a_diagnostic(_ConfigPid) ->
  Root = fixture_compiled("parse_transform_project"),
  TmpPath = filename:join(Root, "src/broken_fixture_tmp.erl"),
  ok = file:write_file(TmpPath, <<
    "-module(broken_fixture_tmp).\n"
    "-export([go/0]).\n"
    "go() -> .\n"
  >>),
  try
    Uri = erlsp_utils:path_to_uri(TmpPath),
    Diagnostics = erlsp_diag_compiler:run(Uri),
    Errors = [D || D = #{severity := 1} <- Diagnostics],
    ?_assert(length(Errors) > 0)
  after
    file:delete(TmpPath)
  end.
