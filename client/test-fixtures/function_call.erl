-module(function_call).

f() ->
  ok.

g(M, F) ->
  f(),
  handle_message(M, F),
  erlang:apply(M, F, []).

-spec h() -> ok.
h() ->
  g(f, f),
  ok.
