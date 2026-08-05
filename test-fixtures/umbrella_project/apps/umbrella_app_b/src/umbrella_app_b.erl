-module(umbrella_app_b).

%% References its own sub-app's header via include_lib - exercises the
%% umbrella-specific variant of the include_lib gap: own_app_parent_dirs/1
%% must resolve this against apps/umbrella_app_b/ specifically, not the
%% umbrella root.
-include_lib("umbrella_app_b/include/umbrella_app_b.hrl").

-export([go/0]).

-spec go() -> atom().
go() ->
  ?UMBRELLA_B_MACRO.
