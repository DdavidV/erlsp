-module(erlsp_job).

-export([
  run/2
]).

%% Behaviour for work erlsp_server offloads onto erlsp_worker_sup. A job
%% module receives only the document's Uri and is responsible for fetching
%% whatever state it needs (e.g. via erlsp_documents:get_text/1) itself.
%% The return value becomes the Result in
%% {worker_result, WorkerPid, Uri, Result}, sent back to whoever started
%% the job (see erlsp_worker:run/3).
-callback run(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: term().

-spec run(JobModule, Uri) -> Result when
  JobModule :: module(),
  Uri :: erlsp_documents:uri(),
  Result :: term().
run(JobModule, Uri) ->
  JobModule:run(Uri).
