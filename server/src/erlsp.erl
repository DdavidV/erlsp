-module(erlsp).

-include("erlsp.hrl").

-export([main/1]).

-spec main(Args) -> Result when
  Args :: term(),
  Result :: ok.
main(_Args) ->
  {ok, _} = application:ensure_all_started(?APP_NAME, permanent),
  Ref = monitor(process, whereis(?ERLSP_SERVER)),
  receive
    {'DOWN', Ref, process, _Pid, _Reason} -> ok
  end.
