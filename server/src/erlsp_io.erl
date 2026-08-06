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
  %% LSP's Content-Length header counts UTF-8 bytes, not characters, so
  %% standard_io must read/write raw bytes (latin1) rather than OTP's
  %% default unicode mode - otherwise a body containing any non-ASCII
  %% character desyncs io:get_chars/3's Length from the actual byte count,
  %% corrupting this message and every one after it.
  ok = io:setopts(standard_io, [{encoding, latin1}]),
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
        Body -> erlsp_jsonrpc:decode(jsx:decode(unicode:characters_to_binary(Body, latin1, utf8)))
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
  %% Flattened to a single binary and written via "~s", rather than
  %% io:put_chars(standard_io, Message) directly on Message as-is: Message
  %% is a mixed iolist.
  %% put_chars on that mix, even with standard_io in latin1 mode,
  %% was found to mangle the binary part - each byte of any UTF-8 multi-byte sequence
  %% in Body got reinterpreted as its  own Unicode codepoint and re-encoded,
  %% producing fewer bytes than the already-computed Content-Length promised -
  %% desyncing every message  after it and corrupting the whole session.
  %% Flattening to one binary first and writing via ~s avoids that
  %% mixed-iolist path entirely.
  ok = io:format(standard_io, "~s", [iolist_to_binary(Message)]).
