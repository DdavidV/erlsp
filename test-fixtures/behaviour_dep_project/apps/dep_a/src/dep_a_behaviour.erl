-module(dep_a_behaviour).

-callback run(Arg) -> Result when
  Arg :: term(),
  Result :: term().
