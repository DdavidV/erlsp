-module(erlsp_index).

-behaviour(gen_server).

-define(FUNCTIONS_TABLE, erlsp_index_functions).
-define(MODULES_TABLE, erlsp_index_modules).
-define(TYPES_TABLE, erlsp_index_types).
-define(RECORDS_TABLE, erlsp_index_records).
-define(MACROS_TABLE, erlsp_index_macros).
-define(INCLUDES_TABLE, erlsp_index_includes).
-define(IMPORTS_TABLE, erlsp_index_imports).
-define(SPECS_TABLE, erlsp_index_specs).
-define(DOCS_TABLE, erlsp_index_docs).
-define(FILE_LINES_CACHE_KEY, erlsp_index_file_lines_cache).

-record(state, {}).

-type state() :: #state{}.
-type doc_value() :: string() | binary() | false | hidden | map().


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
  clear/0,
  remove_uri/1,
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
  all_modules/0,
  imported_module/3,
  function_spec/3,
  function_doc/3,
  type_doc/3,
  module_doc/1,
  macro_definition_text/2
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
  ets:new(?IMPORTS_TABLE, [set, public, named_table, {read_concurrency, true}]),
  ets:new(?SPECS_TABLE, [set, public, named_table, {read_concurrency, true}]),
  ets:new(?DOCS_TABLE, [set, public, named_table, {read_concurrency, true}]),
  {ok, #state{}}.

%% Deletes every indexed entry without recreating the tables - used by a
%% full reindex, so a file that's since been deleted/renamed doesn't
%% leave stale entries behind.
-spec clear() -> Result when
  Result :: ok.
clear() ->
  ets:delete_all_objects(?FUNCTIONS_TABLE),
  ets:delete_all_objects(?MODULES_TABLE),
  ets:delete_all_objects(?TYPES_TABLE),
  ets:delete_all_objects(?RECORDS_TABLE),
  ets:delete_all_objects(?MACROS_TABLE),
  ets:delete_all_objects(?INCLUDES_TABLE),
  ets:delete_all_objects(?IMPORTS_TABLE),
  ets:delete_all_objects(?SPECS_TABLE),
  ets:delete_all_objects(?DOCS_TABLE),
  ok.

%% Removes every entry defined directly IN Uri.
-spec remove_uri(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: ok.
remove_uri(Uri) ->
  case ets:match_object(?MODULES_TABLE, {'_', Uri, '_'}) of
    [{Module, Uri, _Line}] ->
      ets:match_delete(?IMPORTS_TABLE, {{Module, '_', '_'}, '_'}),
      ets:match_delete(?SPECS_TABLE, {{Module, '_', '_'}, '_'}),
      ets:match_delete(?DOCS_TABLE, {{Module, '_', '_', '_'}, '_'}),
      ets:delete(?DOCS_TABLE, {Module, module});
    [] ->
      ok
  end,
  ets:match_delete(?FUNCTIONS_TABLE, {{'_', '_', '_'}, Uri, '_', '_'}),
  ets:match_delete(?MODULES_TABLE, {'_', Uri, '_'}),
  ets:match_delete(?TYPES_TABLE, {{'_', '_', '_'}, Uri, '_'}),
  ets:match_delete(?RECORDS_TABLE, {{'_', '_'}, Uri, '_'}),
  ets:match_delete(?MACROS_TABLE, {{Uri, '_'}, Uri, '_', '_'}),
  ets:delete(?INCLUDES_TABLE, Uri),
  ok.

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
  %% edoc_fallback/2 (called once per undocumented function/type - i.e.
  %% often, at OTP-indexing scale) reads whichever file it's given, but
  %% the vast majority of calls within one index_file/1 are for the same
  %% file (Path itself; only forms that came in through a -file marker,
  %% e.g. via a macro expansion, point elsewhere). Caching each file's
  %% already-read lines in the process dictionary for the span of this
  %% call turns what would otherwise be one file:read_file/1 per
  %% definition into at most one per distinct file actually touched -
  %% without it, indexing ~800 OTP files (most functions undocumented in
  %% many third-party projects) re-reads the same file hundreds of times over.
  put(?FILE_LINES_CACHE_KEY, #{}),
  try
    case epp:parse_file(Path, [{includes, IncludePaths}]) of
      {ok, Forms} ->
        Uri = erlsp_utils:path_to_uri(Path),
        index_forms(Uri, Forms),
        IncludedPaths = included_paths(Path, Forms),
        IncludedUris = [index_header(HeaderPath) || HeaderPath <- IncludedPaths],
        true = ets:insert(?INCLUDES_TABLE, {Uri, IncludedUris}),
        index_macros(Uri, Path);
      {error, _Reason} ->
        ok
    end
  after
    erase(?FILE_LINES_CACHE_KEY)
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
  Uri = erlsp_utils:path_to_uri(HeaderPath),
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
      index_forms(Uri, Uri, Module, undefined, undefined, Forms);
    false ->
      %% No -module attribute: nothing to index.
      ok
  end.

%% PendingDoc carries a -doc attribute's value forward to whichever
%% function/type form immediately follows it - matching the placement
%% convention OTP's own stdlib source uses (-doc directly before -spec,
%% -spec directly before the function/type it describes). PendingSpecLine
%% carries a -spec attribute's own source line forward the same way, so a
%% legacy EDoc "%%" comment block (which precedes -spec, not the function
%% clause itself) is looked for starting above the -spec, not above the
%% function. Both are cleared every time they're consumed (or skipped
%% over by an unrelated form), so neither ever attaches to the wrong
%% definition.
-spec index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, Forms) -> Result when
  Uri :: erlsp_documents:uri(),
  FormUri :: erlsp_documents:uri(),
  Module :: module(),
  PendingDoc :: doc_value() | undefined,
  PendingSpecLine :: non_neg_integer() | undefined,
  Forms :: [erl_parse:abstract_form()],
  Result :: ok.
index_forms(Uri, _FormUri, Module, PendingDoc, PendingSpecLine, [{attribute, _Line, file, {OtherPath, _FileLine}} | Rest]) ->
  index_forms(Uri, erlsp_utils:path_to_uri(OtherPath), Module, PendingDoc, PendingSpecLine, Rest);
index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, [{attribute, _Line, moduledoc, DocValue} | Rest]) ->
  index_doc_value({Module, module}, DocValue),
  index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, Rest);
index_forms(Uri, FormUri, Module, _PendingDoc, PendingSpecLine, [{attribute, _Line, doc, DocValue} | Rest]) ->
  index_forms(Uri, FormUri, Module, DocValue, PendingSpecLine, Rest);
index_forms(Uri, FormUri, Module, PendingDoc, _PendingSpecLine, [{attribute, SpecLine, spec, {{Name, Arity}, _Clauses}} = Form | Rest]) ->
  ets:insert(?SPECS_TABLE, {{Module, Name, Arity}, spec_text(Form)}),
  index_forms(Uri, FormUri, Module, PendingDoc, anno_line(SpecLine), Rest);
index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, [{function, FunLine, Name, Arity, Clauses} | Rest]) ->
  ParamNames = clause_param_names(Clauses),
  ets:insert(?FUNCTIONS_TABLE, {{Module, Name, Arity}, FormUri, anno_line(FunLine), ParamNames}),
  EDocSearchLine = first_defined(PendingSpecLine, anno_line(FunLine)),
  index_doc_value({Module, function, Name, Arity}, PendingDoc,
    fun() -> edoc_fallback(FormUri, EDocSearchLine) end),
  index_forms(Uri, FormUri, Module, undefined, undefined, Rest);
index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, [{attribute, TypeLine, Kind, {Name, _TypeDef, Params}} | Rest])
    when Kind =:= type; Kind =:= opaque ->
  Arity = length(Params),
  ets:insert(?TYPES_TABLE, {{Module, Name, Arity}, FormUri, anno_line(TypeLine)}),
  index_doc_value({Module, type, Name, Arity}, PendingDoc,
    fun() -> edoc_fallback(FormUri, anno_line(TypeLine)) end),
  index_forms(Uri, FormUri, Module, undefined, PendingSpecLine, Rest);
index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, [{attribute, RecordLine, record, {Name, _Fields}} | Rest]) ->
  ets:insert(?RECORDS_TABLE, {{Module, Name}, FormUri, anno_line(RecordLine)}),
  index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, Rest);
index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, [{attribute, _Line, import, {ImportedModule, NamesAndArities}} | Rest]) ->
  [ets:insert(?IMPORTS_TABLE, {{Module, Name, Arity}, ImportedModule})
  || {Name, Arity} <- NamesAndArities],
  index_forms(Uri, FormUri, Module, PendingDoc, PendingSpecLine, Rest);
index_forms(Uri, FormUri, Module, _PendingDoc, _PendingSpecLine, [_OtherForm | Rest]) ->
  index_forms(Uri, FormUri, Module, undefined, undefined, Rest);
index_forms(_Uri, _FormUri, _Module, _PendingDoc, _PendingSpecLine, []) ->
  ok.

-spec first_defined(Primary, Fallback) -> Result when
  Primary :: non_neg_integer() | undefined,
  Fallback :: non_neg_integer(),
  Result :: non_neg_integer().
first_defined(undefined, Fallback) -> Fallback;
first_defined(Primary, _Fallback) -> Primary.

%% Records Key's doc text from a -moduledoc's DocValue - no EDoc fallback
%% for module docs, since EDoc has no real module-level doc convention to
%% fall back to.
-spec index_doc_value(Key, DocValue) -> Result when
  Key :: {module(), module},
  DocValue :: doc_value(),
  Result :: ok.
index_doc_value(Key, DocValue) ->
  case doc_text(DocValue) of
    {ok, Text} -> ets:insert(?DOCS_TABLE, {Key, Text});
    none -> ok
  end.

%% Records Key's doc text: PendingDoc's value if a -doc attribute
%% immediately preceded this definition, otherwise EDocFallback() - the
%% "%%" comment block directly above the definition, for legacy projects
%% that predate -doc (OTP 27+) and never migrated. -doc false/hidden
%% suppresses documentation outright, matching the author's intent - it
%% does not fall back to EDoc.
-spec index_doc_value(Key, PendingDoc, EDocFallback) -> Result when
  Key :: {module(), function | type, atom(), arity()},
  PendingDoc :: doc_value() | undefined,
  EDocFallback :: fun(() -> binary() | none),
  Result :: ok.
index_doc_value(_Key, false, _EDocFallback) ->
  ok;
index_doc_value(_Key, hidden, _EDocFallback) ->
  ok;
index_doc_value(Key, PendingDoc, _EDocFallback) when PendingDoc =/= undefined ->
  case doc_text(PendingDoc) of
    {ok, Text} -> ets:insert(?DOCS_TABLE, {Key, Text});
    %% A -doc #{...} metadata-only form with no PendingDoc text of its own
    %% still counts as "this definition has -doc", so EDoc is not tried.
    none -> ok
  end;
index_doc_value(Key, undefined, EDocFallback) ->
  case EDocFallback() of
    Text when is_binary(Text) -> ets:insert(?DOCS_TABLE, {Key, Text});
    none -> ok
  end.

-spec doc_text(DocValue) -> Result when
  DocValue :: doc_value(),
  Result :: {ok, binary()} | none.
doc_text(DocValue) when is_list(DocValue) -> {ok, unicode:characters_to_binary(DocValue)};
doc_text(DocValue) when is_binary(DocValue) -> {ok, DocValue};
doc_text(_DocValue) -> none.

%% erl_pp:form/1 pretty-prints the whole -spec attribute back to source
%% text, including "-spec" and the trailing ".", exactly as it would read
%% in the file.
-spec spec_text(Form) -> Result when
  Form :: erl_parse:abstract_form(),
  Result :: binary().
spec_text(Form) ->
  unicode:characters_to_binary(erl_pp:form(Form)).

%% EDoc-convention fallback for a legacy project with no -doc attributes:
%% the contiguous run of "%%"-prefixed lines immediately above
%% DefinitionLine in FormUri's own source, stopping at the first
%% non-comment (or blank) line. Returns none if FormUri can't be read or
%% there's no such block directly above the definition.
-spec edoc_fallback(FormUri, DefinitionLine) -> Result when
  FormUri :: erlsp_documents:uri(),
  DefinitionLine :: non_neg_integer(),
  Result :: binary() | none.
edoc_fallback(FormUri, DefinitionLine) when DefinitionLine > 1 ->
  case cached_file_lines(FormUri) of
    {ok, Lines} ->
      %% DefinitionLine is 1-indexed; the line directly above it is at
      %% list index DefinitionLine - 2 (0-indexed list, minus the
      %% definition's own line).
      LinesAbove = lists:sublist(Lines, max(1, DefinitionLine - 1)),
      CommentBlock = trailing_comment_block(lists:reverse(LinesAbove), []),
      case CommentBlock of
        [] -> none;
        _NonEmpty -> unicode:characters_to_binary(lists:join(<<"\n">>, CommentBlock))
      end;
    error ->
      none
  end;
edoc_fallback(_FormUri, _DefinitionLine) ->
  none.

%% FormUri's source split into lines, read from disk at most once per
%% index_file/1 call regardless of how many definitions in that file end
%% up calling edoc_fallback/2 - see the process-dictionary cache set up in
%% index_file/1.
-spec cached_file_lines(FormUri) -> Result when
  FormUri :: erlsp_documents:uri(),
  Result :: {ok, [binary()]} | error.
cached_file_lines(FormUri) ->
  Cache = case get(?FILE_LINES_CACHE_KEY) of
    undefined -> #{};
    ExistingCache -> ExistingCache
  end,
  case maps:find(FormUri, Cache) of
    {ok, CachedResult} ->
      CachedResult;
    error ->
      Result = read_file_lines(FormUri),
      put(?FILE_LINES_CACHE_KEY, Cache#{FormUri => Result}),
      Result
  end.

-spec read_file_lines(FormUri) -> Result when
  FormUri :: erlsp_documents:uri(),
  Result :: {ok, [binary()]} | error.
read_file_lines(FormUri) ->
  case file:read_file(erlsp_utils:uri_to_path(FormUri)) of
    {ok, Bytes} -> {ok, string:split(unicode:characters_to_binary(Bytes), <<"\n">>, all)};
    {error, _Reason} -> error
  end.

%% ReverseLinesAbove is every line above the definition, nearest first.
%% Collects the contiguous run of "%%"-prefixed lines starting at the
%% line directly above the definition, stopping at the first line that
%% isn't a "%%" comment (Acc is already in reading order by construction,
%% since each new match is prepended while walking upward).
-spec trailing_comment_block(ReverseLinesAbove, Acc) -> Result when
  ReverseLinesAbove :: [binary()],
  Acc :: [binary()],
  Result :: [binary()].
trailing_comment_block([Line | Rest], Acc) ->
  Trimmed = string:trim(Line, leading),
  case Trimmed of
    <<"%%", CommentText/binary>> ->
      trailing_comment_block(Rest, [string:trim(CommentText) | Acc]);
    _NotAComment ->
      Acc
  end;
trailing_comment_block([], Acc) ->
  Acc.

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
      Text = unicode:characters_to_binary(Bytes),
      case erl_scan:string(unicode:characters_to_list(Text), {1, 1}) of
        {ok, Tokens, _EndLocation} ->
          Lines = string:split(Text, <<"\n">>, all),
          [ets:insert(?MACROS_TABLE, {{Uri, Name}, Uri, Line, macro_text(Lines, DefineTokens)})
          || {Name, Line, DefineTokens} <- macro_defines(Tokens)],
          ok;
        {error, _ErrorInfo, _EndLocation} ->
          ok
      end;
    {error, _Reason} ->
      ok
  end.

%% Scans Tokens for -define(NAME, ...) / -define(NAME(Args), ...) forms,
%% returning each macro's name, defining line, and (when its closing ')'
%% was found within a bounded scan - see take_through_matching_close/3)
%% the full token list from the '-' of "-define" through that ')'
%% (inclusive) so macro_text/2 can recover the exact source text later. A
%% macro body isn't guaranteed to be a well-formed standalone expression
%% (e.g. -define(GUARD, X > 0, X < 10)), so echoing the original source
%% text is more robust than trying to re-render the tokens with erl_pp.
-spec macro_defines(Tokens) -> Result when
  Tokens :: [erl_scan:token()],
  Result :: [{atom(), non_neg_integer(), [erl_scan:token()]} | {atom(), non_neg_integer(), undefined}].
macro_defines([{'-', _} = MinusToken, {atom, _, define} = DefineToken, {'(', _} = OpenToken, NameToken | Rest])
    when element(1, NameToken) =:= var; element(1, NameToken) =:= atom ->
  {_TokenKind, Location, Name} = NameToken,
  {Line, _Column} = Location,
  case take_through_matching_close(Rest, 1, [NameToken, OpenToken, DefineToken, MinusToken]) of
    {ok, DefineTokens, AfterClose} ->
      [{Name, Line, DefineTokens} | macro_defines(AfterClose)];
    overrun ->
      %% No balanced ')' within a sane token budget - happens for real in
      %% OTP source (e.g. observer's ttb.erl has a -define inside an
      %% -ifdef/-else whose body is an intentionally unbalanced code
      %% fragment, since raw erl_scan (unlike epp) doesn't skip the
      %% untaken branch). Index the name/line - still useful for
      %% go-to-definition - just without definition text.
      [{Name, Line, undefined} | macro_defines(Rest)]
  end;
macro_defines([_Token | Rest]) ->
  macro_defines(Rest);
macro_defines([]) ->
  [].

%% Maximum tokens to scan looking for a macro body's closing ')' before
%% giving up - real macro bodies are normally a handful of tokens; this
%% is generous headroom for large ones while still bailing out quickly
%% on a body that will never balance (see macro_defines/1's overrun case).
-define(MACRO_BODY_SCAN_LIMIT, 500).

%% ReverseAcc accumulates matched tokens nearest-first (cheap prepend
%% while scanning), reversed once the opening '(' this call started
%% inside of - Depth 1 - finally closes. Any '(' encountered along the
%% way (nested calls/tuples/etc. in the macro body) increments Depth so
%% its own ')' doesn't end the scan prematurely. Remaining bounds the
%% scan (see ?MACRO_BODY_SCAN_LIMIT) so a body that never balances (a
%% real case - see macro_defines/1) can't run away through the rest of
%% the file.
-spec take_through_matching_close(Tokens, Depth, ReverseAcc) -> Result when
  Tokens :: [erl_scan:token()],
  Depth :: pos_integer(),
  ReverseAcc :: [erl_scan:token()],
  Result :: {ok, [erl_scan:token()], [erl_scan:token()]} | overrun.
take_through_matching_close(Tokens, Depth, ReverseAcc) ->
  take_through_matching_close(Tokens, Depth, ReverseAcc, ?MACRO_BODY_SCAN_LIMIT).

-spec take_through_matching_close(Tokens, Depth, ReverseAcc, Remaining) -> Result when
  Tokens :: [erl_scan:token()],
  Depth :: pos_integer(),
  ReverseAcc :: [erl_scan:token()],
  Remaining :: non_neg_integer(),
  Result :: {ok, [erl_scan:token()], [erl_scan:token()]} | overrun.
take_through_matching_close(_Tokens, _Depth, _ReverseAcc, 0) ->
  overrun;
take_through_matching_close([{'(', _} = Token | Rest], Depth, ReverseAcc, Remaining) ->
  take_through_matching_close(Rest, Depth + 1, [Token | ReverseAcc], Remaining - 1);
take_through_matching_close([{')', _} = Token | Rest], 1, ReverseAcc, _Remaining) ->
  {ok, lists:reverse([Token | ReverseAcc]), Rest};
take_through_matching_close([{')', _} = Token | Rest], Depth, ReverseAcc, Remaining) ->
  take_through_matching_close(Rest, Depth - 1, [Token | ReverseAcc], Remaining - 1);
take_through_matching_close([Token | Rest], Depth, ReverseAcc, Remaining) ->
  take_through_matching_close(Rest, Depth, [Token | ReverseAcc], Remaining - 1);
take_through_matching_close([], _Depth, _ReverseAcc, _Remaining) ->
  %% Ran out of tokens (end of file) before balancing - same "give up,
  %% don't crash" outcome as overrun.
  overrun.

%% The exact source text spanning DefineTokens' first token's start
%% through its last token's end, e.g. "-define(FOO, bar)" for
%% -define(FOO, bar). (the trailing "." is intentionally excluded, since
%% it belongs to the enclosing form, not the macro's own text).
%% undefined when take_through_matching_close/3 gave up (see
%% macro_defines/1) - the macro's name/line are still indexed, just
%% without recoverable definition text.
-spec macro_text(Lines, DefineTokens) -> Result when
  Lines :: [binary()],
  DefineTokens :: [erl_scan:token()] | undefined,
  Result :: binary() | undefined.
macro_text(_Lines, undefined) ->
  undefined;
macro_text(Lines, DefineTokens) ->
  FirstToken = hd(DefineTokens),
  LastToken = lists:last(DefineTokens),
  {StartLine, StartColumn} = erl_scan:location(FirstToken),
  {EndLine, EndColumn} = end_location(LastToken),
  case StartLine =:= EndLine of
    true ->
      Line = lists:nth(StartLine, Lines),
      binary:part(Line, StartColumn - 1, EndColumn - StartColumn);
    false ->
      SpanLines = lists:sublist(Lines, StartLine, EndLine - StartLine + 1),
      [FirstLine | MiddleAndLast] = SpanLines,
      {MiddleLines, [LastLine]} = lists:split(length(MiddleAndLast) - 1, MiddleAndLast),
      FirstLinePart = binary:part(FirstLine, StartColumn - 1, byte_size(FirstLine) - StartColumn + 1),
      LastLinePart = binary:part(LastLine, 0, EndColumn - 1),
      unicode:characters_to_binary(lists:join(<<"\n">>, [FirstLinePart | MiddleLines] ++ [LastLinePart]))
  end.

%% erl_scan:location/1 gives a token's START position - this is its END
%% position (one column past its last character), needed to slice source
%% text up to and including the token itself.
-spec end_location(Token) -> Result when
  Token :: erl_scan:token(),
  Result :: {non_neg_integer(), non_neg_integer()}.
end_location(Token) ->
  {Line, Column} = erl_scan:location(Token),
  {Line, Column + token_source_width(Token)}.

-spec token_source_width(Token) -> Result when
  Token :: erl_scan:token(),
  Result :: pos_integer().
token_source_width({atom, _Location, Value}) ->
  length(atom_to_list(Value));
token_source_width({var, _Location, Value}) ->
  length(atom_to_list(Value));
token_source_width({string, _Location, Value}) ->
  %% +2 for the surrounding double quotes.
  length(Value) + 2;
token_source_width({Symbol, _Location}) when is_atom(Symbol) ->
  length(atom_to_list(Symbol));
token_source_width(_OtherToken) ->
  1.

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

%% The module a Name/Arity call in Module actually resolves to, per
%% Module's own -import(ImportedModule, [Name/Arity, ...]) attribute -
%% e.g. a module with -import(lists, [reverse/1]) calling reverse(X)
%% resolves to lists, not Module itself or erlang. error if Module has no
%% matching import (the ordinary case for most Name/Arity calls, which
%% are either local or auto-imported BIFs).
-spec imported_module(Module, Function, Arity) -> Result when
  Module :: module(),
  Function :: atom(),
  Arity :: arity(),
  Result :: {ok, module()} | error.
imported_module(Module, Function, Arity) ->
  case ets:lookup(?IMPORTS_TABLE, {Module, Function, Arity}) of
    [{{Module, Function, Arity}, ImportedModule}] -> {ok, ImportedModule};
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

%% Function's -spec, pretty-printed back to source text (e.g.
%% "-spec reverse(list()) -> list()."). error if the function has none
%% (-spec is optional) or was never indexed.
-spec function_spec(Module, Function, Arity) -> Result when
  Module :: module(),
  Function :: atom(),
  Arity :: arity(),
  Result :: {ok, binary()} | error.
function_spec(Module, Function, Arity) ->
  case ets:lookup(?SPECS_TABLE, {Module, Function, Arity}) of
    [{{Module, Function, Arity}, SpecText}] -> {ok, SpecText};
    [] -> error
  end.

%% Function's doc text - its own -doc's value if present, the EDoc-style
%% "%%" comment block directly above it if not (see edoc_fallback/2), or
%% (as a last resort, for a module indexed before its source was on
%% erlsp's code path, or whose source isn't reachable at all) whatever
%% code:get_doc/1 can read straight out of the module's own compiled
%% "Docs" chunk (see beam_doc_chunk_function/3). error if none of these
%% have anything, or -doc false/hidden explicitly suppressed it.
-spec function_doc(Module, Function, Arity) -> Result when
  Module :: module(),
  Function :: atom(),
  Arity :: arity(),
  Result :: {ok, binary()} | error.
function_doc(Module, Function, Arity) ->
  case ets:lookup(?DOCS_TABLE, {Module, function, Function, Arity}) of
    [{{Module, function, Function, Arity}, DocText}] -> {ok, DocText};
    [] -> beam_doc_chunk_function(Module, Function, Arity)
  end.

%% Same as function_doc/3, for a -type/-opaque definition.
-spec type_doc(Module, Type, Arity) -> Result when
  Module :: module(),
  Type :: atom(),
  Arity :: arity(),
  Result :: {ok, binary()} | error.
type_doc(Module, Type, Arity) ->
  case ets:lookup(?DOCS_TABLE, {Module, type, Type, Arity}) of
    [{{Module, type, Type, Arity}, DocText}] -> {ok, DocText};
    [] -> beam_doc_chunk_type(Module, Type, Arity)
  end.

%% Module's own -moduledoc text. No EDoc fallback (see index_doc_value/2),
%% but code:get_doc/1 is still tried as a last resort - see function_doc/3.
-spec module_doc(Module) -> Result when
  Module :: module(),
  Result :: {ok, binary()} | error.
module_doc(Module) ->
  case ets:lookup(?DOCS_TABLE, {Module, module}) of
    [{{Module, module}, DocText}] -> {ok, DocText};
    [] -> beam_doc_chunk_module(Module)
  end.

%% code:get_doc/1's docs_v1 record (EEP 48) - {docs_v1, Anno, BeamLang,
%% Format, ModuleDoc, Metadata, Docs}, where Docs is a list of
%% {{Kind, Name, Arity}, Anno, Signature, DocMap, Metadata} entries. Only
%% the two fields used here are named; see EEP 48 for the rest.
-spec beam_doc_chunk_function(Module, Function, Arity) -> Result when
  Module :: module(),
  Function :: atom(),
  Arity :: arity(),
  Result :: {ok, binary()} | error.
beam_doc_chunk_function(Module, Function, Arity) ->
  beam_doc_chunk_entry_doc(Module, {function, Function, Arity}).

-spec beam_doc_chunk_type(Module, Type, Arity) -> Result when
  Module :: module(),
  Type :: atom(),
  Arity :: arity(),
  Result :: {ok, binary()} | error.
beam_doc_chunk_type(Module, Type, Arity) ->
  beam_doc_chunk_entry_doc(Module, {type, Type, Arity}).

-spec beam_doc_chunk_entry_doc(Module, EntryKey) -> Result when
  Module :: module(),
  EntryKey :: {function | type, atom(), arity()},
  Result :: {ok, binary()} | error.
beam_doc_chunk_entry_doc(Module, EntryKey) ->
  case code:get_doc(Module) of
    {ok, {docs_v1, _Anno, _BeamLang, _Format, _ModuleDoc, _Metadata, Docs}} ->
      case lists:keyfind(EntryKey, 1, Docs) of
        {EntryKey, _EntryAnno, _Signature, DocMap, _EntryMetadata} -> beam_doc_map_text(DocMap);
        false -> error
      end;
    {error, _Reason} ->
      error
  end.

-spec beam_doc_chunk_module(Module) -> Result when
  Module :: module(),
  Result :: {ok, binary()} | error.
beam_doc_chunk_module(Module) ->
  case code:get_doc(Module) of
    {ok, {docs_v1, _Anno, _BeamLang, _Format, ModuleDoc, _Metadata, _Docs}} ->
      beam_doc_map_text(ModuleDoc);
    {error, _Reason} ->
      error
  end.

%% A docs_v1 entry's doc field is #{<<"en">> => Text, ...} for a
%% documented entry, the atom 'none' for an undocumented one, or the atom
%% 'hidden' for one explicitly marked -doc false/hidden.
-spec beam_doc_map_text(DocMap) -> Result when
  DocMap :: #{binary() => binary()} | none | hidden,
  Result :: {ok, binary()} | error.
beam_doc_map_text(#{<<"en">> := Text}) -> {ok, Text};
beam_doc_map_text(_NoEnglishDoc) -> error.

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
    [{{Uri, Macro}, Uri, Line, _Text}] -> {ok, {Uri, Line}};
    [] -> error
  end.

%% Macro's exact source text as written, e.g. "-define(FOO, bar)" -
%% see macro_text/2 for exactly what's included/excluded. error both when
%% Macro isn't indexed at all, and when it is but its text couldn't be
%% recovered (macro_text/2 gave up - see macro_defines/1). Uri here is
%% the same "file the -define directly appears in" as macro_location/2,
%% not necessarily where the macro is used - see that function's own note.
-spec macro_definition_text(Uri, Macro) -> Result when
  Uri :: erlsp_documents:uri(),
  Macro :: atom(),
  Result :: {ok, binary()} | error.
macro_definition_text(Uri, Macro) ->
  case ets:lookup(?MACROS_TABLE, {Uri, Macro}) of
    [{{Uri, Macro}, Uri, _Line, undefined}] -> error;
    [{{Uri, Macro}, Uri, _Line, Text}] -> {ok, Text};
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
  [Name || {{_Uri, Name}, _DefUri, _Line, _Text}
   <- ets:match_object(?MACROS_TABLE, {{Uri, '_'}, '_', '_', '_'})].

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
