-module(erlsp_host_erl).

-include_lib("kernel/include/logger.hrl").

-export([
  compile_file/3,
  find_host_erl/0,
  root_dir/0
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
  case find_host_erl() of
    false ->
      {error, host_erl_unavailable};
    ErlExecutable ->
      run(ErlExecutable, Path, Options, EbinDirs)
  end.

%% os:find_executable("erl") isn't enough on its own: OTP's own erlexec
%% prepends the RUNNING node's own BINDIR to PATH for every child process
%% it spawns.
%% Once erlsp itself ships as a release with a bundled ERTS, the erl PATH search
%% from inside erlsp's own process finds ITS OWN bundled erl first
%% which can't run standalone the way this module invokes it
%% (it needs the full release launcher's boot machinery), so using it here
%% would just reproduce the exact false-positive diagnostics problem host delegation
%% exists to avoid.
%%
%% There's no reliable static signal for "this erl won't work standalone"
%% so each PATH candidate is tried for real, in order, with exactly the invocation
%% run/4 actually uses (-noshell -eval), and the first one that works is
%% used. This directly answers the only question that matters ("does this
%% erl actually run standalone") rather than guessing from a proxy signal.
-spec find_host_erl() -> Result when
  Result :: file:filename() | false.
find_host_erl() ->
  find_host_erl(os:getenv("PATH")).

-spec find_host_erl(PathEnv) -> Result when
  PathEnv :: string() | false,
  Result :: file:filename() | false.
find_host_erl(false) ->
  false;
find_host_erl(PathEnv) ->
  Separator = case os:type() of
    {win32, _} -> ";";
    _Other -> ":"
  end,
  Dirs = string:split(PathEnv, Separator, all),
  first_working_erl(Dirs).

-spec first_working_erl(Dirs) -> Result when
  Dirs :: [string()],
  Result :: file:filename() | false.
first_working_erl([Dir | Rest]) ->
  ErlBasename = case os:type() of
    {win32, _} -> "erl.exe";
    _Other -> "erl"
  end,
  Candidate = filename:join(Dir, ErlBasename),
  case filelib:is_regular(Candidate) andalso runs_standalone(Candidate) of
    true -> Candidate;
    false -> first_working_erl(Rest)
  end;
first_working_erl([]) ->
  false.

%% A trivial -noshell -eval invocation, exactly the shape run/4 uses -
%% this is the actual behavior that matters, not a proxy for it. Fails
%% fast (5s) since a broken candidate here (e.g. erlsp's own bundled erl,
%% invoked without the release launcher's boot machinery it needs) hangs
%% or errors immediately rather than doing real work.
-spec runs_standalone(Candidate) -> Result when
  Candidate :: file:filename(),
  Result :: boolean().
runs_standalone(Candidate) ->
  Port = open_port(
    {spawn_executable, Candidate},
    [{args, ["-noshell", "-eval", "halt(0)."]}, exit_status, use_stdio, stderr_to_stdout]
  ),
  receive
    {Port, {exit_status, 0}} -> true;
    {Port, {exit_status, _NonZero}} -> false
  after 5000 ->
    catch port_close(Port),
    false
  end.

%% The HOST's own OTP install root (e.g. "/usr/lib/erlang" or an asdf/kerl
%% path), found by asking a real, working host erl for its own
%% code:root_dir/0 - NOT erlsp's own code:root_dir/0, which under the
%% bundled-ERTS release only sees the handful of OTP apps erlsp itself
%% depends on (kernel, stdlib, compiler, jsx), not the host's full
%% install. erlsp_index_otp_job uses this to index the host's real
%% stdlib/kernel/eunit/etc. source for go-to-definition - using erlsp's
%% own bundled root there would silently make every OTP application erlsp
%% doesn't itself depend on invisible to go-to-definition, even though
%% it's genuinely installed on the host.
-spec root_dir() -> Result when
  Result :: {ok, file:filename()} | {error, host_erl_unavailable} | {error, {host_erl_failed, term()}}.
root_dir() ->
  case find_host_erl() of
    false ->
      {error, host_erl_unavailable};
    ErlExecutable ->
      Port = open_port(
        {spawn_executable, ErlExecutable},
        [{args, ["-noshell", "-eval", "io:put_chars(code:root_dir()), halt(0)."]},
         binary, exit_status, use_stdio, stderr_to_stdout]
      ),
      case collect(Port, <<>>) of
        {ok, Output} -> {ok, binary_to_list(Output)};
        {error, Reason} -> {error, {host_erl_failed, Reason}}
      end
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
