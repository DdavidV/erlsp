-module(erlsp_jsonrpc).

-define(VSN, <<"2.0">>).

-export([
  reply/2,
  error/3,
  frame/1
]).

-spec reply(Id, Result) -> Message when
  Id :: jsx:json_term(),
  Result :: jsx:json_term(),
  Message :: iodata().
reply(Id, Result) ->
  frame(#{
    <<"jsonrpc">> => ?VSN,
    <<"id">> => Id,
    <<"result">> => Result
  }).

-spec error(Id, Code, Msg) -> Message when
  Id :: jsx:json_term(),
  Code :: integer(),
  Msg :: binary(),
  Message :: iodata().
error(Id, Code, Msg) ->
  frame(#{
    <<"jsonrpc">> => ?VSN,
    <<"id">> => Id,
    <<"error">> => #{
      <<"code">> => Code,
      <<"message">> => Msg
    }
  }).

-spec frame(Term) -> Message when
  Term :: jsx:json_term(),
  Message :: iodata().
frame(Term) ->
  Body = jsx:encode(Term),
  Header = io_lib:format("Content-Length: ~b\r\n\r\n", [iolist_size(Body)]),
  [Header, Body].
