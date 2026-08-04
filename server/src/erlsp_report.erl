-module(erlsp_report).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-record(state, {}).

-type state() :: #state{}.

-type token() :: pos_integer().

-export([
  start_link/0,
  init/1,
  handle_call/3,
  handle_cast/2,
  terminate/2
]).

-export([
  start/2,
  report/2
]).

-export_type([
  token/0
]).

-spec start_link() -> Result when
  Result :: {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init(InitArgs) -> Result when
  InitArgs :: term(),
  Result :: {ok, state()}.
init(_InitArgs) ->
  {ok, #state{}}.

%% Mints a fresh Token identifying one progress sequence, for JobModule's
%% run against Uri. Callers report against it via report/2, in any order/
%% cadence they like - starting one here doesn't itself send anything to
%% the client, the first report/2 call does.
-spec start(JobModule, Uri) -> Token when
  JobModule :: module(),
  Uri :: erlsp_documents:uri(),
  Token :: token().
start(JobModule, Uri) ->
  Token = erlang:unique_integer([positive, monotonic]),
  ?LOG_DEBUG("started progress token ~p for ~p on ~s", [Token, JobModule, Uri]),
  Token.

%% Reports Token's next step to the client, translated into the
%% appropriate $/progress notification.
-spec report(Token, Report) -> Result when
  Token :: token(),
  Report :: erlsp_job:report(),
  Result :: ok.
report(Token, Report) ->
  gen_server:cast(?MODULE, {report, Token, Report}).

-spec handle_call(Request, From, State) -> Result when
  Request :: term(),
  From :: {pid(), term()},
  State :: state(),
  Result :: {reply, ok, state()}.
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

-spec handle_cast(Request, State) -> Result when
  Request :: {report, erlsp_report:token(), erlsp_job:report()},
  State :: state(),
  Result :: {noreply, state()}.
handle_cast({report, Token, {'begin', Title}}, State) ->
  %% Send create request
  RequestId = erlang:unique_integer([positive, monotonic]),
  Message =
    erlsp_jsonrpc:request(RequestId, <<"window/workDoneProgress/create">>, #{token => Token}),
  erlsp_io:send(Message),
  send_progress(Token, #{kind => <<"begin">>, title => Title}),
  {noreply, State};
handle_cast({report, Token, {update, Message, Percentage}}, State) ->
  send_progress(Token, #{kind => <<"report">>, message => Message, percentage => Percentage}),
  {noreply, State};
handle_cast({report, Token, done}, State) ->
  send_progress(Token, #{kind => <<"end">>}),
  {noreply, State}.

-spec terminate(Reason, State) -> Result when
  Reason :: term(),
  State :: state(),
  Result :: ok.
terminate(_Reason, _State) ->
  ok.

-spec send_progress(Token, Value) -> Result when
  Token :: token(),
  Value :: map(),
  Result :: ok.
send_progress(Token, Value) ->
  Message = erlsp_jsonrpc:notification(<<"$/progress">>, #{token => Token, value => Value}),
  erlsp_io:send(Message).
