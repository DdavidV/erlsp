-module(erlsp_index_job).

-behaviour(erlsp_job).

-include_lib("kernel/include/logger.hrl").

-export([
  run/1
]).

%% Indexes every .erl file in the workspace.
%% Deliberately kept separate from erlsp_index_otp_job (which indexes
%% OTP's much larger source tree) so workspace-local go-to-definition is
%% available quickly rather than waiting on hundreds of OTP files too.
-spec run(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: ok.
run(_Uri) ->
  Paths = workspace_erl_files(),
  ?LOG_INFO("indexing ~b workspace files", [length(Paths)]),
  lists:foreach(fun erlsp_index:index_file/1, Paths),
  ?LOG_INFO("workspace indexing complete"),
  ok.

-spec workspace_erl_files() -> Result when
  Result :: [file:filename()].
workspace_erl_files() ->
  %% "**" recurses into subdirectories (e.g. src/jobs/*.erl), not just
  %% Dir's immediate contents - a plain "*.erl" glob would silently miss
  %% any .erl file nested one level deeper.
  lists:append([filelib:wildcard(filename:join(Dir, "**/*.erl"))
               || Dir <- erlsp_config:include_paths()]).
