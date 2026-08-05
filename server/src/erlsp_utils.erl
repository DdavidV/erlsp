-module(erlsp_utils).

-export([
  uri_to_path/1,
  path_to_uri/1,
  module_attribute/1
]).

%% Converts a file:// LSP URI to a local filesystem path. Only the file
%% scheme is supported, since that is the only one LSP clients send for
%% textDocument URIs.
-spec uri_to_path(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: file:filename().
uri_to_path(Uri) ->
  #{path := Path} = uri_string:parse(Uri),
  binary_to_list(uri_string:percent_decode(Path)).

%% Converts a local filesystem path to a file:// LSP URI.
%% Percent-encodes anything outside the path component's  allowed character
%% set (e.g. spaces), but leaves "/" alone since it's the path separator,
%% not something to escape.
-spec path_to_uri(Path) -> Result when
  Path :: file:filename(),
  Result :: erlsp_documents:uri().
path_to_uri(Path) ->
  {path, AllowedChars} = lists:keyfind(path, 1, uri_string:allowed_characters()),
  QuotedPath = uri_string:quote(filename:absname(Path), AllowedChars),
  Uri = uri_string:recompose(#{scheme => <<"file">>, host => <<>>, path => QuotedPath}),
  unicode:characters_to_binary(Uri).

%% Reads Tokens' own -module(Name) attribute, wherever it appears. Shared
%% by erlsp_definition and erlsp_completion, which both need the same
%% "what module is this file" lookup.
-spec module_attribute(Tokens) -> Result when
  Tokens :: [erl_scan:token()],
  Result :: {ok, module()} | error.
module_attribute([{'-', _}, {atom, _, module}, {'(', _}, {atom, _, Module}, {')', _} | _Rest]) ->
  {ok, Module};
module_attribute([_Token | Rest]) ->
  module_attribute(Rest);
module_attribute([]) ->
  error.
