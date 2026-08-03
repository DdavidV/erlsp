-module(erlsp_index_otp_job).

-behaviour(erlsp_job).

-include_lib("kernel/include/logger.hrl").

-export([
  run/1
]).

%% Parses every OTP application's source under the running Erlang
%% installation's lib/ directory and records where each module and
%% function is defined, so go-to-definition also works
%% for stdlib/kernel/etc.
-spec run(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: ok.
run(_Uri) ->
  Paths = otp_erl_files(),
  ?LOG_INFO("indexing ~b OTP files", [length(Paths)]),
  lists:foreach(fun erlsp_index:index_file/1, Paths),
  ?LOG_INFO("OTP indexing complete"),
  ok.

-spec otp_erl_files() -> Result when
  Result :: [file:filename()].
otp_erl_files() ->
  RootDir = code:root_dir(),
  filelib:wildcard(filename:join([RootDir, "lib", "*", "src", "*.erl"])).
