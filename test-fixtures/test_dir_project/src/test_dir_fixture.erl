-module(test_dir_fixture).

-export([add/2]).

-spec add(A, B) -> Result when
  A :: integer(),
  B :: integer(),
  Result :: integer().
add(A, B) ->
  A + B.
