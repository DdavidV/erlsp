-module(operators).

f(X) ->
  X.

g(#{key := Value} = Map) ->
  Map2 = Map#{key => Value},
  A = 1 =< 2,
  B = 2 >= 1,
  C = 1 == 1,
  D = 1 /= 2,
  E = 1 =:= 1,
  F = 1 =/= 2,
  [H | T] = [1, 2, 3],
  L = [1, 2] ++ [3, 4],
  L2 = [1, 2, 3] -- [2],
  ok.
