-module(keywords).

f(X) ->
  case X of
    1 -> ok;
    _ when X > 1 -> big;
    _ -> other
  end.

g(X) ->
  if
    X > 0 -> positive;
    true -> other
  end.

h() ->
  receive
    {msg, X} -> X
  after 1000 ->
    timeout
  end.

i() ->
  try
    risky()
  catch
    error:Reason -> {error, Reason}
  end.

j() ->
  fun(X) -> X + 1 end.

k(A, B) ->
  A andalso B orelse (A and B) or (A xor B),
  not A,
  A band B,
  A bor B,
  A bxor B,
  bnot A,
  A bsl 1,
  A bsr 1,
  A div B,
  A rem B.
