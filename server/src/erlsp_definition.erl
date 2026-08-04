-module(erlsp_definition).

-export([
  locate/3
]).

%% Finds the definition of whatever's at Line/Character in Uri, by
%% tokenizing the file and reading the identifier under the cursor.
%% Resolves function calls (Mod:Fun(...) or bare Fun(...)), type
%% references (Type(...) in a -spec/-type), macros (?MACRO), records
%% (#record{...} or #record.field), -include/-include_lib header paths,
%% and Name/Arity entries in -export(...)/-export_type(...) lists.
-spec locate(Uri, Line, Character) -> Result when
  Uri :: erlsp_documents:uri(),
  Line :: non_neg_integer(),
  Character :: non_neg_integer(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
locate(Uri, Line, Character) ->
  case file_text(Uri) of
    {ok, Text} ->
      %% erl_scan locations are 1-indexed, LSP positions are 0-indexed.
      case erl_scan:string(unicode:characters_to_list(Text), {1, 1}) of
        {ok, Tokens, _EndLocation} ->
          locate_in_tokens(Tokens, Uri, Line + 1, Character + 1);
        {error, _ErrorInfo, _EndLocation} ->
          error
      end;
    error ->
      error
  end.

-spec file_text(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: {ok, unicode:chardata()} | error.
file_text(Uri) ->
  case erlsp_documents:get_text(Uri) of
    {ok, Text} ->
      {ok, Text};
    error ->
      case file:read_file(erlsp_uri:to_path(Uri)) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _Reason} -> error
      end
  end.

-spec locate_in_tokens(Tokens, Uri, Line, Column) -> Result when
  Tokens :: [erl_scan:token()],
  Uri :: erlsp_documents:uri(),
  Line :: non_neg_integer(),
  Column :: non_neg_integer(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
locate_in_tokens(Tokens, Uri, Line, Column) ->
  case token_at(Tokens, Line, Column, []) of
    {ok, Before, After} ->
      resolve_call(Tokens, Before, After, Uri);
    error ->
      error
  end.

%% Splits Tokens around the one under the cursor: Before is everything
%% preceding it in reverse order (nearest first), After has it as its
%% head. The reversed order lets resolve_call/preceded_by_module_colon
%% check "what's immediately before the cursor" with simple head matches.
-spec token_at(Tokens, Line, Column, ReverseBefore) -> Result when
  Tokens :: [erl_scan:token()],
  Line :: non_neg_integer(),
  Column :: non_neg_integer(),
  ReverseBefore :: [erl_scan:token()],
  Result :: {ok, [erl_scan:token()], [erl_scan:token()]} | error.
token_at([Token | Rest], Line, Column, ReverseBefore) ->
  {TokenLine, TokenColumn} = erl_scan:location(Token),
  case TokenLine =:= Line andalso token_covers(Token, TokenColumn, Column) of
    true -> {ok, ReverseBefore, [Token | Rest]};
    false -> token_at(Rest, Line, Column, [Token | ReverseBefore])
  end;
token_at([], _Line, _Column, _ReverseBefore) ->
  error.

-spec token_covers(Token, TokenColumn, Column) -> Result when
  Token :: erl_scan:token(),
  TokenColumn :: non_neg_integer(),
  Column :: non_neg_integer(),
  Result :: boolean().
token_covers(Token, TokenColumn, Column) ->
  Width = token_width(Token),
  Column >= TokenColumn andalso Column < TokenColumn + Width.

-spec token_width(Token) -> Result when
  Token :: erl_scan:token(),
  Result :: pos_integer().
token_width({atom, _Location, Value}) ->
  length(atom_to_list(Value));
token_width({var, _Location, Value}) ->
  length(atom_to_list(Value));
token_width({string, _Location, Value}) ->
  %% +2 for the surrounding double quotes, which erl_scan's location
  %% doesn't include in Value but does include in the source column span.
  length(Value) + 2;
token_width(_OtherToken) ->
  1.

%% AllTokens is the whole file's token stream.
%% ReverseBefore is the tokens immediately preceding the cursor, nearest
%% first - just enough to tell whether the cursor's atom is the Mod or
%% Fun half of a Mod:Fun(...) call, or a bare call.
%% After's head is the atom token under the cursor.
-spec resolve_call(AllTokens, ReverseBefore, After, Uri) -> Result when
  AllTokens :: [erl_scan:token()],
  ReverseBefore :: [erl_scan:token()],
  After :: [erl_scan:token()],
  Uri :: erlsp_documents:uri(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_call(_AllTokens, _ReverseBefore,
             [{atom, _, Module}, {':', _}, {atom, _, Function}, {'(', _} | Rest], _Uri) ->
  %% Cursor on the Mod part of Mod:Fun(...) or Mod:Type(...) - same
  %% syntax for a remote call and a remote type reference.
  resolve_remote_function_or_type(Module, Function, count_arity(Rest));
resolve_call(_AllTokens, [{':', _}, {atom, _, Module} | _EarlierTokens],
             [{atom, _, Function}, {'(', _} | Rest], _Uri) ->
  %% Cursor on the Fun/Type part of Mod:Fun(...) - same call, resolved
  %% from that side instead of the Mod side.
  resolve_remote_function_or_type(Module, Function, count_arity(Rest));
resolve_call(AllTokens, _ReverseBefore, [{'?', _}, NameToken | _Rest], Uri) ->
  %% Cursor on the '?' of ?MACRO or ?MACRO(...).
  resolve_macro(AllTokens, Uri, macro_name(NameToken));
resolve_call(AllTokens, [{'?', _} | _EarlierTokens], [NameToken | _Rest], Uri)
    when element(1, NameToken) =:= var; element(1, NameToken) =:= atom ->
  %% Cursor on the NAME part of ?NAME or ?NAME(...).
  resolve_macro(AllTokens, Uri, macro_name(NameToken));
resolve_call(AllTokens, _ReverseBefore, [{'#', _}, {atom, _, Record}, Next | _Rest], Uri)
    when element(1, Next) =:= '{'; element(1, Next) =:= '.' ->
  %% Cursor on the '#' of #record{...} (construction/update) or
  %% #record.field (field access).
  resolve_record(AllTokens, Uri, Record);
resolve_call(AllTokens, [{'#', _} | _EarlierTokens], [{atom, _, Record}, Next | _Rest], Uri)
    when element(1, Next) =:= '{'; element(1, Next) =:= '.' ->
  %% Cursor on the name part of #record{...} or #record.field.
  resolve_record(AllTokens, Uri, Record);
resolve_call(_AllTokens, [{'-', _} | _EarlierTokens],
             [{atom, _, Attribute}, {'(', _}, {string, _, HeaderPath}, {')', _} | _Rest], Uri)
    when Attribute =:= include; Attribute =:= include_lib ->
  %% Cursor on 'include'/'include_lib' itself, e.g. -include("erlsp.hrl").
  resolve_include(Uri, HeaderPath);
resolve_call(_AllTokens, [{'(', _}, {atom, _, Attribute}, {'-', _} | _EarlierTokens],
             [{string, _, HeaderPath}, {')', _} | _Rest], Uri)
    when Attribute =:= include; Attribute =:= include_lib ->
  %% Cursor on the header path string itself.
  resolve_include(Uri, HeaderPath);
resolve_call(_AllTokens, [{'fun', _} | _EarlierTokens],
             [{atom, _, Module}, {':', _}, {atom, _, Function}, {'/', _}, {integer, _, Arity} | _Rest], _Uri) ->
  %% Cursor on the Mod part of fun Mod:Fun/Arity.
  resolve_remote_function_or_type(Module, Function, Arity);
resolve_call(_AllTokens, [{':', _}, {atom, _, Module}, {'fun', _} | _EarlierTokens],
             [{atom, _, Function}, {'/', _}, {integer, _, Arity} | _Rest], _Uri) ->
  %% Cursor on the Fun part of fun Mod:Fun/Arity.
  resolve_remote_function_or_type(Module, Function, Arity);
resolve_call(AllTokens, [{'fun', _} | _EarlierTokens],
             [{atom, _, Name}, {'/', _}, {integer, _, Arity} | _Rest], Uri) ->
  %% Cursor on Name in a bare fun Name/Arity reference (local function).
  resolve_local_bif_or_type(AllTokens, Uri, Name, Arity);
resolve_call(AllTokens, ReverseBefore, [{atom, _, Name}, {'/', _}, {integer, _, Arity} | _Rest], _Uri) ->
  %% Cursor on Name in a Name/Arity entry, e.g. inside -export([...]) or
  %% -export_type([...]) - only meaningful within one of those attribute
  %% lists, so ReverseBefore is checked for which one encloses it.
  case enclosing_export_attribute(ReverseBefore) of
    {ok, export} -> resolve_own_function(AllTokens, Name, Arity);
    {ok, export_type} -> resolve_own_type(AllTokens, Name, Arity);
    error -> error
  end;
resolve_call(AllTokens, _ReverseBefore, [{atom, _, Function}, {'(', _} | Rest], Uri) ->
  %% Bare Fun(...): local call, auto-imported BIF, or a type reference
  %% (types and calls are syntactically identical at this point).
  resolve_local_bif_or_type(AllTokens, Uri, Function, count_arity(Rest));
resolve_call(_AllTokens, _ReverseBefore, _After, _Uri) ->
  error.

%% -include/-include_lib's HeaderPath is a relative path (e.g. "erlsp.hrl"
%% or "kernel/include/logger.hrl") - resolved by matching its basename
%% against Uri's already-resolved included headers, rather than re-deriving
%% include/app search paths here, which would risk disagreeing with what actually
%% got included.
-spec resolve_include(Uri, HeaderPath) -> Result when
  Uri :: erlsp_documents:uri(),
  HeaderPath :: string(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_include(Uri, HeaderPath) ->
  Basename = unicode:characters_to_binary(filename:basename(HeaderPath)),
  case lists:filter(fun(Included) -> ends_with(Included, Basename) end, erlsp_index:included_uris(Uri)) of
    [HeaderUri | _OtherMatches] -> {ok, {HeaderUri, 1}};
    [] -> error
  end.

-spec ends_with(Subject, Suffix) -> Result when
  Subject :: binary(),
  Suffix :: binary(),
  Result :: boolean().
ends_with(Subject, Suffix) ->
  SuffixSize = byte_size(Suffix),
  SubjectSize = byte_size(Subject),
  SubjectSize >= SuffixSize andalso
    binary:part(Subject, SubjectSize - SuffixSize, SuffixSize) =:= Suffix.

%% ReverseBefore is the tokens preceding a Name/Arity entry, nearest
%% first. Skips backward over any earlier Name/Arity entries and their
%% separating commas to find the list's opening '[' and, past that,
%% whether it belongs to -export(...) or -export_type(...).
-spec enclosing_export_attribute(ReverseBefore) -> Result when
  ReverseBefore :: [erl_scan:token()],
  Result :: {ok, export | export_type} | error.
enclosing_export_attribute([{'[', _}, {'(', _}, {atom, _, Attribute}, {'-', _} | _EarlierTokens])
    when Attribute =:= export; Attribute =:= export_type ->
  {ok, Attribute};
enclosing_export_attribute([{',', _}, {integer, _, _Arity}, {'/', _}, {atom, _, _Name} | Rest]) ->
  enclosing_export_attribute(Rest);
enclosing_export_attribute(_ReverseBefore) ->
  error.

%% -export([Name/Arity, ...]) only ever lists functions defined in the
%% file's own module.
-spec resolve_own_function(Tokens, Name, Arity) -> Result when
  Tokens :: [erl_scan:token()],
  Name :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_own_function(Tokens, Name, Arity) ->
  case erlsp_tokens:module_attribute(Tokens) of
    {ok, Module} -> erlsp_index:function_location(Module, Name, Arity);
    error -> error
  end.

%% -export_type([Name/Arity, ...]) only ever lists types defined in the
%% file's own module.
-spec resolve_own_type(Tokens, Name, Arity) -> Result when
  Tokens :: [erl_scan:token()],
  Name :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_own_type(Tokens, Name, Arity) ->
  case erlsp_tokens:module_attribute(Tokens) of
    {ok, Module} -> erlsp_index:type_location(Module, Name, Arity);
    error -> error
  end.

-spec macro_name(Token) -> Result when
  Token :: erl_scan:token(),
  Result :: atom().
macro_name({var, _Location, Name}) -> Name;
macro_name({atom, _Location, Name}) -> Name.

%% Counts a call's arity given the tokens right after its opening '(': 0
%% if ')' immediately follows (an empty argument list), otherwise the
%% number of top-level commas plus one. Nested brackets ((), [], {}) are
%% tracked by depth so their commas aren't mistaken for argument
%% separators. Depth starts at 1 for the '(' Tokens is already past.
-spec count_arity(Tokens) -> Result when
  Tokens :: [erl_scan:token()],
  Result :: arity().
count_arity([{')', _} | _Rest]) ->
  0;
count_arity(Tokens) ->
  count_arity(Tokens, 1, 0).

-spec count_arity(Tokens, Depth, CommaCount) -> Result when
  Tokens :: [erl_scan:token()],
  Depth :: non_neg_integer(),
  CommaCount :: non_neg_integer(),
  Result :: arity().
count_arity([{'(', _} | Rest], Depth, Commas) ->
  count_arity(Rest, Depth + 1, Commas);
count_arity([Open | Rest], Depth, Commas) when element(1, Open) =:= '['; element(1, Open) =:= '{' ->
  count_arity(Rest, Depth + 1, Commas);
count_arity([{')', _} | Rest], Depth, Commas) when Depth > 1 ->
  count_arity(Rest, Depth - 1, Commas);
count_arity([{')', _} | _Rest], 1, Commas) ->
  Commas + 1;
count_arity([Close | Rest], Depth, Commas) when element(1, Close) =:= ']'; element(1, Close) =:= '}' ->
  count_arity(Rest, Depth - 1, Commas);
count_arity([{',', _} | Rest], Depth, Commas) when Depth =:= 1 ->
  count_arity(Rest, Depth, Commas + 1);
count_arity([_Token | Rest], Depth, Commas) ->
  count_arity(Rest, Depth, Commas);
count_arity([], _Depth, Commas) ->
  %% Unbalanced/truncated input: best-effort arity from what was seen.
  Commas + 1.

%% Mod:Name(...) is either a remote call or a remote type reference
%% (e.g. erlsp_documents:uri()) - syntactically identical, so functions
%% are tried first (the more common case) with types as a fallback.
-spec resolve_remote_function_or_type(Module, Name, Arity) -> Result when
  Module :: module(),
  Name :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_remote_function_or_type(Module, Name, Arity) ->
  case erlsp_index:function_location(Module, Name, Arity) of
    {ok, Location} -> {ok, Location};
    error -> erlsp_index:type_location(Module, Name, Arity)
  end.

%% A bare Name(...) could be a call to a function defined in Uri's own
%% module, a reference to a type defined in Uri's own module, an
%% auto-imported BIF (e.g. length/1, is_list/1), or a predefined type
%% (e.g. non_neg_integer/0, timeout/0) - the latter two both live in the
%% erlang module. All four are syntactically identical at this point.
%% Functions are tried before types at each scope, since that's the more
%% common case; the local module is tried before erlang, since a local
%% definition shadows a same-named BIF/predefined type.
-spec resolve_local_bif_or_type(Tokens, Uri, Name, Arity) -> Result when
  Tokens :: [erl_scan:token()],
  Uri :: erlsp_documents:uri(),
  Name :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_local_bif_or_type(Tokens, _Uri, Name, Arity) ->
  case erlsp_tokens:module_attribute(Tokens) of
    {ok, Module} ->
      case erlsp_index:function_location(Module, Name, Arity) of
        {ok, Location} -> {ok, Location};
        error -> resolve_local_type_or_erlang(Module, Name, Arity)
      end;
    error ->
      resolve_erlang_function_or_type(Name, Arity)
  end.

-spec resolve_local_type_or_erlang(Module, Name, Arity) -> Result when
  Module :: module(),
  Name :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_local_type_or_erlang(Module, Name, Arity) ->
  case erlsp_index:type_location(Module, Name, Arity) of
    {ok, Location} -> {ok, Location};
    error -> resolve_erlang_function_or_type(Name, Arity)
  end.

%% erlang is both where auto-imported BIFs (length/1, is_list/1, ...) and
%% predefined types (non_neg_integer/0, timeout/0, ...) live.
-spec resolve_erlang_function_or_type(Name, Arity) -> Result when
  Name :: atom(),
  Arity :: arity(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_erlang_function_or_type(Name, Arity) ->
  case erlsp_index:function_location(erlang, Name, Arity) of
    {ok, Location} -> {ok, Location};
    error -> erlsp_index:type_location(erlang, Name, Arity)
  end.

%% ?MACRO or ?MACRO(...): could be defined directly in Uri, or in any
%% header Uri includes (see erlsp_index:included_uris/1) - checked in
%% that order since a file's own -define shadows one of the same name
%% from an include.
-spec resolve_macro(Tokens, Uri, Macro) -> Result when
  Tokens :: [erl_scan:token()],
  Uri :: erlsp_documents:uri(),
  Macro :: atom(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_macro(_Tokens, Uri, Macro) ->
  Candidates = [Uri | erlsp_index:included_uris(Uri)],
  first_macro_location(Candidates, Macro).

-spec first_macro_location(Uris, Macro) -> Result when
  Uris :: [erlsp_documents:uri()],
  Macro :: atom(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
first_macro_location([Uri | Rest], Macro) ->
  case erlsp_index:macro_location(Uri, Macro) of
    {ok, Location} -> {ok, Location};
    error -> first_macro_location(Rest, Macro)
  end;
first_macro_location([], _Macro) ->
  error.

%% #record{...}: resolved against Uri's own module, matching how records
%% are indexed (see erlsp_index:index_forms/2).
-spec resolve_record(Tokens, Uri, Record) -> Result when
  Tokens :: [erl_scan:token()],
  Uri :: erlsp_documents:uri(),
  Record :: atom(),
  Result :: {ok, {erlsp_documents:uri(), non_neg_integer()}} | error.
resolve_record(Tokens, _Uri, Record) ->
  case erlsp_tokens:module_attribute(Tokens) of
    {ok, Module} -> erlsp_index:record_location(Module, Record);
    error -> error
  end.
