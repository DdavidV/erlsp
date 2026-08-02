-module(erlsp_server).

-behaviour(gen_server).

-include("erlsp.hrl").
-include_lib("kernel/include/logger.hrl").

-record(state, {io :: pid(), jobs :: #{erlsp_documents:uri() => {module(), pid()}}}).

-type state() :: #state{}.

-export([
  start_link/0,
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2
]).

-spec start_link() -> Result when
  Result :: {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?ERLSP_SERVER}, ?MODULE, [], []).

-spec init(InitArgs) -> Result when
  InitArgs :: term(),
  Result :: {ok, state()}.
init(_InitArgs) ->
  process_flag(trap_exit, true),
  {ok, IoPid} = erlsp_io:start_link(),
  {ok, #state{io = IoPid, jobs = #{}}}.

-spec handle_call(Request, From, State) -> Result when
  Request :: term(),
  From :: {pid(), term()},
  State :: state(),
  Result :: {reply, ok, state()}.
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

-spec handle_cast(Request, State) -> Result when
  Request :: {message, map()} | io_closed,
  State :: state(),
  Result :: {noreply, state()} | {stop, normal, state()}.
handle_cast({message, Message}, State) ->
  NewState = handle_message(Message, State),
  {noreply, NewState};
handle_cast(io_closed, State) ->
  ?LOG_INFO("stdin closed, shutting down"),
  {stop, normal, State}.

-spec handle_info(Info, State) -> Result when
  Info :: {worker_result, pid(), erlsp_documents:uri(), module(), term()},
  State :: state(),
  Result :: {noreply, state()}.
handle_info({worker_result, WorkerPid, Uri, JobModule, Result}, State) ->
  NewState = case maps:find(Uri, State#state.jobs) of
    {ok, {JobModule, WorkerPid}} ->
      ?LOG_DEBUG("~p result for ~s: ~p", [JobModule, Uri, Result]),
      State#state{jobs = maps:remove(Uri, State#state.jobs)};
    _ ->
      %% Stale/cancelled job's result arrived after a newer job took its place, ignore.
      State
  end,
  {noreply, NewState}.

-spec terminate(Reason, State) -> Result when
  Reason :: term(),
  State :: state(),
  Result :: ok.
terminate(_Reason, _State) ->
  ok.

%% Cancels any in-flight job for Uri and removes it from Jobs.
-spec cancel_job(Uri, Jobs) -> Result when
  Uri :: erlsp_documents:uri(),
  Jobs :: #{erlsp_documents:uri() => {module(), pid()}},
  Result :: #{erlsp_documents:uri() => {module(), pid()}}.
cancel_job(Uri, Jobs) ->
  case maps:find(Uri, Jobs) of
    {ok, {_JobModule, WorkerPid}} ->
      exit(WorkerPid, kill),
      maps:remove(Uri, Jobs);
    error ->
      Jobs
  end.

%% Cancels any existing job for Uri, then starts a new one running
%% JobModule:run(Uri) (see erlsp_job), recording it in Jobs.
-spec start_job(Uri, JobModule, Jobs) -> Result when
  Uri :: erlsp_documents:uri(),
  JobModule :: module(),
  Jobs :: #{erlsp_documents:uri() => {module(), pid()}},
  Result :: #{erlsp_documents:uri() => {module(), pid()}}.
start_job(Uri, JobModule, Jobs) ->
  CancelledJobs = cancel_job(Uri, Jobs),
  {ok, WorkerPid} = erlsp_worker_sup:start_worker(self(), Uri, JobModule),
  CancelledJobs#{Uri => {JobModule, WorkerPid}}.

-spec handle_message(Message, State) -> NewState when
  Message :: map(),
  State :: state(),
  NewState :: state().
handle_message(#{id := Id, method := <<"initialize">>}, State) ->
  ?LOG_INFO("received initialize request"),
  Capabilities = #{
    textDocumentSync => #{
      openClose => true,
      change => ?TEXT_DOCUMENT_SYNC_FULL
    }
  },
  erlsp_io:send(erlsp_jsonrpc:reply(Id, #{capabilities => Capabilities})),
  State;
handle_message(#{id := Id, method := <<"shutdown">>}, State) ->
  erlsp_io:send(erlsp_jsonrpc:reply(Id, null)),
  State;
handle_message(#{method := <<"textDocument/didOpen">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri, text := Text}} = Params,
  erlsp_documents:open(Uri, Text),
  State;
handle_message(#{method := <<"textDocument/didChange">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri}, contentChanges := Changes} = Params,
  #{text := Text} = lists:last(Changes),
  erlsp_documents:update(Uri, Text),
  State;
handle_message(#{method := <<"textDocument/didClose">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri}} = Params,
  erlsp_documents:close(Uri),
  Jobs = cancel_job(Uri, State#state.jobs),
  State#state{jobs = Jobs};
handle_message(#{id := Id, method := Method}, State) ->
  ?LOG_WARNING("method not found: ~s", [Method]),
  erlsp_io:send(erlsp_jsonrpc:error(Id, ?JSONRPC_METHOD_NOT_FOUND, <<"Method not found">>)),
  State;
handle_message(_Message, State) ->
  State.
