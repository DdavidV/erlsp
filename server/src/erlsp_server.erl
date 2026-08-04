-module(erlsp_server).

-behaviour(gen_server).

-include("erlsp.hrl").
-include_lib("kernel/include/logger.hrl").

-type jobs_for_uri() :: #{module() => pid()}.
-type jobs() :: #{erlsp_documents:uri() => jobs_for_uri()}.

-record(state, {io :: pid(), jobs :: jobs()}).

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
  Info :: term(),
  State :: state(),
  Result :: {noreply, state()} | {stop, term(), state()}.
handle_info({worker_result, WorkerPid, Uri, JobModule, Result}, State) ->
  JobsForUri = maps:get(Uri, State#state.jobs, #{}),
  NewState = case maps:find(JobModule, JobsForUri) of
    {ok, WorkerPid} ->
      ?LOG_DEBUG("~p result for ~s: ~p", [JobModule, Uri, Result]),
      RemainingJobs = remove_job(Uri, JobModule, State#state.jobs),
      handle_job_result(JobModule, Uri, Result, State#state{jobs = RemainingJobs});
    _ ->
      %% Stale/cancelled job's result arrived after a newer job took its place, ignore.
      State
  end,
  {noreply, NewState};
handle_info({'EXIT', IoPid, Reason}, #state{io = IoPid} = State) ->
  ?LOG_ERROR("erlsp_io exited: ~p", [Reason]),
  {stop, Reason, State};
handle_info(Info, State) ->
  ?LOG_WARNING("unexpected message: ~p", [Info]),
  {noreply, State}.

-spec terminate(Reason, State) -> Result when
  Reason :: term(),
  State :: state(),
  Result :: ok.
terminate(_Reason, _State) ->
  ok.

%% Removes JobModule's slot for Uri from Jobs, cleaning up the outer Uri
%% entry too once it's left empty (so cancel_jobs_for_uri/2 sees nothing
%% for a Uri with no jobs, rather than a stale empty map).
-spec remove_job(Uri, JobModule, Jobs) -> Result when
  Uri :: erlsp_documents:uri(),
  JobModule :: module(),
  Jobs :: jobs(),
  Result :: jobs().
remove_job(Uri, JobModule, Jobs) ->
  JobsForUri = maps:remove(JobModule, maps:get(Uri, Jobs, #{})),
  case map_size(JobsForUri) of
    0 -> maps:remove(Uri, Jobs);
    _Size -> Jobs#{Uri => JobsForUri}
  end.

%% Cancels any existing JobModule job for Uri, then starts a new one
%% running JobModule:run(Uri), recording it in Jobs.
%% Independent of whatever other job kinds are running for the same Uri.
-spec start_job(Uri, JobModule, Jobs) -> Result when
  Uri :: erlsp_documents:uri(),
  JobModule :: module(),
  Jobs :: jobs(),
  Result :: jobs().
start_job(Uri, JobModule, Jobs) ->
  CancelledJobs = cancel_job(Uri, JobModule, Jobs),
  {ok, WorkerPid} = erlsp_worker_sup:start_worker(self(), Uri, JobModule),
  JobsForUri = maps:get(Uri, CancelledJobs, #{}),
  CancelledJobs#{Uri => JobsForUri#{JobModule => WorkerPid}}.

%% Cancels JobModule's in-flight job for Uri, if any, leaving any other
%% job kind running for that same Uri untouched.
-spec cancel_job(Uri, JobModule, Jobs) -> Result when
  Uri :: erlsp_documents:uri(),
  JobModule :: module(),
  Jobs :: jobs(),
  Result :: jobs().
cancel_job(Uri, JobModule, Jobs) ->
  JobsForUri = maps:get(Uri, Jobs, #{}),
  case maps:find(JobModule, JobsForUri) of
    {ok, WorkerPid} ->
      exit(WorkerPid, kill),
      remove_job(Uri, JobModule, Jobs);
    error ->
      Jobs
  end.

%% Cancels every in-flight job for Uri, regardless of kind - used when a
%% document closes, since nothing further should run against it.
-spec cancel_jobs_for_uri(Uri, Jobs) -> Result when
  Uri :: erlsp_documents:uri(),
  Jobs :: jobs(),
  Result :: jobs().
cancel_jobs_for_uri(Uri, Jobs) ->
  JobsForUri = maps:get(Uri, Jobs, #{}),
  [exit(WorkerPid, kill) || WorkerPid <- maps:values(JobsForUri)],
  maps:remove(Uri, Jobs).

%% Dispatches a finished job's result to whatever it should do next. Each
%% job module gets its own clause here, since different job types produce
%% differently-shaped results.
-spec handle_job_result(JobModule, Uri, Result, State) -> state() when
  JobModule :: module(),
  Uri :: erlsp_documents:uri(),
  Result :: term(),
  State :: state().
handle_job_result(JobModule, Uri, {job_crashed, Class, Reason, Stacktrace}, State) ->
  ?LOG_ERROR("~p crashed for ~s: ~p:~p~n~p", [JobModule, Uri, Class, Reason, Stacktrace]),
  State;
handle_job_result(erlsp_diag_compiler, Uri, Diagnostics, State) ->
  publish_diagnostics(Uri, Diagnostics),
  State;
handle_job_result(erlsp_index_job, Uri, ok, State) ->
  Jobs0 = start_job(Uri, erlsp_index_otp_job, State#state.jobs),
  Jobs = start_job(Uri, erlsp_index_deps_job, Jobs0),
  State#state{jobs = Jobs};
handle_job_result(erlsp_index_otp_job, _Uri, ok, State) ->
  State;
handle_job_result(erlsp_index_deps_job, _Uri, ok, State) ->
  State;
handle_job_result(erlsp_index_file_job, _Uri, ok, State) ->
  State.

-spec publish_diagnostics(Uri, Diagnostics) -> Result when
  Uri :: erlsp_documents:uri(),
  Diagnostics :: [erlsp_job:diagnostic()],
  Result :: ok.
publish_diagnostics(Uri, Diagnostics) ->
  Params = #{uri => Uri, diagnostics => Diagnostics},
  erlsp_io:send(erlsp_jsonrpc:notification(<<"textDocument/publishDiagnostics">>, Params)).

-spec handle_message(Message, State) -> NewState when
  Message :: map(),
  State :: state(),
  NewState :: state().
handle_message(#{id := Id, method := <<"initialize">>, params := Params}, State) ->
  ?LOG_INFO("received initialize request"),
  #{rootUri := RootUri} = Params,
  ok = erlsp_config:init_workspace(RootUri),
  Capabilities = #{
    textDocumentSync => #{
      openClose => true,
      change => ?TEXT_DOCUMENT_SYNC_FULL,
      save => #{includeText => false}
    },
    definitionProvider => true,
    completionProvider => #{triggerCharacters => [<<":">>, <<"?">>, <<"#">>]}
  },
  erlsp_io:send(erlsp_jsonrpc:reply(Id, #{capabilities => Capabilities})),
  Jobs = start_job(RootUri, erlsp_index_job, State#state.jobs),
  State#state{jobs = Jobs};
handle_message(#{id := Id, method := <<"shutdown">>}, State) ->
  erlsp_io:send(erlsp_jsonrpc:reply(Id, null)),
  State;
handle_message(#{method := <<"textDocument/didOpen">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri, text := Text}} = Params,
  erlsp_documents:open(Uri, Text),
  Jobs = start_job(Uri, erlsp_diag_compiler, State#state.jobs),
  State#state{jobs = Jobs};
handle_message(#{method := <<"textDocument/didChange">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri}, contentChanges := Changes} = Params,
  #{text := Text} = lists:last(Changes),
  erlsp_documents:update(Uri, Text),
  State;
handle_message(#{method := <<"textDocument/didSave">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri}} = Params,
  Jobs0 = start_job(Uri, erlsp_diag_compiler, State#state.jobs),
  Jobs = start_job(Uri, erlsp_index_file_job, Jobs0),
  State#state{jobs = Jobs};
handle_message(#{method := <<"textDocument/didClose">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri}} = Params,
  erlsp_documents:close(Uri),
  Jobs = cancel_jobs_for_uri(Uri, State#state.jobs),
  publish_diagnostics(Uri, []),
  State#state{jobs = Jobs};
handle_message(#{id := Id, method := <<"textDocument/definition">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri}, position := #{line := Line, character := Character}} = Params,
  Result = case erlsp_definition:locate(Uri, Line, Character) of
    {ok, {DefinitionUri, DefinitionLine}} ->
      Position = #{line => DefinitionLine - 1, character => 0},
      #{uri => DefinitionUri, range => #{start => Position, 'end' => Position}};
    error ->
      null
  end,
  erlsp_io:send(erlsp_jsonrpc:reply(Id, Result)),
  State;
handle_message(#{id := Id, method := <<"textDocument/completion">>, params := Params}, State) ->
  #{textDocument := #{uri := Uri}, position := #{line := Line, character := Character}} = Params,
  Items = erlsp_completion:complete(Uri, Line, Character),
  erlsp_io:send(erlsp_jsonrpc:reply(Id, Items)),
  State;
handle_message(#{id := Id, method := Method}, State) ->
  ?LOG_WARNING("method not found: ~s", [Method]),
  erlsp_io:send(erlsp_jsonrpc:error(Id, ?JSONRPC_METHOD_NOT_FOUND, <<"Method not found">>)),
  State;
handle_message(_Message, State) ->
  State.
