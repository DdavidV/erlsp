-module(erlsp_hover_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture_compiled/1]).

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, DocumentsPid} = erlsp_documents:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  {IndexPid, DocumentsPid, ConfigPid}.

teardown({IndexPid, DocumentsPid, ConfigPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(DocumentsPid),
  gen_server:stop(ConfigPid).

erlsp_hover_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun hover_shows_spec_and_doc_for_a_documented_function/1,
    fun hover_shows_edoc_fallback_when_no_doc_attribute_is_present/1,
    fun hover_shows_only_spec_when_there_is_no_doc_at_all/1,
    fun hover_shows_doc_for_a_documented_type/1,
    fun hover_shows_moduledoc_for_a_bare_module_atom/1,
    fun hover_shows_macro_definition_text/1,
    fun hover_on_nothing_resolvable_returns_error/1
  ]}.

hover_shows_spec_and_doc_for_a_documented_function(_Pids) ->
  Root = fixture_compiled("hover_doc_project"),
  Path = filename:join(Root, "src/hover_doc_fixture.erl"),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "documented(Number) ->"),
  {ok, #{kind := <<"markdown">>, value := Markdown}} = erlsp_hover:hover(Uri, Line, Column),
  [
    ?_assert(binary:match(Markdown, <<"-spec documented">>) =/= nomatch),
    ?_assert(binary:match(Markdown, <<"Doubles its argument.">>) =/= nomatch)
  ].

hover_shows_edoc_fallback_when_no_doc_attribute_is_present(_Pids) ->
  Root = fixture_compiled("hover_doc_project"),
  Path = filename:join(Root, "src/hover_edoc_fixture.erl"),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "legacy_documented(Number) ->"),
  {ok, #{value := Markdown}} = erlsp_hover:hover(Uri, Line, Column),
  [
    ?_assert(binary:match(Markdown, <<"-spec legacy_documented">>) =/= nomatch),
    ?_assert(binary:match(Markdown, <<"documented the legacy EDoc-comment way">>) =/= nomatch)
  ].

hover_shows_only_spec_when_there_is_no_doc_at_all(_Pids) ->
  Root = fixture_compiled("hover_doc_project"),
  Path = filename:join(Root, "src/hover_nodoc_fixture.erl"),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "undocumented(Number) ->"),
  {ok, #{value := Markdown}} = erlsp_hover:hover(Uri, Line, Column),
  [
    ?_assert(binary:match(Markdown, <<"```erlang">>) =/= nomatch),
    ?_assert(binary:match(Markdown, <<"-spec undocumented">>) =/= nomatch),
    ?_assert(binary:match(Markdown, <<"Number :: integer()">>) =/= nomatch),
    %% No doc section: no "---" separator should be present.
    ?_assertEqual(nomatch, binary:match(Markdown, <<"---">>))
  ].

hover_shows_doc_for_a_documented_type(_Pids) ->
  Root = fixture_compiled("hover_doc_project"),
  Path = filename:join(Root, "src/hover_doc_fixture.erl"),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "documented_type() :: ok"),
  {ok, #{value := Markdown}} = erlsp_hover:hover(Uri, Line, Column),
  ?_assertEqual(<<"A type documented with -doc.">>, Markdown).

hover_shows_moduledoc_for_a_bare_module_atom(_Pids) ->
  Root = fixture_compiled("hover_doc_project"),
  DocFixturePath = filename:join(Root, "src/hover_doc_fixture.erl"),
  ok = erlsp_index:index_file(DocFixturePath),
  TmpPath = filename:join(Root, "src/hover_module_ref_tmp.erl"),
  ok = file:write_file(TmpPath, <<
    "-module(hover_module_ref_tmp).\n"
    "-export([go/0]).\n"
    "go() -> hover_doc_fixture.\n"
  >>),
  try
    ok = erlsp_index:index_file(TmpPath),
    Uri = erlsp_utils:path_to_uri(TmpPath),
    {ok, Text} = file:read_file(TmpPath),
    {Line, Column} = locate_substring(Text, "hover_doc_fixture."),
    {ok, #{value := Markdown}} = erlsp_hover:hover(Uri, Line, Column),
    ?_assertEqual(<<"A fixture module documented with the modern -doc/-moduledoc attributes.">>, Markdown)
  after
    file:delete(TmpPath)
  end.

hover_shows_macro_definition_text(_Pids) ->
  Root = fixture_compiled("hover_doc_project"),
  TmpPath = filename:join(Root, "src/hover_macro_tmp.erl"),
  ok = file:write_file(TmpPath, <<
    "-module(hover_macro_tmp).\n"
    "-define(ANSWER, 42).\n"
    "-export([go/0]).\n"
    "go() -> ?ANSWER.\n"
  >>),
  try
    ok = erlsp_index:index_file(TmpPath),
    Uri = erlsp_utils:path_to_uri(TmpPath),
    {ok, Text} = file:read_file(TmpPath),
    {Line, Column} = locate_substring(Text, "?ANSWER."),
    {ok, #{value := Markdown}} = erlsp_hover:hover(Uri, Line, Column),
    ?_assertEqual(<<"```erlang\n-define(ANSWER, 42)\n```">>, Markdown)
  after
    file:delete(TmpPath)
  end.

hover_on_nothing_resolvable_returns_error(_Pids) ->
  Root = fixture_compiled("hover_doc_project"),
  Path = filename:join(Root, "src/hover_nodoc_fixture.erl"),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  %% Line 0, column 0 is "-module(...)"'s leading '-' - not a resolvable symbol.
  ?_assertEqual(error, erlsp_hover:hover(Uri, 0, 0)).

locate_substring(Text, Needle) ->
  Lines = string:split(unicode:characters_to_binary(Text), <<"\n">>, all),
  NeedleBin = unicode:characters_to_binary(Needle),
  locate_in_lines(Lines, NeedleBin, 0).

locate_in_lines([Line | Rest], Needle, LineIndex) ->
  case binary:match(Line, Needle) of
    {Start, _Length} -> {LineIndex, Start};
    nomatch -> locate_in_lines(Rest, Needle, LineIndex + 1)
  end;
locate_in_lines([], _Needle, _LineIndex) ->
  error(not_found).
