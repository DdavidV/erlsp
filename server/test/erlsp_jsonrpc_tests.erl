-module(erlsp_jsonrpc_tests).

-include_lib("eunit/include/eunit.hrl").

reply_frames_a_result_test_() ->
  Message = iolist_to_binary(erlsp_jsonrpc:reply(1, #{ok => true})),
  {Header, Body} = split_frame(Message),
  Decoded = jsx:decode(Body),
  [
    ?_assertMatch(<<"Content-Length: ", _/binary>>, Header),
    ?_assertEqual(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1, <<"result">> => #{<<"ok">> => true}}, Decoded)
  ].

notification_has_no_id_test() ->
  Message = iolist_to_binary(erlsp_jsonrpc:notification(<<"$/progress">>, #{token => 1})),
  {_Header, Body} = split_frame(Message),
  Decoded = jsx:decode(Body),
  ?assertNot(maps:is_key(<<"id">>, Decoded)).

request_has_method_and_params_test_() ->
  Message = iolist_to_binary(erlsp_jsonrpc:request(7, <<"window/workDoneProgress/create">>, #{token => 1})),
  {_Header, Body} = split_frame(Message),
  Decoded = jsx:decode(Body),
  [
    ?_assertEqual(<<"window/workDoneProgress/create">>, maps:get(<<"method">>, Decoded)),
    ?_assertEqual(7, maps:get(<<"id">>, Decoded))
  ].

error_has_code_and_message_test_() ->
  Message = iolist_to_binary(erlsp_jsonrpc:error(1, -32601, <<"Method not found">>)),
  {_Header, Body} = split_frame(Message),
  Decoded = jsx:decode(Body),
  ErrorObj = maps:get(<<"error">>, Decoded),
  [
    ?_assertEqual(-32601, maps:get(<<"code">>, ErrorObj)),
    ?_assertEqual(<<"Method not found">>, maps:get(<<"message">>, ErrorObj))
  ].

frame_content_length_matches_body_byte_size_test() ->
  Message = iolist_to_binary(erlsp_jsonrpc:reply(1, #{text => <<"héllo"/utf8>>})),
  {Header, Body} = split_frame(Message),
  <<"Content-Length: ", LengthStr/binary>> = Header,
  DeclaredLength = binary_to_integer(string:trim(LengthStr)),
  ?assertEqual(DeclaredLength, byte_size(Body)).

decode_converts_known_keys_recursively_test() ->
  Input = #{
    <<"jsonrpc">> => <<"2.0">>,
    <<"id">> => 1,
    <<"method">> => <<"textDocument/didOpen">>,
    <<"params">> => #{
      <<"textDocument">> => #{<<"uri">> => <<"file:///a.erl">>, <<"text">> => <<"ok.">>}
    }
  },
  Decoded = erlsp_jsonrpc:decode(Input),
  ?assertEqual(
    #{
      jsonrpc => <<"2.0">>,
      id => 1,
      method => <<"textDocument/didOpen">>,
      params => #{textDocument => #{uri => <<"file:///a.erl">>, text => <<"ok.">>}}
    },
    Decoded
  ).

decode_leaves_unknown_keys_as_binaries_test() ->
  Decoded = erlsp_jsonrpc:decode(#{<<"totallyUnknownKey">> => 1}),
  ?assertEqual(#{<<"totallyUnknownKey">> => 1}, Decoded).

decode_recurses_into_lists_test() ->
  Decoded = erlsp_jsonrpc:decode(#{<<"contentChanges">> => [#{<<"text">> => <<"a">>}, #{<<"text">> => <<"b">>}]}),
  ?assertEqual(#{contentChanges => [#{text => <<"a">>}, #{text => <<"b">>}]}, Decoded).

split_frame(Message) ->
  [Header, Body] = binary:split(Message, <<"\r\n\r\n">>),
  {Header, Body}.
