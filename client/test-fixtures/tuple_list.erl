-module(tuple_list).

f() ->
  T = {ok, 1, "value"},
  L = [1, 2, 3],
  L2 = [H | Tail] = L,
  L3 = [X || X <- L, X > 1],
  Nested = {ok, [1, {a, 2}, [3, 4]]},
  T.
