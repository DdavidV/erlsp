-module(char_literal).

f() ->
  A = $a,
  B = $\n,
  C = $\\,
  D = $',
  E = $",
  F = $ ,
  ok.
