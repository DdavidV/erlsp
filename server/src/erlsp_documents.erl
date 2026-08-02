-module(erlsp_documents).

-behaviour(gen_server).

-include("erlsp.hrl").

-record(state, {}).

-type state() :: #state{}.
-type uri() :: binary().
-type text() :: binary().

-export_type([
  uri/0,
  text/0
]).

-export([
  start_link/0,
  init/1,
  handle_call/3,
  handle_cast/2,
  terminate/2
]).

-export([
  open/2,
  update/2,
  close/1,
  get_text/1
]).

-spec start_link() -> Result when
  Result :: {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init(InitArgs) -> Result when
  InitArgs :: term(),
  Result :: {ok, state()}.
init(_InitArgs) ->
  ets:new(?MODULE, [set, public, named_table, {read_concurrency, true}]),
  {ok, #state{}}.

-spec open(Uri, Text) -> Result when
  Uri :: uri(),
  Text :: text(),
  Result :: ok.
open(Uri, Text) ->
  true = ets:insert(?MODULE, {Uri, Text}),
  ok.

-spec update(Uri, Text) -> Result when
  Uri :: uri(),
  Text :: text(),
  Result :: ok.
update(Uri, Text) ->
  true = ets:insert(?MODULE, {Uri, Text}),
  ok.

-spec close(Uri) -> Result when
  Uri :: uri(),
  Result :: ok.
close(Uri) ->
  true = ets:delete(?MODULE, Uri),
  ok.

-spec get_text(Uri) -> Result when
  Uri :: uri(),
  Result :: {ok, text()} | error.
get_text(Uri) ->
  case ets:lookup(?MODULE, Uri) of
    [{Uri, Text}] -> {ok, Text};
    [] -> error
  end.

-spec handle_call(Request, From, State) -> Result when
  Request :: term(),
  From :: {pid(), term()},
  State :: state(),
  Result :: {reply, ok, state()}.
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

-spec handle_cast(Request, State) -> Result when
  Request :: term(),
  State :: state(),
  Result :: {noreply, state()}.
handle_cast(_Request, State) ->
  {noreply, State}.

-spec terminate(Reason, State) -> Result when
  Reason :: term(),
  State :: state(),
  Result :: ok.
terminate(_Reason, _State) ->
  ok.
