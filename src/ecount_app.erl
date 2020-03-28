%%-------------------------------------------------------------------
%% @copyright Maxim Fedorov <maximfca@gmail.com>
%% @doc Application behaviour definition.
%% @private
%%-------------------------------------------------------------------
-module(ecount_app).
-author("maximfca@gmail.com").

-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()}.
start(_StartType, _StartArgs) ->
    ecount_sup:start_link().

-spec stop(State :: term()) -> ok.
stop(_State) ->
    ok.
