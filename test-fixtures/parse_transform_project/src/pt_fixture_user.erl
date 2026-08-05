-module(pt_fixture_user).

-compile({parse_transform, pt_fixture_transform}).

-export([go/0]).

-spec go() -> ok.
go() ->
  ok.
