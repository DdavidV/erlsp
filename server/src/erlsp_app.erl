-module(erlsp_app).

-behaviour(application).

-export([
  start/2,
  stop/1
]).

-spec start(StartType, StartArgs) -> Result when
  StartType :: application:start_type(),
  StartArgs :: term(),
  Result :: {ok, pid()}.
start(_StartType, _StartArgs) ->
  ok = configure_logging(),
  erlsp_sup:start_link().

-spec stop(State) -> Result when
  State :: term(),
  Result :: ok.
stop(_State) ->
  ok.

%% stdout is the JSON-RPC channel: any stray write to it would corrupt the
%% protocol stream, so the default console handler is removed and logs only
%% ever go to a file. Must run before erlsp_sup starts anything (a
%% supervisor/progress report logged before this point would otherwise hit
%% the default handler and land on stdout).
-spec configure_logging() -> Result when
  Result :: ok.
configure_logging() ->
  logger:remove_handler(default),
  logger:set_primary_config(level, info),
  LogFile = filename:join(filename:basedir(user_log, "erlsp"), "server.log"),
  ok = filelib:ensure_dir(LogFile),
  logger:add_handler(erlsp_file_handler, logger_std_h, #{
    config => #{
      file => LogFile,
      max_no_bytes => 10 * 1024 * 1024, % rotate after 10 MB
      max_no_files => 5
    },
    formatter => {logger_formatter, #{single_line => true}}
  }).
