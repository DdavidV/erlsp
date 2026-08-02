-module(erlsp_worker_sup).

-behaviour(supervisor).

-export([
  start_link/0,
  init/1
]).

-export([
  start_worker/3
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
    strategy => one_for_one,
    intensity => 10,
    period => 10
  },
  {ok, {SupFlags, []}}.

-spec start_worker(ReplyTo, Uri, Fun) -> Result when
  ReplyTo :: pid(),
  Uri :: erlsp_documents:uri(),
  Fun :: fun(() -> term()),
  Result :: {ok, pid()}.
start_worker(ReplyTo, Uri, Fun) ->
  ChildSpec = #{
    id => make_ref(),
    start => {erlsp_worker, start_link, [ReplyTo, Uri, Fun]},
    restart => temporary,
    shutdown => brutal_kill
  },
  supervisor:start_child(?MODULE, ChildSpec).
