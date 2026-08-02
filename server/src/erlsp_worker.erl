-module(erlsp_worker).

-export([
  start_link/3,
  run/3
]).

-spec start_link(ReplyTo, Uri, Fun) -> Result when
  ReplyTo :: pid(),
  Uri :: erlsp_documents:uri(),
  Fun :: fun(() -> term()),
  Result :: {ok, pid()}.
start_link(ReplyTo, Uri, Fun) ->
  proc_lib:start_link(?MODULE, run, [ReplyTo, Uri, Fun]).

-spec run(ReplyTo, Uri, Fun) -> Result when
  ReplyTo :: pid(),
  Uri :: erlsp_documents:uri(),
  Fun :: fun(() -> term()),
  Result :: ok.
run(ReplyTo, Uri, Fun) ->
  proc_lib:init_ack({ok, self()}),
  Result = Fun(),
  ReplyTo ! {worker_result, self(), Uri, Result},
  ok.
