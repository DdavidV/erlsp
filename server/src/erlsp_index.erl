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
  index_files/3,
  module_location/1,
  function_location/3,
  function_param_names/3,
  type_location/3,
  record_location/2,
  macro_location/2,
  included_uris/1,
  functions_in_module/1,
  types_in_module/1,
  records_in_module/1,
  macros_in_uri/1,
  all_modules/0
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
  code:add_pathsz(erlsp_config:ebin_paths_for_root(ProjectRoot)),
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

%% Indexes every Path in Paths, reporting {update, ...} against Token
%% whenever the rounded percentage changes plus always on the last file
%% so the final report reflects 100% exactly. Each report's message shows
%% a live "Current/Total Unit" count (e.g. "342/809 files") rather than a
%% static label.
-spec index_files(Paths, Token, Unit) -> Result when
  Paths :: [file:filename()],
  Token :: erlsp_report:token(),
  Unit :: unicode:chardata(),
  Result :: ok.
index_files(Paths, Token, Unit) ->
  Total = length(Paths),
  index_files(Paths, Token, Unit, 0, Total).

-spec index_files(Paths, Token, Unit, Current, Total) -> Result when
  Paths :: [file:filename()],
  Token :: erlsp_report:token(),
  Unit :: unicode:chardata(),
  Current :: non_neg_integer(),
  Total :: non_neg_integer(),
  Result :: ok.
index_files([], _Token, _Unit, _Current, _Total) ->
  ok;
index_files([Path | Rest], Token, Unit, Current, Total) ->
  index_file(Path),
  NewCurrent = Current + 1,
  case should_report_progress(Current, NewCurrent, Total) of
    true ->
      Message = unicode:characters_to_binary(io_lib:format("~b/~b ~s", [NewCurrent, Total, Unit])),
      erlsp_report:report(Token, {update, Message, progress_percentage(NewCurrent, Total)});
    false -> ok
  end,
  index_files(Rest, Token, Unit, NewCurrent, Total).

%% Reports on the very first and very last file and otherwise only when the rounded
%% percentage actually changes from the previous file to this one.
-spec should_report_progress(PreviousCurrent, NewCurrent, Total) -> Result when
  PreviousCurrent :: non_neg_integer(),
  NewCurrent :: non_neg_integer(),
  Total :: non_neg_integer(),
  Result :: boolean().
should_report_progress(_PreviousCurrent, NewCurrent, Total) when NewCurrent =:= Total ->
  true;
should_report_progress(0, _NewCurrent, _Total) ->
  true;
should_report_progress(PreviousCurrent, NewCurrent, Total) when Total > 0 ->
  progress_percentage(PreviousCurrent, Total) =/= progress_percentage(NewCurrent, Total).

-spec progress_percentage(Current, Total) -> Result when
  Current :: non_neg_integer(),
  Total :: non_neg_integer(),
  Result :: 0..100.
progress_percentage(_Current, 0) -> 100;
progress_percentage(Current, Total) -> (Current * 100) div Total.

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
index_forms(Uri, FormUri, Module, [{function, FunLine, Name, Arity, Clauses} | Rest]) ->
  ParamNames = clause_param_names(Clauses),
  ets:insert(?FUNCTIONS_TABLE, {{Module, Name, Arity}, FormUri, anno_line(FunLine), ParamNames}),
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

%% Parameter names for a function's first clause (arbitrarily but
%% consistently - a function's clauses almost always name their
%% parameters the same way anyway), for building a completion snippet
%% with real argument names instead of just "Arg1, Arg2, ...". A
%% parameter that isn't a plain variable pattern (destructuring, a
%% literal, a bare "_") has no single meaningful name, so it falls back
%% to "ArgN" (1-indexed) instead.
-spec clause_param_names(Clauses) -> Result when
  Clauses :: [erl_parse:abstract_clause()],
  Result :: [binary()].
clause_param_names([{clause, _Line, Patterns, _Guards, _Body} | _OtherClauses]) ->
  [param_name(Pattern, Index) || {Pattern, Index} <- lists:zip(Patterns, lists:seq(1, length(Patterns)))];
clause_param_names([]) ->
  [].

-spec param_name(Pattern, Index) -> Result when
  Pattern :: erl_parse:abstract_expr(),
  Index :: pos_integer(),
  Result :: binary().
param_name({var, _Anno, Name}, _Index) when Name =/= '_' ->
  %% A leading underscore (e.g. _Args) marks an intentionally-unused
  %% parameter by convention, not part of the name itself.
  NameString = atom_to_list(Name),
  case NameString of
    [$_ | Rest] when Rest =/= [] -> unicode:characters_to_binary(Rest);
    _ -> unicode:characters_to_binary(NameString)
  end;
param_name(_Pattern, Index) ->
  unicode:characters_to_binary(io_lib:format("Arg~b", [Index])).

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

%% Every indexed module's name, in no particular order.
-spec all_modules() -> Result when
  Result :: [module()].
all_modules() ->
  [Module || {Module, _Uri, _Line} <- ets:tab2list(?MODULES_TABLE)].

-spec function_location(Module, Function, Arity) -> Result when
  Module :: module(),
  Function :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
function_location(Module, Function, Arity) ->
  case ets:lookup(?FUNCTIONS_TABLE, {Module, Function, Arity}) of
    [{{Module, Function, Arity}, Uri, Line, _ParamNames}] -> {ok, {Uri, Line}};
    [] -> error
  end.

%% Function's first clause's parameter names, e.g. [<<"Args">>] for
%% main(_Args)/1 - see clause_param_names/1 for how a parameter that
%% isn't a plain variable pattern gets a generic "ArgN" name instead.
-spec function_param_names(Module, Function, Arity) -> Result when
  Module :: module(),
  Function :: atom(),
  Arity :: arity(),
  Result :: {ok, [binary()]} | error.
function_param_names(Module, Function, Arity) ->
  case ets:lookup(?FUNCTIONS_TABLE, {Module, Function, Arity}) of
    [{{Module, Function, Arity}, _Uri, _Line, ParamNames}] -> {ok, ParamNames};
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

%% Every {Name, Arity} function defined in Module, in no particular order.
-spec functions_in_module(Module) -> Result when
  Module :: module(),
  Result :: [{atom(), arity()}].
functions_in_module(Module) ->
  [{Name, Arity}
  || {{_Module, Name, Arity}, _Uri, _Line, _ParamNames}
     <- ets:match_object(?FUNCTIONS_TABLE, {{Module, '_', '_'}, '_', '_', '_'})].

%% Every {Name, Arity} type defined in Module, in no particular order.
-spec types_in_module(Module) -> Result when
  Module :: module(),
  Result :: [{atom(), arity()}].
types_in_module(Module) ->
  [{Name, Arity} || {{_Module, Name, Arity}, _Uri, _Line}
   <- ets:match_object(?TYPES_TABLE, {{Module, '_', '_'}, '_', '_'})].

%% Every record name defined in Module, in no particular order.
-spec records_in_module(Module) -> Result when
  Module :: module(),
  Result :: [atom()].
records_in_module(Module) ->
  [Name || {{_Module, Name}, _Uri, _Line}
   <- ets:match_object(?RECORDS_TABLE, {{Module, '_'}, '_', '_'})].

%% Every macro name defined directly in Uri (not any header it includes -
%% see macros_visible/1 in erlsp_completion for the transitive version).
-spec macros_in_uri(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: [atom()].
macros_in_uri(Uri) ->
  [Name || {{_Uri, Name}, _DefUri, _Line}
   <- ets:match_object(?MACROS_TABLE, {{Uri, '_'}, '_', '_'})].

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
