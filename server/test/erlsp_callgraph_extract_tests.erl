-module(erlsp_callgraph_extract_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture/1]).

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  Root = fixture("callgraph_project"),
  ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(Root)),
  PathA = filename:join(Root, "src/callgraph_a.erl"),
  PathB = filename:join(Root, "src/callgraph_b.erl"),
  ok = erlsp_index:index_file(PathB),
  ok = erlsp_index:index_file(PathA),
  {IndexPid, ConfigPid}.

teardown({IndexPid, ConfigPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(ConfigPid).

erlsp_callgraph_extract_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun a_local_call_produces_an_edge_to_the_same_module/1,
    fun a_cross_module_remote_call_produces_an_edge_to_the_real_callee/1,
    fun an_import_resolved_call_produces_an_edge_to_the_imported_module/1,
    fun a_dynamic_module_call_produces_no_edge/1,
    fun a_dynamic_function_call_produces_no_edge/1,
    fun apply_3_produces_an_edge_to_erlang_apply_3_not_the_dynamic_target/1,
    fun a_function_with_no_calls_has_a_vertex_and_no_outgoing_edges/1,
    fun a_function_never_called_still_gets_a_vertex/1,
    fun calls_nested_in_case_try_and_a_list_comprehension_are_all_found/1
  ]}.

edges_for(Forms) ->
  {_Vertices, Edges} = erlsp_callgraph_extract:extract_edges(<<"file:///callgraph_a.erl">>, Forms),
  lists:sort(Edges).

vertices_for(Forms) ->
  {Vertices, _Edges} = erlsp_callgraph_extract:extract_edges(<<"file:///callgraph_a.erl">>, Forms),
  lists:sort(Vertices).

forms_a() ->
  Root = fixture("callgraph_project"),
  Path = filename:join(Root, "src/callgraph_a.erl"),
  {ok, Forms} = epp:parse_file(Path, []),
  Forms.

a_local_call_produces_an_edge_to_the_same_module(_Pids) ->
  Edges = edges_for(forms_a()),
  ?_assert(lists:member({{callgraph_a, entry, 1}, {callgraph_a, local_call, 1}}, Edges)).

a_cross_module_remote_call_produces_an_edge_to_the_real_callee(_Pids) ->
  Edges = edges_for(forms_a()),
  ?_assert(lists:member({{callgraph_a, remote_call, 1}, {callgraph_b, helper, 1}}, Edges)).

an_import_resolved_call_produces_an_edge_to_the_imported_module(_Pids) ->
  Edges = edges_for(forms_a()),
  ?_assert(lists:member({{callgraph_a, imported_call, 1}, {lists, reverse, 1}}, Edges)).

a_dynamic_module_call_produces_no_edge(_Pids) ->
  Edges = edges_for(forms_a()),
  HasEdgeFromDynamicModuleCall = lists:any(
    fun({{callgraph_a, dynamic_module_call, 2}, _Callee}) -> true; (_Other) -> false end,
    Edges
  ),
  ?_assertNot(HasEdgeFromDynamicModuleCall).

a_dynamic_function_call_produces_no_edge(_Pids) ->
  Edges = edges_for(forms_a()),
  HasEdgeFromDynamicFunctionCall = lists:any(
    fun({{callgraph_a, dynamic_function_call, 2}, _Callee}) -> true; (_Other) -> false end,
    Edges
  ),
  ?_assertNot(HasEdgeFromDynamicFunctionCall).

apply_3_produces_an_edge_to_erlang_apply_3_not_the_dynamic_target(_Pids) ->
  Edges = edges_for(forms_a()),
  ?_assertEqual(
    [{{callgraph_a, apply_call, 2}, {erlang, apply, 3}}],
    [Edge || {{callgraph_a, apply_call, 2}, _Callee} = Edge <- Edges]
  ).

a_function_with_no_calls_has_a_vertex_and_no_outgoing_edges(_Pids) ->
  Vertices = vertices_for(forms_a()),
  Edges = edges_for(forms_a()),
  HasLeafVertex = lists:any(
    fun({{callgraph_a, leaf, 0}, _Uri, _Line}) -> true; (_Other) -> false end,
    Vertices
  ),
  HasEdgeFromLeaf = lists:any(
    fun({{callgraph_a, leaf, 0}, _Callee}) -> true; (_Other) -> false end,
    Edges
  ),
  HasEdgeIntoLeaf = lists:any(
    fun({_Caller, {callgraph_a, leaf, 0}}) -> true; (_Other) -> false end,
    Edges
  ),
  [
    ?_assert(HasLeafVertex),
    ?_assertNot(HasEdgeFromLeaf),
    ?_assert(HasEdgeIntoLeaf)
  ].

a_function_never_called_still_gets_a_vertex(_Pids) ->
  Vertices = vertices_for(forms_a()),
  HasEntryVertex = lists:any(
    fun({{callgraph_a, entry, 1}, _Uri, _Line}) -> true; (_Other) -> false end,
    Vertices
  ),
  ?_assert(HasEntryVertex).

calls_nested_in_case_try_and_a_list_comprehension_are_all_found(_Pids) ->
  Edges = edges_for(forms_a()),
  EdgesFromNestedCalls = [Callee || {{callgraph_a, nested_calls, 1}, Callee} <- Edges],
  [
    %% case branches
    ?_assert(lists:member({callgraph_a, leaf, 0}, EdgesFromNestedCalls)),
    ?_assert(lists:member({callgraph_a, local_call, 1}, EdgesFromNestedCalls)),
    %% list comprehension template
    ?_assert(lists:member({callgraph_b, helper, 1}, EdgesFromNestedCalls)),
    %% try body and catch clause
    ?_assert(lists:member({callgraph_a, remote_call, 1}, EdgesFromNestedCalls))
  ].
