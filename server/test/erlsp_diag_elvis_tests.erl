-module(erlsp_diag_elvis_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture/1]).

setup() ->
  {ok, ConfigPid} = erlsp_config:start_link(),
  ConfigPid.

teardown(ConfigPid) ->
  gen_server:stop(ConfigPid).

erlsp_diag_elvis_test_() ->
  {timeout, 30, {foreach, fun setup/0, fun teardown/1, [
    fun no_diagnostics_without_an_elvis_config/1,
    fun a_real_violation_produces_a_diagnostic/1,
    fun a_violation_underlines_the_whole_line/1,
    fun a_clean_file_produces_no_diagnostics/1,
    fun a_non_erl_file_produces_no_diagnostics/1
  ]}}.

no_diagnostics_without_an_elvis_config(_ConfigPid) ->
  Root = fixture("parse_transform_project"),
  Path = filename:join(Root, "src/pt_fixture_user.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  ?_assertEqual([], erlsp_diag_elvis:run(Uri)).

a_real_violation_produces_a_diagnostic(_ConfigPid) ->
  Root = fixture("elvis_project"),
  Path = filename:join(Root, "src/elvis_fixture.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  Diagnostics = erlsp_diag_elvis:run(Uri),
  [
    ?_assert(length(Diagnostics) > 0),
    ?_assert(lists:all(fun(#{severity := Severity}) -> Severity =:= 2 end, Diagnostics)),
    ?_assert(lists:all(
      fun(#{source := Source}) -> binary:match(Source, <<"elvis(">>) =/= nomatch end,
      Diagnostics
    ))
  ].

a_violation_underlines_the_whole_line(_ConfigPid) ->
  Root = fixture("elvis_project"),
  Path = filename:join(Root, "src/elvis_fixture.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  [Diagnostic | _Rest] = erlsp_diag_elvis:run(Uri),
  #{range := #{start := Start, 'end' := End}} = Diagnostic,
  [
    ?_assertEqual(#{line => 5, character => 4}, Start),
    ?_assertEqual(#{line => 5, character => 8}, End),
    ?_assertNotEqual(Start, End)
  ].

a_clean_file_produces_no_diagnostics(_ConfigPid) ->
  Root = fixture("elvis_project"),
  Path = filename:join(Root, "src/elvis_clean_fixture.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  ?_assertEqual([], erlsp_diag_elvis:run(Uri)).

a_non_erl_file_produces_no_diagnostics(_ConfigPid) ->
  Root = fixture("elvis_project"),
  Path = filename:join(Root, "elvis.config"),
  Uri = erlsp_utils:path_to_uri(Path),
  ?_assertEqual([], erlsp_diag_elvis:run(Uri)).
