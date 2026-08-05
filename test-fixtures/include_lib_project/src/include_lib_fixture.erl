-module(include_lib_fixture).

%% References this app's OWN header via include_lib, not a dependency's -
%% this is exactly the pattern that fails to resolve today.
-include_lib("include_lib_project/include/fixture.hrl").

-export([go/0]).

-spec go() -> #fixture_record{}.
go() ->
  #fixture_record{a = ?FIXTURE_MACRO, b = ok}.
