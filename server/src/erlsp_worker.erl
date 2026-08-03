-module(erlsp_worker).

-export([
  start_link/3,
  run/3
]).

-spec start_link(ReplyTo, Uri, JobModule) -> Result when
  ReplyTo :: pid(),
  Uri :: erlsp_documents:uri(),
  JobModule :: module(),
  Result :: {ok, pid()}.
start_link(ReplyTo, Uri, JobModule) ->
  proc_lib:start_link(?MODULE, run, [ReplyTo, Uri, JobModule]).

-spec run(ReplyTo, Uri, JobModule) -> Result when
  ReplyTo :: pid(),
  Uri :: erlsp_documents:uri(),
  JobModule :: module(),
  Result :: ok.
run(ReplyTo, Uri, JobModule) ->
  proc_lib:init_ack({ok, self()}),
  Result =
    try
      erlsp_job:run(JobModule, Uri)
    catch
      Class:Reason:Stacktrace ->
        {job_crashed, Class, Reason, Stacktrace}
    end,
  ReplyTo ! {worker_result, self(), Uri, JobModule, Result},
  ok.
