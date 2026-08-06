-module(erlsp_server_tests).

-include_lib("eunit/include/eunit.hrl").

merge_diagnostics_test_() ->
  [
    fun first_job_for_a_uri_is_recorded_alone/0,
    fun a_second_job_for_the_same_uri_is_added_alongside_the_first/0,
    fun a_job_rerunning_for_the_same_uri_replaces_only_its_own_slot/0,
    fun different_uris_are_kept_independent/0
  ].

first_job_for_a_uri_is_recorded_alone() ->
  Uri = <<"file:///a.erl">>,
  Diagnostics = merge(#{}, Uri, erlsp_diag_compiler, [compiler_diag()]),
  ?assertEqual(#{Uri => #{erlsp_diag_compiler => [compiler_diag()]}}, Diagnostics).

a_second_job_for_the_same_uri_is_added_alongside_the_first() ->
  Uri = <<"file:///a.erl">>,
  Diagnostics0 = merge(#{}, Uri, erlsp_diag_compiler, [compiler_diag()]),
  Diagnostics = merge(Diagnostics0, Uri, erlsp_diag_elvis, [elvis_diag()]),
  ?assertEqual(
    #{Uri => #{erlsp_diag_compiler => [compiler_diag()], erlsp_diag_elvis => [elvis_diag()]}},
    Diagnostics
  ),
  AllDiagnostics = lists:append(maps:values(maps:get(Uri, Diagnostics))),
  ?assertEqual(lists:sort([compiler_diag(), elvis_diag()]), lists:sort(AllDiagnostics)).

a_job_rerunning_for_the_same_uri_replaces_only_its_own_slot() ->
  Uri = <<"file:///a.erl">>,
  Diagnostics0 = merge(#{}, Uri, erlsp_diag_compiler, [compiler_diag()]),
  Diagnostics1 = merge(Diagnostics0, Uri, erlsp_diag_elvis, [elvis_diag()]),
  Diagnostics = merge(Diagnostics1, Uri, erlsp_diag_compiler, []),
  ?assertEqual(
    #{Uri => #{erlsp_diag_compiler => [], erlsp_diag_elvis => [elvis_diag()]}},
    Diagnostics
  ).

different_uris_are_kept_independent() ->
  UriA = <<"file:///a.erl">>,
  UriB = <<"file:///b.erl">>,
  Diagnostics0 = merge(#{}, UriA, erlsp_diag_compiler, [compiler_diag()]),
  Diagnostics = merge(Diagnostics0, UriB, erlsp_diag_elvis, [elvis_diag()]),
  ?assertEqual(
    #{
      UriA => #{erlsp_diag_compiler => [compiler_diag()]},
      UriB => #{erlsp_diag_elvis => [elvis_diag()]}
    },
    Diagnostics
  ).

merge(Diagnostics, Uri, JobModule, JobDiagnostics) ->
  erlsp_server:merge_diagnostics(Diagnostics, Uri, JobModule, JobDiagnostics).

compiler_diag() ->
  #{
    range => #{start => #{line => 0, character => 0}, 'end' => #{line => 0, character => 0}},
    severity => 1,
    source => <<"erlsp">>,
    message => <<"a compiler error">>
  }.

elvis_diag() ->
  #{
    range => #{start => #{line => 5, character => 0}, 'end' => #{line => 5, character => 0}},
    severity => 2,
    source => <<"elvis(elvis_style/operator_spaces)">>,
    message => <<"a style violation">>
  }.
