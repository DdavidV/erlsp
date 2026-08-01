-module(records).

-record(state, {io :: pid()}).
-record('quoted record', {a, b}).

f() ->
  S = #state{io = self()},
  #state.io,
  S2 = S#state{io = undefined},
  #'quoted record'{a = 1, b = 2}.
