-module(callgraph_a).

-export([
  entry/1,
  leaf/0,
  local_call/1,
  remote_call/1,
  imported_call/1,
  dynamic_module_call/2,
  dynamic_function_call/2,
  apply_call/2,
  nested_calls/1
]).

-import(lists, [reverse/1]).

%% entry/1 is never called from within this fixture project - it only
%% appears as a vertex with zero incoming edges, proving vertices come
%% from definitions, not just call targets.
entry(X) ->
  local_call(X).

%% leaf/0 has zero outgoing edges.
leaf() ->
  ok.

local_call(X) ->
  callgraph_b:helper(X).

remote_call(X) ->
  callgraph_b:helper(X).

imported_call(X) ->
  reverse(X).

dynamic_module_call(Mod, X) ->
  Mod:helper(X).

dynamic_function_call(Fun, X) ->
  callgraph_b:Fun(X).

apply_call(Mod, X) ->
  apply(Mod, helper, [X]).

nested_calls(X) ->
  Result = case X of
    [] -> leaf();
    _ -> local_call(X)
  end,
  Mapped = [callgraph_b:helper(Item) || Item <- Result],
  try
    remote_call(Mapped)
  catch
    _:_ -> leaf()
  end.
