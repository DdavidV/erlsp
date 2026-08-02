-module(guard_function).

f(X) when is_list(X) ->
  is_atom(X),
  is_integer(X),
  element(1, X),
  hd(X),
  erlang:is_list(X),
  ok.
