-module(erlsp_index_file_job).

-behaviour(erlsp_job).

-export([
  run/1
]).

%% Re-indexes Uri's file on disk.
%% Run on every save so the index doesn't drift out of sync with edits.
-spec run(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: ok.
run(Uri) ->
  Path = erlsp_uri:to_path(Uri),
  erlsp_index:index_file(Path).
