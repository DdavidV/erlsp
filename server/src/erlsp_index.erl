-module(erlsp_index).

-behaviour(gen_server).

-define(FUNCTIONS_TABLE, erlsp_index_functions).
-define(MODULES_TABLE, erlsp_index_modules).
-define(TYPES_TABLE, erlsp_index_types).
-define(RECORDS_TABLE, erlsp_index_records).
-define(MACROS_TABLE, erlsp_index_macros).
-define(INCLUDES_TABLE, erlsp_index_includes).

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
  function_location/3,
  type_location/3,
  record_location/2,
  macro_location/2,
  included_uris/1
]).

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
  ets:new(?TYPES_TABLE, [set, public, named_table, {read_concurrency, true}]),
  ets:new(?RECORDS_TABLE, [set, public, named_table, {read_concurrency, true}]),
  ets:new(?MACROS_TABLE, [set, public, named_table, {read_concurrency, true}]),
  ets:new(?INCLUDES_TABLE, [set, public, named_table, {read_concurrency, true}]),
  {ok, #state{}}.

%% Parses Path and records where its module, functions, types, records and
%% macros are defined, and which headers it includes.
-spec index_file(Path) -> Result when
  Path :: file:filename(),
  Result :: ok.
index_file(Path) ->
  IncludeDir = filename:join(filename:dirname(Path), "../include"),
  ProjectRoot = erlsp_config:project_root_for_path(Path),
  IncludePaths = [IncludeDir | erlsp_config:include_paths_for_root(ProjectRoot)],
  case epp:parse_file(Path, [{includes, IncludePaths}]) of
    {ok, Forms} ->
      Uri = erlsp_uri:from_path(Path),
      index_forms(Uri, Forms),
      IncludedPaths = included_paths(Path, Forms),
      IncludedUris = [index_header(HeaderPath) || HeaderPath <- IncludedPaths],
      true = ets:insert(?INCLUDES_TABLE, {Uri, IncludedUris}),
      index_macros(Uri, Path);
    {error, _Reason} ->
      ok
  end.

%% Every other file's path mentioned in Forms' -file markers (which epp
%% emits, in order, at every file transition during preprocessing - see
%% https://www.erlang.org/doc/apps/erts/absform.html) - i.e. every header
%% Path transitively -include/-include_libs, with paths already resolved
%% against the real search paths by epp itself.
-spec included_paths(Path, Forms) -> Result when
  Path :: file:filename(),
  Forms :: [erl_parse:abstract_form()],
  Result :: [file:filename()].
included_paths(Path, Forms) ->
  AbsPath = filename:absname(Path),
  lists:usort([OtherPath
              || {attribute, _Line, file, {OtherPath, _FileLine}} <- Forms,
              filename:absname(OtherPath) =/= AbsPath]).

%% Indexes HeaderPath's own macros and returns its Uri.
-spec index_header(HeaderPath) -> Result when
  HeaderPath :: file:filename(),
  Result :: erlsp_documents:uri().
index_header(HeaderPath) ->
  Uri = erlsp_uri:from_path(HeaderPath),
  index_macros(Uri, HeaderPath),
  Uri.

-spec index_forms(Uri, Forms) -> Result when
  Uri :: erlsp_documents:uri(),
  Forms :: [erl_parse:abstract_form()],
  Result :: ok.
index_forms(Uri, Forms) ->
  case lists:search(fun is_module_attribute/1, Forms) of
    {value, {attribute, ModuleLine, module, Module}} ->
      true = ets:insert(?MODULES_TABLE, {Module, Uri, anno_line(ModuleLine)}),
      index_forms(Uri, Uri, Module, Forms);
    false ->
      %% No -module attribute: nothing to index.
      ok
  end.

-spec index_forms(Uri, FormUri, Module, Forms) -> Result when
  Uri :: erlsp_documents:uri(),
  FormUri :: erlsp_documents:uri(),
  Module :: module(),
  Forms :: [erl_parse:abstract_form()],
  Result :: ok.
index_forms(Uri, _FormUri, Module, [{attribute, _Line, file, {OtherPath, _FileLine}} | Rest]) ->
  index_forms(Uri, erlsp_uri:from_path(OtherPath), Module, Rest);
index_forms(Uri, FormUri, Module, [{function, FunLine, Name, Arity, _Clauses} | Rest]) ->
  ets:insert(?FUNCTIONS_TABLE, {{Module, Name, Arity}, FormUri, anno_line(FunLine)}),
  index_forms(Uri, FormUri, Module, Rest);
index_forms(Uri, FormUri, Module, [{attribute, TypeLine, Kind, {Name, _TypeDef, Params}} | Rest])
    when Kind =:= type; Kind =:= opaque ->
  ets:insert(?TYPES_TABLE, {{Module, Name, length(Params)}, FormUri, anno_line(TypeLine)}),
  index_forms(Uri, FormUri, Module, Rest);
index_forms(Uri, FormUri, Module, [{attribute, RecordLine, record, {Name, _Fields}} | Rest]) ->
  ets:insert(?RECORDS_TABLE, {{Module, Name}, FormUri, anno_line(RecordLine)}),
  index_forms(Uri, FormUri, Module, Rest);
index_forms(Uri, FormUri, Module, [_OtherForm | Rest]) ->
  index_forms(Uri, FormUri, Module, Rest);
index_forms(_Uri, _FormUri, _Module, []) ->
  ok.

%% Macros aren't preserved in Forms), so Uri's own raw text is tokenized directly.
%% Keyed by Uri (the file the -define actually appears in, whether an
%% .erl or a .hrl).
-spec index_macros(Uri, Path) -> Result when
  Uri :: erlsp_documents:uri(),
  Path :: file:filename(),
  Result :: ok.
index_macros(Uri, Path) ->
  case file:read_file(Path) of
    {ok, Bytes} ->
      case erl_scan:string(unicode:characters_to_list(Bytes), {1, 1}) of
        {ok, Tokens, _EndLocation} ->
          [ets:insert(?MACROS_TABLE, {{Uri, Name}, Uri, Line})
          || {Name, Line} <- macro_defines(Tokens)],
          ok;
        {error, _ErrorInfo, _EndLocation} ->
          ok
      end;
    {error, _Reason} ->
      ok
  end.

%% Scans Tokens for -define(NAME, ...) / -define(NAME(Args), ...) forms,
%% returning each macro's name and defining line.
-spec macro_defines(Tokens) -> Result when
  Tokens :: [erl_scan:token()],
  Result :: [{atom(), non_neg_integer()}].
macro_defines([{'-', _}, {atom, _, define}, {'(', _}, NameToken | Rest])
    when element(1, NameToken) =:= var; element(1, NameToken) =:= atom ->
  {_TokenKind, Location, Name} = NameToken,
  {Line, _Column} = Location,
  [{Name, Line} | macro_defines(Rest)];
macro_defines([_Token | Rest]) ->
  macro_defines(Rest);
macro_defines([]) ->
  [].

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

-spec type_location(Module, Type, Arity) -> Result when
  Module :: module(),
  Type :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
type_location(Module, Type, Arity) ->
  case ets:lookup(?TYPES_TABLE, {Module, Type, Arity}) of
    [{{Module, Type, Arity}, Uri, Line}] -> {ok, {Uri, Line}};
    [] -> error
  end.

-spec record_location(Module, Record) -> Result when
  Module :: module(),
  Record :: atom(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
record_location(Module, Record) ->
  case ets:lookup(?RECORDS_TABLE, {Module, Record}) of
    [{{Module, Record}, Uri, Line}] -> {ok, {Uri, Line}};
    [] -> error
  end.

%% Uri here is the file to look for Macro's own -define in directly - not
%% necessarily where the macro is used. Callers wanting to resolve a
%% ?MACRO usage should also check included_uris/1 for that file, since a
%% macro is often defined in an included header instead.
-spec macro_location(Uri, Macro) -> Result when
  Uri :: erlsp_documents:uri(),
  Macro :: atom(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
macro_location(Uri, Macro) ->
  case ets:lookup(?MACROS_TABLE, {Uri, Macro}) of
    [{{Uri, Macro}, Uri, Line}] -> {ok, {Uri, Line}};
    [] -> error
  end.

%% The headers Uri transitively -include/-include_libs, in no particular order.
-spec included_uris(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: [erlsp_documents:uri()].
included_uris(Uri) ->
  case ets:lookup(?INCLUDES_TABLE, Uri) of
    [{Uri, IncludedUris}] -> IncludedUris;
    [] -> []
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
