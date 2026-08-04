-module(erlsp_index_otp_job).

-behaviour(erlsp_job).

-include_lib("kernel/include/logger.hrl").

-export([
  run/2
]).

%% Parses every OTP application's source under the running Erlang
%% installation's lib/ directory and records where each module and
%% function is defined, so go-to-definition also works
%% for stdlib/kernel/etc.
-spec run(Uri, Token) -> Result when
  Uri :: erlsp_documents:uri(),
  Token :: erlsp_report:token(),
  Result :: ok.
run(_Uri, Token) ->
  erlsp_report:report(Token, {'begin', <<"Indexing">>}),
  Paths = otp_erl_files(),
  ?LOG_INFO("indexing ~b OTP files", [length(Paths)]),
  erlsp_index:index_files(Paths, Token, <<"OTP files">>),
  ?LOG_INFO("OTP indexing complete"),
  erlsp_report:report(Token, done),
  ok.

-spec otp_erl_files() -> Result when
  Result :: [file:filename()].
otp_erl_files() ->
  %% "**" recurses into subdirectories - some apps nest source further
  %% (e.g. wx's generated bindings live under lib/wx-*/src/gen/*.erl), not
  %% just directly under src/.
  RootDir = code:root_dir(),
  filelib:wildcard(filename:join([RootDir, "lib", "*", "src", "**/*.erl"])).
