%%-------------------------------------------------------------------
%% @copyright Maxim Fedorov <maximfca@gmail.com>
%% @doc Top-level supervisor.
%% @private
%%-------------------------------------------------------------------
-module(ecount_sup).
-author("maximfca@gmail.com").

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    %% Default: allow 1 restart a minute (traditional aggregation period for many systems)
    SupFlags = #{strategy => one_for_one,
                 intensity => 1,
                 period => 60},
    ChildSpecs = [
        #{
            id => ecount,
            start => {ecount, start_link, []}
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
