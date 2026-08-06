-module(erlsp_hover).

-type markup_content() :: #{kind := binary(), value := binary()}.

-export([
  hover/3
]).

%% Hover text for whatever's at Line/Character in Uri.
%% Renders the symbol's -spec and doc text (its own -doc,
%% an EDoc "%%" comment fallback, or a compiled module's own doc chunk)
%% as a single markdown block.
-spec hover(Uri, Line, Character) -> Result when
  Uri :: erlsp_documents:uri(),
  Line :: non_neg_integer(),
  Character :: non_neg_integer(),
  Result :: {ok, markup_content()} | error.
hover(Uri, Line, Character) ->
  maybe
    {ok, Symbol} ?= erlsp_definition:resolve(Uri, Line, Character),
    {ok, Markdown} ?= symbol_markdown(Symbol),
    {ok, #{kind => <<"markdown">>, value => Markdown}}
  else
    error -> error
  end.

-spec symbol_markdown(Symbol) -> Result when
  Symbol :: erlsp_definition:symbol(),
  Result :: {ok, binary()} | error.
symbol_markdown({function, Module, Name, Arity}) ->
  Spec = optional_section(erlsp_index:function_spec(Module, Name, Arity), <<"erlang">>),
  Doc = optional_section(erlsp_index:function_doc(Module, Name, Arity), undefined),
  sections_markdown([Spec, Doc]);
symbol_markdown({type, Module, Name, Arity}) ->
  Doc = optional_section(erlsp_index:type_doc(Module, Name, Arity), undefined),
  sections_markdown([Doc]);
symbol_markdown({record, _Module, _Name}) ->
  error;
symbol_markdown({macro, Uri, Name}) ->
  %% No -spec/-doc equivalent for macros - shows the macro's own
  %% -define(...) source text instead, exactly as written.
  sections_markdown([optional_section(macro_definition_text(Uri, Name), <<"erlang">>)]);
symbol_markdown({module, Module}) ->
  sections_markdown([optional_section(erlsp_index:module_doc(Module), undefined)]);
symbol_markdown({include, _Uri, _HeaderPath}) ->
  error.

-spec macro_definition_text(Uri, Name) -> Result when
  Uri :: erlsp_documents:uri(),
  Name :: atom(),
  Result :: {ok, binary()} | error.
macro_definition_text(Uri, Name) ->
  first_macro_definition_text([Uri | erlsp_index:included_uris(Uri)], Name).

-spec first_macro_definition_text(Uris, Name) -> Result when
  Uris :: [erlsp_documents:uri()],
  Name :: atom(),
  Result :: {ok, binary()} | error.
first_macro_definition_text([Uri | Rest], Name) ->
  case erlsp_index:macro_definition_text(Uri, Name) of
    {ok, Text} -> {ok, Text};
    error -> first_macro_definition_text(Rest, Name)
  end;
first_macro_definition_text([], _Name) ->
  error.

%% Wraps Text (if present) as a single fenced code block when Language is
%% given (used for -spec text, so it's rendered/highlighted like code),
%% or as-is when Language is undefined.
-spec optional_section(LookupResult, Language) -> Result when
  LookupResult :: {ok, binary()} | error,
  Language :: binary() | undefined,
  Result :: binary() | none.
optional_section({ok, Text}, undefined) ->
  Text;
optional_section({ok, Text}, Language) ->
  <<"```", Language/binary, "\n", Text/binary, "\n```">>;
optional_section(error, _Language) ->
  none.

-spec sections_markdown(Sections) -> Result when
  Sections :: [binary() | none],
  Result :: {ok, binary()} | error.
sections_markdown(Sections) ->
  case [Section || Section <- Sections, Section =/= none] of
    [] ->
      error;
    NonEmptySections ->
      {ok, unicode:characters_to_binary(lists:join(<<"\n\n---\n\n">>, NonEmptySections))}
  end.
