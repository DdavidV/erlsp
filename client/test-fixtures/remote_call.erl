-module(remote_call).

-define(F, f).

f() ->
  application:get_env(erlsp, some_key, default_value),
  gen_server:start_link({local, ?ERLSP_SERVER}, ?MODULE, [], []),
  lists:map(fun(X) -> X end, [1, 2, 3]),
  m:F(),
  M:f(),
  m:?F().
