-module(erlsp_definition_tests).

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

server_root() ->
  filename:absname(".").

index_server_tree() ->
  Root = server_root(),
  ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(Root)),
  Files = filelib:wildcard(filename:join(Root, "src/**/*.erl")),
  [erlsp_index:index_file(F) || F <- Files],
  Root.

erlsp_definition_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun bare_module_atom_in_child_spec_resolves/1,
    fun behaviour_attribute_resolves_to_its_own_module/1,
    fun remote_function_call_resolves/1,
    fun record_reference_resolves/1,
    fun macro_reference_resolves/1,
    fun parse_transform_module_name_resolves/1,
    fun imported_function_call_resolves_to_the_imported_module/1
  ]}.

bare_module_atom_in_child_spec_resolves(_Pids) ->
  Root = index_server_tree(),
  SupPath = filename:join(Root, "src/erlsp_sup.erl"),
  SupUri = erlsp_utils:path_to_uri(SupPath),
  {ok, Text} = file:read_file(SupPath),
  {Line, Column} = locate_substring(Text, "erlsp_worker_sup, start_link"),
  Result = erlsp_definition:locate(SupUri, Line, Column),
  WorkerSupUri = erlsp_utils:path_to_uri(filename:join(Root, "src/servers/erlsp_worker_sup.erl")),
  ?_assertEqual({ok, {WorkerSupUri, 1}}, Result).

behaviour_attribute_resolves_to_its_own_module(_Pids) ->
  Root = index_server_tree(),
  Path = filename:join(Root, "src/jobs/erlsp_diag_compiler.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "erlsp_job"),
  Result = erlsp_definition:locate(Uri, Line, Column),
  JobUri = erlsp_utils:path_to_uri(filename:join(Root, "src/jobs/erlsp_job.erl")),
  ?_assertEqual({ok, {JobUri, 1}}, Result).

remote_function_call_resolves(_Pids) ->
  Root = index_server_tree(),
  Path = filename:join(Root, "src/servers/erlsp_index.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "erlsp_utils:path_to_uri"),
  Result = erlsp_definition:locate(Uri, Line, Column),
  UtilsUri = erlsp_utils:path_to_uri(filename:join(Root, "src/erlsp_utils.erl")),
  ?_assertEqual({ok, {UtilsUri, 26}}, Result).

record_reference_resolves(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  Path = filename:join(Root, "src/include_lib_fixture.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  ok = erlsp_index:index_file(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "#fixture_record{"),
  {ok, {ResolvedUri, ResolvedLine}} = erlsp_definition:locate(Uri, Line, Column),
  [
    ?_assert(ends_with(ResolvedUri, <<"fixture.hrl">>)),
    ?_assertEqual(3, ResolvedLine)
  ].

macro_reference_resolves(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  Path = filename:join(Root, "src/include_lib_fixture.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  ok = erlsp_index:index_file(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "?FIXTURE_MACRO"),
  {ok, {ResolvedUri, ResolvedLine}} = erlsp_definition:locate(Uri, Line, Column),
  [
    ?_assert(ends_with(ResolvedUri, <<"fixture.hrl">>)),
    ?_assertEqual(1, ResolvedLine)
  ].

ends_with(Subject, Suffix) ->
  SuffixSize = byte_size(Suffix),
  SubjectSize = byte_size(Subject),
  SubjectSize >= SuffixSize andalso
    binary:part(Subject, SubjectSize - SuffixSize, SuffixSize) =:= Suffix.

parse_transform_module_name_resolves(_Pids) ->
  Root = fixture_compiled("parse_transform_project"),
  Path = filename:join(Root, "src/pt_fixture_user.erl"),
  TransformPath = filename:join(Root, "src/pt_fixture_transform.erl"),
  ok = erlsp_index:index_file(TransformPath),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "pt_fixture_transform"),
  Result = erlsp_definition:locate(Uri, Line, Column),
  TransformUri = erlsp_utils:path_to_uri(TransformPath),
  ?_assertEqual({ok, {TransformUri, 1}}, Result).

imported_function_call_resolves_to_the_imported_module(_Pids) ->
  Root = index_server_tree(),
  Path = filename:join(Root, "test/erlsp_config_tests.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  ok = erlsp_index:index_file(filename:join(Root, "test/erlsp_test_utils.erl")),
  ok = erlsp_index:index_file(Path),
  {ok, Text} = file:read_file(Path),
  {Line, Column} = locate_substring(Text, "fixture(\"parse_transform_project\")"),
  Result = erlsp_definition:locate(Uri, Line, Column),
  UtilsUri = erlsp_utils:path_to_uri(filename:join(Root, "test/erlsp_test_utils.erl")),
  ?_assertMatch({ok, {UtilsUri, _Line}}, Result).

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
