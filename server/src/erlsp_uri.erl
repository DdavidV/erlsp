-module(erlsp_uri).

-export([
  to_path/1,
  from_path/1
]).

%% Converts a file:// LSP URI to a local filesystem path. Only the file
%% scheme is supported, since that is the only one LSP clients send for
%% textDocument URIs.
-spec to_path(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: file:filename().
to_path(Uri) ->
  #{path := Path} = uri_string:parse(Uri),
  binary_to_list(uri_string:percent_decode(Path)).

%% Converts a local filesystem path to a file:// LSP URI.
%% Percent-encodes anything outside the path component's  allowed character
%% set (e.g. spaces), but leaves "/" alone since it's the path separator,
%% not something to escape.
-spec from_path(Path) -> Result when
  Path :: file:filename(),
  Result :: erlsp_documents:uri().
from_path(Path) ->
  {path, AllowedChars} = lists:keyfind(path, 1, uri_string:allowed_characters()),
  QuotedPath = uri_string:quote(filename:absname(Path), AllowedChars),
  Uri = uri_string:recompose(#{scheme => <<"file">>, host => <<>>, path => QuotedPath}),
  unicode:characters_to_binary(Uri).
