-module(erlsp_host_erl).

-include_lib("kernel/include/logger.hrl").

-export([
  compile_file/3
]).

%% Runs compile:file(Path, Options) on the HOST machine's own `erl`
%% (found via the system PATH, not erlsp's own runtime) instead of
%% in-process, with EbinDirs added to its code path via -pa, so that
%% -compile({parse_transform, M}) resolves against whatever the user's
%% real dev environment (and their own rebar3 build output) provides -
%% erlsp's own process never has the project's compiled modules loaded,
%% and never should.
%%
%% Returns compile:file/2's ordinary result term unchanged, or
%% {error, host_erl_unavailable} if the host has no `erl` on PATH, or
%% {error, {host_erl_failed, Reason}} for any other failure to get a
%% usable result back (non-zero exit with no parseable output, a crashed
%% eval, etc.) - callers should treat both as "compile diagnostics not
%% available this time" rather than a hard failure.
-spec compile_file(Path, Options, EbinDirs) -> Result when
  Path :: file:filename(),
  Options :: [compile:option()],
  EbinDirs :: [file:filename()],
  Result :: compile:comp_ret() | {error, host_erl_unavailable} | {error, {host_erl_failed, term()}}.
compile_file(Path, Options, EbinDirs) ->
  case os:find_executable("erl") of
    false ->
      {error, host_erl_unavailable};
    ErlExecutable ->
      run(ErlExecutable, Path, Options, EbinDirs)
  end.

-spec run(ErlExecutable, Path, Options, EbinDirs) -> Result when
  ErlExecutable :: file:filename(),
  Path :: file:filename(),
  Options :: [compile:option()],
  EbinDirs :: [file:filename()],
  Result :: compile:comp_ret() | {error, {host_erl_failed, term()}}.
run(ErlExecutable, Path, Options, EbinDirs) ->
  EvalString = eval_string(Path, Options),
  PaArgs = lists:append([["-pa", EbinDir] || EbinDir <- EbinDirs]),
  Port = open_port(
    {spawn_executable, ErlExecutable},
    [{args, PaArgs ++ ["-noshell", "-eval", EvalString]}, binary, exit_status, use_stdio, stderr_to_stdout]
  ),
  case collect(Port, <<>>) of
    {ok, Output} ->
      try binary_to_term(Output) of
        Term -> Term
      catch
        error:badarg ->
          ?LOG_WARNING("host erl produced unparseable output for ~s: ~p", [Path, Output]),
          {error, {host_erl_failed, {unparseable_output, Output}}}
      end;
    {error, Reason} ->
      ?LOG_WARNING("host erl failed to run for ~s: ~p", [Path, Reason]),
      {error, {host_erl_failed, Reason}}
  end.

%% Builds a self-contained -eval string: compiles Path with Options in
%% the spawned process, then writes the result to standard_io as a raw
%% term_to_binary/1 byte sequence.
%% standard_io is switched to latin1 first so each byte of the binary round-trips
%% exactly one-for-one, without it, io:put_chars either rejects the raw bytes outright
%% or reinterprets bytes >= 128 as UTF-8, corrupting the binary in transit.
-spec eval_string(Path, Options) -> Result when
  Path :: file:filename(),
  Options :: [compile:option()],
  Result :: string().
eval_string(Path, Options) ->
  lists:flatten(io_lib:format(
    "ok = io:setopts(standard_io, [{encoding, latin1}]), "
    "Result = compile:file(~p, ~p), "
    "io:put_chars(binary_to_list(term_to_binary(Result))), "
    "halt(0).",
    [Path, Options]
  )).

-spec collect(Port, Acc) -> Result when
  Port :: port(),
  Acc :: binary(),
  Result :: {ok, binary()} | {error, term()}.
collect(Port, Acc) ->
  receive
    {Port, {data, Data}} ->
      collect(Port, <<Acc/binary, Data/binary>>);
    {Port, {exit_status, 0}} ->
      {ok, Acc};
    {Port, {exit_status, Status}} ->
      {error, {exit_status, Status, Acc}}
  after 30000 ->
    {error, timeout}
  end.
