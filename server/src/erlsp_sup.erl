-module(erlsp_sup).

-behaviour(supervisor).

-export([
  start_link/0,
  init/1
]).

-spec start_link() -> Result when
  Result :: {ok, pid()}.
start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init(InitArgs) -> Result when
  InitArgs :: term(),
  Result :: {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(_InitArgs) ->
  SupFlags = #{
    intensity => 5,
    period => 10
  },
  ChildSpecs = [
    #{
      id => erlsp_documents,
      start => {erlsp_documents, start_link, []}
    },
    %% Start erlsp_server last so that messages are only handled after every service is operational
    #{
      id => erlsp_server,
      start => {erlsp_server, start_link, []}
    }
  ],
  {ok, {SupFlags, ChildSpecs}}.
