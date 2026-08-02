-module(docstring).

-moduledoc """
This module does things.
""".

-doc """
Adds two numbers.
""".
-spec add(integer(), integer()) -> integer().
add(X, Y) ->
  """
  Inline docstring before the body.
  """
  X + Y.
