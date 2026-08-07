-module(erlsp_callgraph_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erlsp_test_utils, [fixture/1]).

setup() ->
  {ok, IndexPid} = erlsp_index:start_link(),
  {ok, ConfigPid} = erlsp_config:start_link(),
  {ok, CallgraphPid} = erlsp_callgraph:start_link(),
  Root = fixture("callgraph_project"),
  ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(Root)),
  {IndexPid, ConfigPid, CallgraphPid}.

teardown({IndexPid, ConfigPid, CallgraphPid}) ->
  gen_server:stop(IndexPid),
  gen_server:stop(ConfigPid),
  gen_server:stop(CallgraphPid).

erlsp_callgraph_test_() ->
  {foreach, fun setup/0, fun teardown/1, [
    fun status_starts_as_not_built/1,
    fun ensure_built_builds_the_whole_workspace_graph_and_flips_status_to_built/1,
    fun ensure_built_is_a_cheap_no_op_once_already_built/1,
    fun clear_resets_status_to_not_built/1,
    fun snapshot_has_a_node_per_vertex/1,
    fun snapshot_marks_external_nodes_without_location_data/1,
    fun snapshot_marks_workspace_nodes_with_location_data/1,
    fun snapshot_has_one_edge_per_edge/1
  ]}.

build(_Pids) ->
  Token = make_ref(),
  ok = erlsp_callgraph:ensure_built(Token).

status_starts_as_not_built(_Pids) ->
  ?_assertEqual(not_built, erlsp_callgraph:status()).

ensure_built_builds_the_whole_workspace_graph_and_flips_status_to_built(Pids) ->
  build(Pids),
  ?_assertEqual(built, erlsp_callgraph:status()).

ensure_built_is_a_cheap_no_op_once_already_built(Pids) ->
  build(Pids),
  #{nodes := FirstNodes, edges := FirstEdges} = erlsp_callgraph:snapshot(),
  build(Pids),
  #{nodes := SecondNodes, edges := SecondEdges} = erlsp_callgraph:snapshot(),
  [
    ?_assertEqual(lists:sort(FirstNodes), lists:sort(SecondNodes)),
    ?_assertEqual(lists:sort(FirstEdges), lists:sort(SecondEdges))
  ].

clear_resets_status_to_not_built(Pids) ->
  build(Pids),
  ok = erlsp_callgraph:clear(),
  ?_assertEqual(not_built, erlsp_callgraph:status()).

snapshot_has_a_node_per_vertex(Pids) ->
  build(Pids),
  #{nodes := Nodes} = erlsp_callgraph:snapshot(),
  [
    ?_assert(has_node(Nodes, <<"callgraph_a">>, <<"local_call">>, 1)),
    ?_assert(has_node(Nodes, <<"callgraph_b">>, <<"helper">>, 1)),
    ?_assert(has_node(Nodes, <<"lists">>, <<"reverse">>, 1))
  ].

snapshot_marks_external_nodes_without_location_data(Pids) ->
  build(Pids),
  #{nodes := Nodes} = erlsp_callgraph:snapshot(),
  Node = find_node(Nodes, <<"lists">>, <<"reverse">>, 1),
  [
    ?_assertEqual(external, maps:get(origin, Node)),
    ?_assertNot(maps:is_key(uri, Node)),
    ?_assertNot(maps:is_key(line, Node))
  ].

snapshot_marks_workspace_nodes_with_location_data(Pids) ->
  build(Pids),
  #{nodes := Nodes} = erlsp_callgraph:snapshot(),
  Node = find_node(Nodes, <<"callgraph_b">>, <<"helper">>, 1),
  [
    ?_assertEqual(workspace, maps:get(origin, Node)),
    ?_assert(maps:is_key(uri, Node)),
    ?_assert(maps:is_key(line, Node))
  ].

snapshot_has_one_edge_per_edge(Pids) ->
  build(Pids),
  #{edges := Edges} = erlsp_callgraph:snapshot(),
  ?_assert(length(Edges) >= 9).

has_node(Nodes, Module, Function, Arity) ->
  find_node(Nodes, Module, Function, Arity) =/= not_found.

find_node(Nodes, Module, Function, Arity) ->
  case lists:search(
    fun(#{module := M, function := F, arity := A}) -> M =:= Module andalso F =:= Function andalso A =:= Arity end,
    Nodes
  ) of
    {value, Node} -> Node;
    false -> not_found
  end.
