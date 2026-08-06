-module(erlsp_host_erl).

-include_lib("kernel/include/logger.hrl").

-export([
  find_host_erl/0,
  run/5
]).

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
%% run/5 actually uses (-noshell -eval), and the first one that works is
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

%% A trivial -noshell -eval invocation, exactly the shape run/5 uses -
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

%% Runs erlang:apply(Module, Function, Args) on the HOST's own erl
%% instead of in erlsp's own process, and returns whatever that call returns
%% or {error, host_erl_unavailable} if the host has no erl on PATH
%% or {error, {host_erl_failed, Reason}} for any other failure to get a usable result back.
-spec run(Module, Function, PaDirs, Args, Opts) -> Result when
  Module :: module(),
  Function :: atom(),
  PaDirs :: [file:filename()],
  Args :: [term()],
  Opts :: [{cd, file:filename()}],
  Result :: term() | {error, host_erl_unavailable} | {error, {host_erl_failed, term()}}.
run(Module, Function, PaDirs, Args, Opts) ->
  case find_host_erl() of
    false ->
      {error, host_erl_unavailable};
    ErlExecutable ->
      run(ErlExecutable, Module, Function, PaDirs, Args, Opts)
  end.

-spec run(ErlExecutable, Module, Function, PaDirs, Args, Opts) -> Result when
  ErlExecutable :: file:filename(),
  Module :: module(),
  Function :: atom(),
  PaDirs :: [file:filename()],
  Args :: [term()],
  Opts :: [{cd, file:filename()}],
  Result :: term() | {error, {host_erl_failed, term()}}.
run(ErlExecutable, Module, Function, PaDirs, Args, Opts) ->
  PaArgs = lists:append([["-pa", PaDir] || PaDir <- PaDirs]),
  EvalString = bootstrap_eval_string(Module, Function, Args),
  PortOpts = [
    {args, PaArgs ++ ["-noshell", "-eval", EvalString]},
    binary, exit_status, use_stdio, stderr_to_stdout
  ],
  Port = open_port({spawn_executable, ErlExecutable}, Opts ++ PortOpts),
  case collect(Port, <<>>) of
    {ok, Output} ->
      try binary_to_term(Output) of
        Term -> Term
      catch
        error:badarg ->
          ?LOG_WARNING("host erl produced unparseable output for ~p:~p: ~p", [Module, Function, Output]),
          {error, {host_erl_failed, {unparseable_output, Output}}}
      end;
    {error, Reason} ->
      ?LOG_WARNING("host erl failed to run ~p:~p: ~p", [Module, Function, Reason]),
      {error, {host_erl_failed, Reason}}
  end.

-spec bootstrap_eval_string(Module, Function, Args) -> Result when
  Module :: module(),
  Function :: atom(),
  Args :: [term()],
  Result :: string().
bootstrap_eval_string(Module, Function, Args) ->
  lists:flatten(io_lib:format(
    "ok = io:setopts(standard_io, [{encoding, latin1}]), "
    "Result = erlang:apply(~p, ~p, ~p), "
    "io:put_chars(binary_to_list(term_to_binary(Result))), "
    "halt(0).",
    [Module, Function, Args]
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
