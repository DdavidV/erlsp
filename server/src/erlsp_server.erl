-module(erlsp_server).

-behaviour(gen_server).

-include("erlsp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([
  start_link/0,
  init/1,
  handle_call/3,
  handle_cast/2,
  terminate/2
]).

-record(state, {io :: pid()}).
-type state() :: #state{}.

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
  {ok, #state{io = IoPid}}.

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
  handle_message(Message),
  {noreply, State};
handle_cast(io_closed, State) ->
  ?LOG_INFO("stdin closed, shutting down"),
  {stop, normal, State}.

-spec terminate(Reason, State) -> Result when
  Reason :: term(),
  State :: state(),
  Result :: ok.
terminate(_Reason, _State) ->
  ok.

handle_message(#{<<"id">> := Id, <<"method">> := <<"initialize">>}) ->
  ?LOG_INFO("received initialize request"),
  Capabilities = #{
    <<"textDocumentSync">> => #{
      <<"openClose">> => true,
      <<"change">> => ?TEXT_DOCUMENT_SYNC_FULL
    }
  },
  erlsp_io:send(erlsp_jsonrpc:reply(Id, #{<<"capabilities">> => Capabilities}));
handle_message(#{<<"id">> := Id, <<"method">> := <<"shutdown">>}) ->
  erlsp_io:send(erlsp_jsonrpc:reply(Id, null));
handle_message(#{<<"method">> := <<"textDocument/didOpen">>, <<"params">> := Params}) ->
  #{<<"textDocument">> := #{<<"uri">> := Uri, <<"text">> := Text}} = Params,
  erlsp_documents:open(Uri, Text);
handle_message(#{<<"method">> := <<"textDocument/didChange">>, <<"params">> := Params}) ->
  #{<<"textDocument">> := #{<<"uri">> := Uri}, <<"contentChanges">> := Changes} = Params,
  #{<<"text">> := Text} = lists:last(Changes),
  erlsp_documents:update(Uri, Text);
handle_message(#{<<"method">> := <<"textDocument/didClose">>, <<"params">> := Params}) ->
  #{<<"textDocument">> := #{<<"uri">> := Uri}} = Params,
  erlsp_documents:close(Uri);
handle_message(#{<<"id">> := Id, <<"method">> := Method}) ->
  ?LOG_WARNING("method not found: ~s", [Method]),
  erlsp_io:send(erlsp_jsonrpc:error(Id, ?JSONRPC_METHOD_NOT_FOUND, <<"Method not found">>));
handle_message(_Message) ->
  ok.
