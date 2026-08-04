-module(erlsp_job).

-include("erlsp.hrl").

%% LSP DiagnosticSeverity: 3 = Information, 4 = Hint are not produced by any job yet.
-type severity() :: ?DIAGNOSTIC_SEVERITY_ERROR | ?DIAGNOSTIC_SEVERITY_WARNING.
-type position() :: #{line := non_neg_integer(), character := non_neg_integer()}.
-type range() :: #{start := position(), 'end' := position()}.
-type diagnostic() :: #{
  range := range(),
  severity := severity(),
  source := binary(),
  message := binary()
}.

%% A job's progress against erlsp_report:token()'s sequence: 'begin' opens
%% it (with a human-readable title), 'update' reports a step along the way
%% (with a message and 0-100 percentage), done closes it. See
%% erlsp_report:report/2.
-type report() :: {'begin', unicode:chardata()}
                 | {update, unicode:chardata(), 0..100}
                 | done.

-export_type([
  diagnostic/0,
  severity/0,
  position/0,
  range/0,
  report/0
]).

-export([
  run/2
]).

%% Behaviour for work erlsp_server offloads onto erlsp_worker_sup. A job
%% module receives only the document's Uri and is responsible for fetching
%% whatever state it needs (e.g. via erlsp_documents:get_text/1) itself.
%% The return value becomes the Result in
%% {worker_result, WorkerPid, Uri, Result}, sent back to whoever started
%% the job (see erlsp_worker:run/3).
%%
%% A job implements exactly one of these two: run/1 if it never reports
%% progress, or run/2 if it wants to - run/2 receives a fresh
%% erlsp_report:token() to report against via erlsp_report:report/2,
%% however often/wherever in its body it likes.
-callback run(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: term().

-callback run(Uri, Token) -> Result when
  Uri :: erlsp_documents:uri(),
  Token :: erlsp_report:token(),
  Result :: term().

-optional_callbacks([run/1, run/2]).

-spec run(JobModule, Uri) -> Result when
  JobModule :: module(),
  Uri :: erlsp_documents:uri(),
  Result :: term().
run(JobModule, Uri) ->
  %% function_exported/3 only sees already-loaded modules; job modules
  %% aren't necessarily loaded yet the first time a job runs.
  code:ensure_loaded(JobModule),
  case erlang:function_exported(JobModule, run, 2) of
    true ->
      Token = erlsp_report:start(JobModule, Uri),
      run_with_report(JobModule, Uri, Token);
    false ->
      JobModule:run(Uri)
  end.

%% $/progress has no client-side timeout: a token left open after a crash
%% would leave its progress bar stuck in the UI forever, not just fail
%% silently server-side. So a crash here still ends Token before re-raising,
%% letting erlsp_worker's own try/catch keep producing {job_crashed, ...} exactly
%% as it does for a run/1 job.
-spec run_with_report(JobModule, Uri, Token) -> Result when
  JobModule :: module(),
  Uri :: erlsp_documents:uri(),
  Token :: erlsp_report:token(),
  Result :: term().
run_with_report(JobModule, Uri, Token) ->
  try
    JobModule:run(Uri, Token)
  catch
    Class:Reason:Stacktrace ->
      erlsp_report:report(Token, done),
      erlang:raise(Class, Reason, Stacktrace)
  end.
