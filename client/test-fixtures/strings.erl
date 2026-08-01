-module(strings).

f() ->
  A = "a plain string",
  B = "a string with \"escaped quotes\" and a \n newline",
  C = "",
  D = "line one"
      "line two implicitly concatenated",
  ok.
