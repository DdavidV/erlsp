-module(maybe_expr).

-export([process/1, simple/1]).

process(Input) ->
  maybe
    {ok, Parsed} ?= parse(Input),
    ok ?= validate(Parsed),
    {ok, Enriched} ?= enrich(Parsed),
    {ok, Enriched}
  else
    {error, Reason} -> {error, Reason};
    invalid -> {error, invalid_input}
  end.

simple(X) ->
  maybe
    ok ?= X,
    done
  end.
