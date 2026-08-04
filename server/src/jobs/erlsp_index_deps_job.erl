-module(erlsp_index_deps_job).

-behaviour(erlsp_job).

-include_lib("kernel/include/logger.hrl").

-export([
  run/1
]).

%% Indexes every fetched dependency's source for every project found
%% under the workspace root, so go-to-definition also works for calls
%% into a project's own deps, not just its own modules and OTP's.
%% Deliberately kept separate from erlsp_index_job (workspace) and
%% erlsp_index_otp_job (OTP) so those stay quick.
-spec run(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: ok.
run(_Uri) ->
  ProjectRoots = erlsp_config:project_roots(),
  Paths = lists:append([dep_erl_files(ProjectRoot) || ProjectRoot <- ProjectRoots]),
  ?LOG_INFO("indexing ~b dependency files across ~b project(s)", [length(Paths), length(ProjectRoots)]),
  lists:foreach(fun erlsp_index:index_file/1, Paths),
  ?LOG_INFO("dependency indexing complete"),
  ok.

-spec dep_erl_files(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
dep_erl_files(ProjectRoot) ->
  lists:append([filelib:wildcard(filename:join(Dir, "**/*.erl"))
               || Dir <- erlsp_config:dep_source_dirs_for_root(ProjectRoot)]).
