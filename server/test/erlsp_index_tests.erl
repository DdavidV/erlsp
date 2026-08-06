-module(erlsp_index_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture/1, fixture_compiled/1]).

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  {IndexPid, ConfigPid}.

teardown({IndexPid, ConfigPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(ConfigPid).

erlsp_index_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun indexes_module_and_function/1,
    fun indexes_record_and_macro/1,
    fun include_lib_own_header_is_resolved_and_indexed/1,
    fun umbrella_sub_app_include_lib_is_resolved_and_indexed/1,
    fun unresolvable_include_lib_does_not_crash_and_leaves_no_entry/1,
    fun clear_removes_every_indexed_entry/1,
    fun remove_uri_removes_only_that_files_entries/1,
    fun remove_uri_removes_imports_from_the_removed_module/1
  ]}.

indexes_module_and_function(_Pids) ->
  Root = fixture("parse_transform_project"),
  Path = filename:join(Root, "src/pt_fixture_user.erl"),
  ok = erlsp_index:index_file(Path),
  [
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:module_location(pt_fixture_user)),
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:function_location(pt_fixture_user, go, 0))
  ].

indexes_record_and_macro(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  Path = filename:join(Root, "src/include_lib_fixture.erl"),
  ok = erlsp_index:index_file(Path),
  [
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:record_location(include_lib_fixture, fixture_record)),
    ?_assertEqual([fixture_record], erlsp_index:records_in_module(include_lib_fixture))
  ].

include_lib_own_header_is_resolved_and_indexed(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  Path = filename:join(Root, "src/include_lib_fixture.erl"),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  IncludedUris = erlsp_index:included_uris(Uri),
  ResolvedBasenames = [filename:basename(binary_to_list(U)) || U <- IncludedUris],
  [
    ?_assert(lists:member("fixture.hrl", ResolvedBasenames)),
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:record_location(include_lib_fixture, fixture_record))
  ].

umbrella_sub_app_include_lib_is_resolved_and_indexed(_Pids) ->
  Root = fixture_compiled("umbrella_project"),
  Path = filename:join(Root, "apps/umbrella_app_b/src/umbrella_app_b.erl"),
  ok = erlsp_index:index_file(Path),
  [
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:function_location(umbrella_app_b, go, 0))
  ].

unresolvable_include_lib_does_not_crash_and_leaves_no_entry(_Pids) ->
  Root = fixture("parse_transform_project"),
  TmpPath = filename:join(Root, "src/bad_include_tmp.erl"),
  ok = file:write_file(TmpPath, <<
    "-module(bad_include_tmp).\n"
    "-include_lib(\"totally_nonexistent_app/include/nope.hrl\").\n"
    "-export([go/0]).\n"
    "go() -> ok.\n"
  >>),
  try
    ok = erlsp_index:index_file(TmpPath),
    Uri = erlsp_utils:path_to_uri(TmpPath),
    [
      ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:module_location(bad_include_tmp)),
      ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:function_location(bad_include_tmp, go, 0)),
      ?_assertEqual([], erlsp_index:included_uris(Uri))
    ]
  after
    file:delete(TmpPath)
  end.

remove_uri_removes_only_that_files_entries(_Pids) ->
  Root = fixture_compiled("umbrella_project"),
  PathA = filename:join(Root, "apps/umbrella_app_a/src/umbrella_app_a.erl"),
  PathB = filename:join(Root, "apps/umbrella_app_b/src/umbrella_app_b.erl"),
  ok = erlsp_index:index_file(PathA),
  ok = erlsp_index:index_file(PathB),
  UriA = erlsp_utils:path_to_uri(PathA),
  ok = erlsp_index:remove_uri(UriA),
  [
    ?_assertEqual(error, erlsp_index:module_location(umbrella_app_a)),
    ?_assertEqual(error, erlsp_index:function_location(umbrella_app_a, hello, 0)),
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:module_location(umbrella_app_b)),
    ?_assertMatch({ok, {_Uri, _Line}}, erlsp_index:function_location(umbrella_app_b, go, 0))
  ].

remove_uri_removes_imports_from_the_removed_module(_Pids) ->
  Root = fixture("parse_transform_project"),
  TmpPath = filename:join(Root, "src/import_removal_tmp.erl"),
  ok = file:write_file(TmpPath, <<
    "-module(import_removal_tmp).\n"
    "-import(lists, [reverse/1]).\n"
    "-export([go/0]).\n"
    "go() -> reverse([1, 2, 3]).\n"
  >>),
  try
    ok = erlsp_index:index_file(TmpPath),
    {ok, lists} = erlsp_index:imported_module(import_removal_tmp, reverse, 1),
    Uri = erlsp_utils:path_to_uri(TmpPath),
    ok = erlsp_index:remove_uri(Uri),
    ?_assertEqual(error, erlsp_index:imported_module(import_removal_tmp, reverse, 1))
  after
    file:delete(TmpPath)
  end.

clear_removes_every_indexed_entry(_Pids) ->
  Root = fixture_compiled("include_lib_project"),
  Path = filename:join(Root, "src/include_lib_fixture.erl"),
  ok = erlsp_index:index_file(Path),
  Uri = erlsp_utils:path_to_uri(Path),
  {ok, _} = erlsp_index:module_location(include_lib_fixture),
  ok = erlsp_index:clear(),
  [
    ?_assertEqual(error, erlsp_index:module_location(include_lib_fixture)),
    ?_assertEqual(error, erlsp_index:record_location(include_lib_fixture, fixture_record)),
    ?_assertEqual([], erlsp_index:included_uris(Uri)),
    ?_assertEqual([], erlsp_index:all_modules())
  ].
