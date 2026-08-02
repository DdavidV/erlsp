-module(erlsp_jsonrpc).

-define(VSN, <<"2.0">>).

-export([
  reply/2,
  error/3,
  notification/2,
  frame/1,
  decode/1
]).

-spec reply(Id, Result) -> Message when
  Id :: jsx:json_term(),
  Result :: jsx:json_term(),
  Message :: iodata().
reply(Id, Result) ->
  frame(#{
    jsonrpc => ?VSN,
    id => Id,
    result => Result
  }).

-spec notification(Method, Params) -> Message when
  Method :: binary(),
  Params :: jsx:json_term(),
  Message :: iodata().
notification(Method, Params) ->
  frame(#{
    jsonrpc => ?VSN,
    method => Method,
    params => Params
  }).

-spec error(Id, Code, Msg) -> Message when
  Id :: jsx:json_term(),
  Code :: integer(),
  Msg :: binary(),
  Message :: iodata().
error(Id, Code, Msg) ->
  frame(#{
    jsonrpc => ?VSN,
    id => Id,
    error => #{
      code => Code,
      message => Msg
    }
  }).

-spec frame(Term) -> Message when
  Term :: jsx:json_term(),
  Message :: iodata().
frame(Term) ->
  Body = jsx:encode(Term),
  Header = io_lib:format("Content-Length: ~b\r\n\r\n", [iolist_size(Body)]),
  [Header, Body].

%% Recursively converts known JSON-RPC/LSP object keys from binaries to
%% atoms, leaving any key it doesn't recognize as a binary. Deliberately
%% does not use binary_to_atom/1,2: atoms are never garbage collected, so
%% converting arbitrary keys from client-controlled input would let a
%% malicious or buggy client exhaust the atom table.
-spec decode(Term) -> Result when
  Term :: jsx:json_term(),
  Result :: term().
decode(Map) when is_map(Map) ->
  maps:fold(
    fun(Key, Value, Acc) -> Acc#{decode_key(Key) => decode(Value)} end,
    #{},
    Map
  );
decode(List) when is_list(List) ->
  [decode(Item) || Item <- List];
decode(Term) ->
  Term.

-spec decode_key(Key) -> Result when
  Key :: binary(),
  Result :: atom() | binary().
decode_key(<<"jsonrpc">>) -> jsonrpc;
decode_key(<<"id">>) -> id;
decode_key(<<"method">>) -> method;
decode_key(<<"params">>) -> params;
decode_key(<<"result">>) -> result;
decode_key(<<"error">>) -> error;
decode_key(<<"code">>) -> code;
decode_key(<<"message">>) -> message;
decode_key(<<"textDocument">>) -> textDocument;
decode_key(<<"uri">>) -> uri;
decode_key(<<"text">>) -> text;
decode_key(<<"version">>) -> version;
decode_key(<<"languageId">>) -> languageId;
decode_key(<<"contentChanges">>) -> contentChanges;
decode_key(<<"range">>) -> range;
decode_key(<<"start">>) -> start;
decode_key(<<"end">>) -> 'end';
decode_key(<<"line">>) -> line;
decode_key(<<"character">>) -> character;
decode_key(<<"capabilities">>) -> capabilities;
decode_key(<<"processId">>) -> processId;
decode_key(<<"rootUri">>) -> rootUri;
decode_key(UnknownKey) -> UnknownKey.
