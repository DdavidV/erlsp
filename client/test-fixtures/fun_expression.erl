-module(fun_expression).

f() ->
  A = fun handle/2,
  B = fun lists:map/2,
  C = fun(X) -> X + 1 end,
  D = fun(X, Y) -> X + Y end,
  lists:map(fun(X) -> X * 2 end, [1, 2, 3]).
