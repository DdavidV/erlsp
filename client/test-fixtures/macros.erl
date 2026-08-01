-module(macros).

-define(TIMEOUT, 5000).
-define(IS_DEFINED, true).

start_link() ->
  gen_server:start_link({local, ?ERLSP_SERVER}, ?MODULE, [], []).

wait() ->
  receive
    _ -> ok
  after ?TIMEOUT ->
    timeout
  end.

check() ->
  ?assertEqual(1, 1),
  ??QUOTED_MACRO.
