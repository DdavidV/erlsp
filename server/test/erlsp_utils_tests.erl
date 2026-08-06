-module(erlsp_utils_tests).

-include_lib("eunit/include/eunit.hrl").

path_to_uri_round_trips_test() ->
  Path = filename:absname("src/erlsp_utils.erl"),
  Uri = erlsp_utils:path_to_uri(Path),
  ?assertEqual(Path, erlsp_utils:uri_to_path(Uri)).

path_to_uri_uses_file_scheme_test() ->
  Uri = erlsp_utils:path_to_uri("src/erlsp_utils.erl"),
  ?assertMatch(<<"file:///", _/binary>>, Uri).

path_to_uri_percent_encodes_spaces_but_not_slashes_test() ->
  Path = "/tmp/a dir/file name.erl",
  Uri = erlsp_utils:path_to_uri(Path),
  ?assert(binary:match(Uri, <<"%20">>) =/= nomatch),
  ?assertEqual(Path, erlsp_utils:uri_to_path(Uri)).

uri_to_path_percent_decodes_test() ->
  Path = erlsp_utils:uri_to_path(<<"file:///tmp/a%20dir/file.erl">>),
  ?assertEqual("/tmp/a dir/file.erl", Path).

module_attribute_finds_module_regardless_of_leading_tokens_test() ->
  {ok, Tokens, _} = erl_scan:string("-module(foo).\n-export([bar/0]).\nbar() -> ok."),
  ?assertEqual({ok, foo}, erlsp_utils:module_attribute(Tokens)).

module_attribute_returns_error_when_absent_test() ->
  {ok, Tokens, _} = erl_scan:string("bar() -> ok."),
  ?assertEqual(error, erlsp_utils:module_attribute(Tokens)).

module_attribute_skips_preceding_comments_and_attributes_test() ->
  {ok, Tokens, _} = erl_scan:string("-file(\"x.erl\", 1).\n-module(real_module).\ngo() -> ok."),
  ?assertEqual({ok, real_module}, erlsp_utils:module_attribute(Tokens)).
