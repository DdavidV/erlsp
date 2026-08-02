-module(language_constant).

f() ->
  true,
  false,
  undefined,
  X = true andalso false,
  Y = case X of
    undefined -> false;
    _ -> true
  end,
  ok.
