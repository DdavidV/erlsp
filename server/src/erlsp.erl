-module(erlsp).

-export([main/1]).

main(_Args) ->
  loop().

loop() ->
  case read_message() of
    eof ->
      ok;
    Message ->
      handle_message(Message),
      loop()
  end.

read_message() ->
  case read_headers(#{}) of
    eof -> eof;
    Headers ->
      Length = maps:get("content-length", Headers),
      case io:get_chars(standard_io, "", Length) of
        eof -> eof;
        Body -> jsx:decode(list_to_binary(Body), [return_maps])
      end
  end.

read_headers(Acc) ->
  case io:get_line(standard_io, "") of
    eof -> eof;
    "\r\n" -> Acc;
    "\n" -> Acc;
    Line ->
      case string:split(string:trim(Line), ":") of
        [Key, Value] ->
          NormKey = string:lowercase(string:trim(Key)),
          read_headers(Acc#{NormKey => list_to_integer(string:trim(Value))});
        _ ->
          read_headers(Acc)
      end
  end.

write_message(Term) ->
  Body = jsx:encode(Term),
  Header = io_lib:format("Content-Length: ~b\r\n\r\n", [iolist_size(Body)]),
  io:put_chars(standard_io, [Header, Body]).

handle_message(#{<<"method">> := <<"initialize">>, <<"id">> := Id}) ->
  write_message(#{
    <<"jsonrpc">> => <<"2.0">>,
    <<"id">> => Id,
    <<"result">> => #{<<"capabilities">> => #{}}
  });
handle_message(#{<<"method">> := <<"shutdown">>, <<"id">> := Id}) ->
  write_message(#{
    <<"jsonrpc">> => <<"2.0">>,
    <<"id">> => Id,
    <<"result">> => null
  });
handle_message(_Message) ->
  ok.
