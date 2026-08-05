-module(erlsp_index_workspace_job).

-behaviour(erlsp_job).

-include_lib("kernel/include/logger.hrl").

-export([
  run/2
]).

%% Indexes every .erl file in every project (rebar3/Mix app) found under
%% the workspace root (a workspace may contain several independent
%% sibling projects, each with its own include paths, not just one).
%% Deliberately kept separate from erlsp_index_otp_job (which indexes
%% OTP's much larger source tree) so workspace-local go-to-definition is
%% available quickly rather than waiting on hundreds of OTP files too.
-spec run(Uri, Token) -> Result when
  Uri :: erlsp_documents:uri(),
  Token :: erlsp_report:token(),
  Result :: ok.
run(_Uri, Token) ->
  erlsp_report:report(Token, {'begin', <<"Indexing">>}),
  ProjectRoots = erlsp_config:project_roots(),
  Paths = lists:append([workspace_erl_files(ProjectRoot) || ProjectRoot <- ProjectRoots]),
  ?LOG_INFO("indexing ~b workspace files across ~b project(s)",
            [length(Paths), length(ProjectRoots)]),
  erlsp_index:index_files(Paths, Token, <<"workspace files">>),
  ?LOG_INFO("workspace indexing complete"),
  erlsp_report:report(Token, done),
  ok.

-spec workspace_erl_files(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
workspace_erl_files(ProjectRoot) ->
  %% "**" recurses into subdirectories (e.g. src/jobs/*.erl), not just
  %% Dir's immediate contents - a plain "*.erl" glob would silently miss
  %% any .erl file nested one level deeper.
  lists:append([filelib:wildcard(filename:join(Dir, "**/*.erl"))
               || Dir <- erlsp_config:source_dirs_for_root(ProjectRoot)]).
