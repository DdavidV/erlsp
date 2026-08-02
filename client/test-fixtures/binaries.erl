-module(binaries).

f() ->
  A = <<"hello">>,
  B = <<1, 2, 3>>,
  C = <<A/binary, "world"/utf8>>,
  <<Head:8, Rest/binary>> = A,
  <<Len:16/integer-little, Payload:Len/binary-unit:8>> = C,
  ok.
