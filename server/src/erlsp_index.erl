-module(erlsp_index).

-behaviour(gen_server).

-record(state, {}).

-type state() :: #state{}.

-export([
  start_link/0,
  init/1,
  handle_call/3,
  handle_cast/2,
  terminate/2
]).

-export([
  index_file/1,
  module_location/1,
  function_location/3
]).

-define(FUNCTIONS_TABLE, erlsp_index_functions).
-define(MODULES_TABLE, erlsp_index_modules).

-spec start_link() -> Result when
  Result :: {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init(InitArgs) -> Result when
  InitArgs :: term(),
  Result :: {ok, state()}.
init(_InitArgs) ->
  ets:new(?FUNCTIONS_TABLE, [set, public, named_table, {read_concurrency, true}]),
  ets:new(?MODULES_TABLE, [set, public, named_table, {read_concurrency, true}]),
  {ok, #state{}}.

%% Parses Path and records where its module and functions are defined.
-spec index_file(Path) -> Result when
  Path :: file:filename(),
  Result :: ok.
index_file(Path) ->
  IncludeDir = filename:join(filename:dirname(Path), "../include"),
  case epp:parse_file(Path, [{includes, [IncludeDir | erlsp_config:include_paths()]}]) of
    {ok, Forms} ->
      Uri = erlsp_uri:from_path(Path),
      index_forms(Uri, Forms);
    {error, _Reason} ->
      ok
  end.

-spec index_forms(Uri, Forms) -> Result when
  Uri :: erlsp_documents:uri(),
  Forms :: [erl_parse:abstract_form()],
  Result :: ok.
index_forms(Uri, Forms) ->
  case lists:search(fun is_module_attribute/1, Forms) of
    {value, {attribute, ModuleLine, module, Module}} ->
      true = ets:insert(?MODULES_TABLE, {Module, Uri, anno_line(ModuleLine)}),
      [ets:insert(?FUNCTIONS_TABLE, {{Module, Name, Arity}, Uri, anno_line(FunLine)})
      || {function, FunLine, Name, Arity, _Clauses} <- Forms],
      ok;
    false ->
      %% No -module attribute: nothing to index.
      ok
  end.

-spec is_module_attribute(Form) -> Result when
  Form :: erl_parse:abstract_form(),
  Result :: boolean().
is_module_attribute({attribute, _Line, module, _Module}) -> true;
is_module_attribute(_Form) -> false.

-spec anno_line(Anno) -> Result when
  Anno :: erl_anno:anno() | non_neg_integer(),
  Result :: non_neg_integer().
anno_line(Line) when is_integer(Line) -> Line;
anno_line(Anno) -> erl_anno:line(Anno).

-spec module_location(Module) -> Result when
  Module :: module(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
module_location(Module) ->
  case ets:lookup(?MODULES_TABLE, Module) of
    [{Module, Uri, Line}] -> {ok, {Uri, Line}};
    [] -> error
  end.

-spec function_location(Module, Function, Arity) -> Result when
  Module :: module(),
  Function :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
function_location(Module, Function, Arity) ->
  case ets:lookup(?FUNCTIONS_TABLE, {Module, Function, Arity}) of
    [{{Module, Function, Arity}, Uri, Line}] -> {ok, {Uri, Line}};
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
