-module(erlsp).

-include("erlsp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([main/1]).

-spec main(Args) -> Result when
  Args :: term(),
  Result :: ok.
main(_Args) ->
  ok = configure_logging(),
  {ok, _} = application:ensure_all_started(?APP_NAME, permanent),
  ?LOG_INFO("erlsp started"),
  Ref = monitor(process, whereis(?ERLSP_SERVER)),
  receive
    {'DOWN', Ref, process, _Pid, _Reason} -> ok
  end,
  logger_std_h:filesync(erlsp_file_handler).

%% stdout is the JSON-RPC channel: any stray write to it would corrupt the
%% protocol stream, so the default console handler is removed and logs only
%% ever go to a file.
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
