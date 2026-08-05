-module(erlsp_completion).

-include("erlsp.hrl").

-type item() :: #{
  label := binary(),
  kind := non_neg_integer(),
  insertText => binary(),
  insertTextFormat => non_neg_integer(),
  command => #{title := binary(), command := binary()}
}.

-export([
  complete/3
]).

%% Finds completion candidates for whatever's being typed at Line/Character
%% in Uri, by tokenizing only the text up to the cursor and classifying
%% the last couple of tokens the same way.
%% Returns every candidate in scope for that context, filtering by what's already been
%% typed is left to the client.
-spec complete(Uri, Line, Character) -> Result when
  Uri :: erlsp_documents:uri(),
  Line :: non_neg_integer(),
  Character :: non_neg_integer(),
  Result :: [item()].
complete(Uri, Line, Character) ->
  case file_text(Uri) of
    {ok, Text} ->
      Prefix = text_before_cursor(Text, Line, Character),
      case erl_scan:string(unicode:characters_to_list(Prefix), {1, 1}) of
        {ok, Tokens, _EndLocation} ->
          resolve_context(lists:reverse(Tokens), Uri);
        {error, _ErrorInfo, _EndLocation} ->
          []
      end;
    error ->
      []
  end.

-spec file_text(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: {ok, unicode:chardata()} | error.
file_text(Uri) ->
  case erlsp_documents:get_text(Uri) of
    {ok, Text} ->
      {ok, Text};
    error ->
      case file:read_file(erlsp_utils:uri_to_path(Uri)) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _Reason} -> error
      end
  end.

%% Everything in Text up to (not including) Line/Character - erl_scan is
%% run only against this slice, so whatever's mid-typed at the cursor
%% naturally ends up as the last (possibly partial) token instead of
%% needing special-casing.
%% Character is a count of Unicode characters into the line,
%% it must not be treated as a byte offset, since binary:part/3 on a
%% UTF-8 binary can slice mid-character and produce an invalid fragment.
-spec text_before_cursor(Text, Line, Character) -> Result when
  Text :: unicode:chardata(),
  Line :: non_neg_integer(),
  Character :: non_neg_integer(),
  Result :: unicode:chardata().
text_before_cursor(Text, Line, Character) ->
  Lines = string:split(unicode:characters_to_binary(Text), <<"\n">>, all),
  {PriorLines, CursorLineAndRest} = lists:split(min(Line, length(Lines)), Lines),
  CursorLinePrefix = case CursorLineAndRest of
    [CursorLine | _Rest] -> characters_prefix(CursorLine, Character);
    [] -> <<>>
  end,
  unicode:characters_to_binary(lists:join(<<"\n">>, PriorLines ++ [CursorLinePrefix])).

-spec characters_prefix(Line, Count) -> Result when
  Line :: unicode:unicode_binary(),
  Count :: non_neg_integer(),
  Result :: unicode:unicode_binary().
characters_prefix(Line, Count) ->
  Characters = unicode:characters_to_list(Line),
  Prefix = lists:sublist(Characters, Count),
  unicode:characters_to_binary(Prefix).

%% ReverseTokens is every token up to the cursor, nearest-first
%% its head is either the partial identifier being typed, or the trigger
%% punctuation itself if nothing's been typed after it yet.
-spec resolve_context(ReverseTokens, Uri) -> Result when
  ReverseTokens :: [erl_scan:token()],
  Uri :: erlsp_documents:uri(),
  Result :: [item()].
resolve_context([{atom, PartialLoc, _Partial}, {':', ColonLoc}, {atom, _, Module} | _Rest], _Uri)
    when element(1, PartialLoc) =:= element(1, ColonLoc) ->
  %% Mod:<partial> - the same-line check rules out an unrelated earlier
  %% ':' from a previous, syntactically distinct statement matching by
  %% pure token shape (e.g. mid-edit code where a stray "Mod:" precedes
  %% an unrelated bare identifier on the next line).
  remote_items(Module);
resolve_context([{':', _}, {atom, _, Module} | _Rest], _Uri) ->
  %% Mod: with nothing typed yet after the colon - cursor is the token
  %% immediately after ':' by construction, so no adjacency check needed.
  remote_items(Module);
resolve_context([NameToken, {'?', QuestionLoc} | _Rest], Uri)
    when element(1, NameToken) =:= var; element(1, NameToken) =:= atom ->
  %% ?<partial>, same-line-adjacent to its '?'.
  {_TokenKind, NameLoc, _Name} = NameToken,
  case element(1, NameLoc) =:= element(1, QuestionLoc) of
    true -> macro_items(Uri);
    false -> []
  end;
resolve_context([{'?', _} | _Rest], Uri) ->
  %% ? with nothing typed yet.
  macro_items(Uri);
resolve_context([{atom, PartialLoc, _Partial}, {'#', HashLoc} | _Rest] = ReverseTokens, _Uri)
    when element(1, PartialLoc) =:= element(1, HashLoc) ->
  %% #<partial>, same-line-adjacent to its '#'.
  record_items(module_of(ReverseTokens));
resolve_context([{'#', _} | _Rest] = ReverseTokens, _Uri) ->
  %% # with nothing typed yet.
  record_items(module_of(ReverseTokens));
resolve_context([{atom, _, _Partial} | _Rest] = ReverseTokens, _Uri) ->
  %% Bare <partial>: local module functions plus erlang BIFs.
  local_items(module_of(ReverseTokens));
resolve_context(_ReverseTokens, _Uri) ->
  [].

-spec module_of(ReverseTokens) -> Result when
  ReverseTokens :: [erl_scan:token()],
  Result :: module() | undefined.
module_of(ReverseTokens) ->
  case erlsp_utils:module_attribute(lists:reverse(ReverseTokens)) of
    {ok, Module} -> Module;
    error -> undefined
  end.

-spec remote_items(Module) -> Result when
  Module :: module(),
  Result :: [item()].
remote_items(Module) ->
  function_items(Module, erlsp_index:functions_in_module(Module)) ++
    type_items(erlsp_index:types_in_module(Module)).

%% A bare identifier could become a local/BIF call (Name(...)) or the
%% start of a module name meant to be followed by ":" (Mod:Fun(...)) -
%% both are offered together, since which one the user meant isn't known
%% until they type further.
-spec local_items(Module) -> Result when
  Module :: module() | undefined,
  Result :: [item()].
local_items(undefined) ->
  function_items(erlang, erlsp_index:functions_in_module(erlang)) ++ module_items();
local_items(Module) ->
  function_items(Module, erlsp_index:functions_in_module(Module)) ++
  function_items(erlang, erlsp_index:functions_in_module(erlang)) ++
  module_items().

%% Inserts "Module:" and immediately re-triggers suggestions (via VS
%% Code's built-in editor.action.triggerSuggest command), so choosing a
%% module flows straight into completing a function on it instead of
%% leaving the user to type ":" themselves.
-spec module_items() -> Result when
  Result :: [item()].
module_items() ->
  [
    #{
      label => atom_to_binary(Module, utf8),
      kind => ?COMPLETION_ITEM_KIND_MODULE,
      insertText => <<(atom_to_binary(Module, utf8))/binary, ":">>,
      command => #{title => <<"Suggest">>, command => <<"editor.action.triggerSuggest">>}
    }
  || Module <- erlsp_index:all_modules()
  ].

-spec macro_items(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: [item()].
macro_items(Uri) ->
  Uris = [Uri | erlsp_index:included_uris(Uri)],
  Names = lists:usort(lists:append([erlsp_index:macros_in_uri(U) || U <- Uris])),
  [#{label => atom_to_binary(Name, utf8), kind => ?COMPLETION_ITEM_KIND_CONSTANT} || Name <- Names].

-spec record_items(Module) -> Result when
  Module :: module() | undefined,
  Result :: [item()].
record_items(undefined) ->
  [];
record_items(Module) ->
  Names = erlsp_index:records_in_module(Module),
  [#{label => atom_to_binary(Name, utf8), kind => ?COMPLETION_ITEM_KIND_STRUCT} || Name <- Names].

%% Inserts a snippet with the function's real parameter names as
%% tab-stops (e.g. "main(${1:Args})" for main(_Args)/1), so pressing Tab
%% after inserting steps through each argument instead of leaving the
%% user to type the parens and args from scratch. Falls back to a bare
%% Name(...) with no parameter placeholders if arity is 0 or the
%% parameter names couldn't be found (shouldn't normally happen, since
%% NamesAndArities came from the same index).
-spec function_items(Module, NamesAndArities) -> Result when
  Module :: module(),
  NamesAndArities :: [{atom(), arity()}],
  Result :: [item()].
function_items(Module, NamesAndArities) ->
  [function_item(Module, Name, Arity) || {Name, Arity} <- NamesAndArities].

-spec function_item(Module, Name, Arity) -> Result when
  Module :: module(),
  Name :: atom(),
  Arity :: arity(),
  Result :: item().
function_item(Module, Name, Arity) ->
  #{
    label => label(Name, Arity),
    kind => ?COMPLETION_ITEM_KIND_FUNCTION,
    insertText => function_snippet(Module, Name, Arity),
    insertTextFormat => ?INSERT_TEXT_FORMAT_SNIPPET
  }.

-spec function_snippet(Module, Name, Arity) -> Result when
  Module :: module(),
  Name :: atom(),
  Arity :: arity(),
  Result :: binary().
function_snippet(_Module, Name, 0) ->
  <<(atom_to_binary(Name, utf8))/binary, "()">>;
function_snippet(Module, Name, Arity) ->
  case erlsp_index:function_param_names(Module, Name, Arity) of
    {ok, ParamNames} ->
      Placeholders = [
        unicode:characters_to_binary(io_lib:format("${~b:~s}", [Index, ParamName]))
      || {ParamName, Index} <- lists:zip(ParamNames, lists:seq(1, Arity))
      ],
      Args = lists:join(<<", ">>, Placeholders),
      unicode:characters_to_binary([atom_to_binary(Name, utf8), "(", Args, ")"]);
    error ->
      %% Not expected (NamesAndArities always comes from the same index
      %% as function_param_names/3), but harmless to fall back on.
      <<(atom_to_binary(Name, utf8))/binary, "()">>
  end.

-spec type_items(NamesAndArities) -> Result when
  NamesAndArities :: [{atom(), arity()}],
  Result :: [item()].
type_items(NamesAndArities) ->
  [
    #{
      label => label(Name, Arity),
      kind => ?COMPLETION_ITEM_KIND_CLASS,
      insertText => atom_to_binary(Name, utf8)
    }
  || {Name, Arity} <- NamesAndArities
  ].

-spec label(Name, Arity) -> Result when
  Name :: atom(),
  Arity :: arity(),
  Result :: binary().
label(Name, Arity) ->
  unicode:characters_to_binary(io_lib:format("~s/~b", [Name, Arity])).
