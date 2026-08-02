-module(sigil).

f() ->
  A = ~"raw string",
  B = ~s"escaped \n string",
  C = ~S"verbatim \n string",
  D = "normal string",
  ok.
