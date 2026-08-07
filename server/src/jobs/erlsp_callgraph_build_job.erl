-module(erlsp_callgraph_build_job).

-behaviour(erlsp_job).

-include_lib("kernel/include/logger.hrl").

-export([
  run/2
]).

%% Builds the whole-workspace call graph backing the "erlsp: Show Call Graph" command.
-spec run(Uri, Token) -> Result when
  Uri :: erlsp_documents:uri(),
  Token :: erlsp_report:token(),
  Result :: ok.
run(_Uri, Token) ->
  ?LOG_INFO("building call graph"),
  ok = erlsp_callgraph:ensure_built(Token),
  ?LOG_INFO("call graph build complete"),
  ok.
