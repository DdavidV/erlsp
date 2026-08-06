-module(erlsp_completion_tests).

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

erlsp_completion_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun remote_call_completes_functions_in_module/1,
    fun macro_completes_after_question_mark/1,
    fun record_completes_after_hash/1,
    fun bare_call_completes_local_functions_and_modules/1
  ]}.

open_and_index(Root, RelativePath) ->
  Path = filename:join(Root, RelativePath),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, Text} = file:read_file(Path),
  ok = erlsp_documents:open(Uri, Text),
  {Uri, Text}.

remote_call_completes_functions_in_module(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  {Uri, _Text} = open_and_index(Root, "src/include_lib_fixture.erl"),
  NewText = <<
    "-module(include_lib_fixture).\n"
    "-include_lib(\"include_lib_project/include/fixture.hrl\").\n"
    "-export([go/0]).\n"
    "go() -> #fixture_record{a = ?FIXTURE_MACRO, b = ok}.\n"
    "x() -> include_lib_fixture:"
  >>,
  ok = erlsp_documents:update(Uri, NewText),
  Items = erlsp_completion:complete(Uri, 4, byte_size(<<"x() -> include_lib_fixture:">>)),
  Labels = [Label || #{label := Label} <- Items],
  ?_assert(lists:member(<<"go/0">>, Labels)).

macro_completes_after_question_mark(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  {Uri, Text} = open_and_index(Root, "src/include_lib_fixture.erl"),
  NewText = <<Text/binary, "\nz() -> ?">>,
  ok = erlsp_documents:update(Uri, NewText),
  Lines = binary:split(NewText, <<"\n">>, [global]),
  LastLineIndex = length(Lines) - 1,
  LastLine = lists:last(Lines),
  Items = erlsp_completion:complete(Uri, LastLineIndex, byte_size(LastLine)),
  Labels = [Label || #{label := Label} <- Items],
  ?_assert(lists:member(<<"FIXTURE_MACRO">>, Labels)).

record_completes_after_hash(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  {Uri, Text} = open_and_index(Root, "src/include_lib_fixture.erl"),
  NewText = <<Text/binary, "\nz() -> #">>,
  ok = erlsp_documents:update(Uri, NewText),
  Lines = binary:split(NewText, <<"\n">>, [global]),
  LastLineIndex = length(Lines) - 1,
  LastLine = lists:last(Lines),
  Items = erlsp_completion:complete(Uri, LastLineIndex, byte_size(LastLine)),
  Labels = [Label || #{label := Label} <- Items],
  ?_assert(lists:member(<<"fixture_record">>, Labels)).

bare_call_completes_local_functions_and_modules(_Pids) ->
  Root = fixture_compiled("parse_transform_project"),
  {Uri, Text} = open_and_index(Root, "src/pt_fixture_user.erl"),
  TransformPath = filename:join(Root, "src/pt_fixture_transform.erl"),
  ok = erlsp_index:index_file(TransformPath),
  NewText = <<Text/binary, "\nz() -> g">>,
  ok = erlsp_documents:update(Uri, NewText),
  Lines = binary:split(NewText, <<"\n">>, [global]),
  LastLineIndex = length(Lines) - 1,
  LastLine = lists:last(Lines),
  Items = erlsp_completion:complete(Uri, LastLineIndex, byte_size(LastLine)),
  Labels = [Label || #{label := Label} <- Items],
  ?_assert(lists:member(<<"go/0">>, Labels)).
