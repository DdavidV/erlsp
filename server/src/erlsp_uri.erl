-module(erlsp_uri).

-export([
  to_path/1
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
