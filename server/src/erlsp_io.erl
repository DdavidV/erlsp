-module(erlsp_io).

-include("erlsp.hrl").

-export([
  start_link/0,
  loop/0,
  send/1
]).

-spec start_link() -> Result when
  Result :: {ok, pid()}.
start_link() ->
  Pid = spawn_link(?MODULE, loop, []),
  {ok, Pid}.

-spec loop() -> Result when
  Result :: ok.
loop() ->
  case read_message() of
    eof ->
      gen_server:cast(?ERLSP_SERVER, io_closed);
    Message ->
      gen_server:cast(?ERLSP_SERVER, {message, Message}),
      loop()
  end.

-spec read_message() -> Result when
  Result :: jsx:json_term() | eof.
read_message() ->
  case read_headers(#{}) of
    eof -> eof;
    Headers ->
      Length = list_to_integer(maps:get("content-length", Headers)),
      case io:get_chars(standard_io, "", Length) of
        eof -> eof;
        Body -> erlsp_jsonrpc:decode(jsx:decode(list_to_binary(Body)))
      end
  end.

-spec read_headers(Acc) -> Result when
  Acc :: #{string() => string()},
  Result :: #{string() => string()} | eof.
read_headers(Acc) ->
  case io:get_line(standard_io, "") of
    eof -> eof;
    "\r\n" -> Acc;
    "\n" -> Acc;
    Line ->
      case string:split(string:trim(Line), ":") of
        [Key, Value] ->
          NormKey = string:lowercase(string:trim(Key)),
          read_headers(Acc#{NormKey => string:trim(Value)});
        _ ->
          read_headers(Acc)
      end
  end.

-spec send(Message) -> Result when
  Message :: iodata(),
  Result :: ok.
send(Message) ->
  io:put_chars(standard_io, Message).
