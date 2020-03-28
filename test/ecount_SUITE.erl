%%-------------------------------------------------------------------
%% @copyright Maxim Fedorov <maximfca@gmail.com>
%% @private
%%-------------------------------------------------------------------
-module(ecount_SUITE).
-author("maximfca@gmail.com").

-export([
    all/0,
    suite/0,
    end_per_testcase/2
]).

-export([
    basic/0, basic/1,
    large/0, large/1,
    parallel/0, parallel/1,
    throughput/0, throughput/1
]).

-export([
    bench/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

suite() ->
    [{timetrap, {seconds, 5}}].

all() ->
    [basic, large, parallel, throughput].

end_per_testcase(_TestCase, _Config) ->
    is_pid(whereis(ecount)) andalso gen_server:stop(ecount).

%%--------------------------------------------------------------------
%% Helper functions

%% @doc Formats number rounded to 3 digits.
%%  Example: 88 -> 88, 880000 -> 880 Ki, 100501 -> 101 Ki
-spec format_number(non_neg_integer()) -> string().
format_number(Num) when Num > 100000000000 ->
    integer_to_list(round(Num / 1000000000)) ++ " Gi";
format_number(Num) when Num > 100000000 ->
    integer_to_list(round(Num / 1000000)) ++ " Mi";
format_number(Num) when Num > 100000 ->
    integer_to_list(round(Num / 1000)) ++ " Ki";
format_number(Num) ->
    integer_to_list(Num).

%% Spawns process for every "bump list" passed.
-spec run([[{ecount:name(), integer()}]]) -> ok.
run(Templates) ->
    PidList = [spawn_monitor(fun () -> bump(BumpList) end) || BumpList <- Templates],
    gather(maps:from_list(PidList)).

bump([{Counter, Count}]) ->
    ecount:count(Counter, Count);
bump([{Counter, Count} | Tail]) ->
    ecount:count(Counter, Count),
    bump(Tail).

%% Waits until all processes in a map of #{pid() => reference()} exit with
%%  reason 'normal'.
gather(None) when map_size(None) =:= 0 ->
    ok;
gather(Pids) ->
    receive
        {'DOWN', _MRef, process, Pid, normal} when is_map_key(Pid, Pids) ->
            gather(maps:remove(Pid, Pids))
    end.

%% Runs throughput benchmark
benchmark(Options, QLen, NumCounters, CounterType, NumProcesses, TimeMs) ->
    {ok, CntPid} = ecount:start_link(Options),
    %% create counters mappings to processes
    Queues = [make_queue(QLen, NumCounters, CounterType, queue:new()) || _ <- lists:seq(1, NumProcesses)],
    %% set higher priority to get some better timing
    erlang:process_flag(priority, high),
    %%
    Pids = [spawn(?MODULE, bench, [Queue]) || Queue <- Queues],
    %%
    timer:sleep(TimeMs),
    %% kill all processes brutally
    [exit(Pid, kill) || Pid <- Pids],
    erlang:process_flag(priority, normal),
    %% output is equal to sum of all bumps for all counters()
    Result = lists:sum(maps:values(ecount:all())),
    %% clear up
    gen_server:stop(CntPid),
    ct:pal("~s QPS with ~b qlen, ~b variety of ~s (~b processes, ~p)",
        [format_number(Result * 1000 div TimeMs), QLen, NumCounters, CounterType, NumProcesses, Options]),
    Result.

make_queue(0, _NumCounters, _CounterType, Queue) ->
    Queue;
make_queue(More, NumCounters, CounterType, Queue) ->
    Name = make_counter(NumCounters, CounterType),
    make_queue(More - 1, NumCounters, CounterType, queue:in(Name, Queue)).

make_counter(NumCounters, atom) ->
    list_to_atom(lists:concat(["name_", rand:uniform(NumCounters)]));
make_counter(NumCounters, binary) ->
    Rnd = rand:uniform(NumCounters),
    << <<"name_">>/binary, Rnd:32>>;
make_counter(NumCounters, string) ->
    "name_" ++ integer_to_list(rand:uniform(NumCounters));
make_counter(NumCounters, tuple) ->
    {tuple, rand:uniform(NumCounters)};
make_counter(NumCounters, integer) ->
    rand:uniform(NumCounters).

bench(Queue) ->
    {{value, Name}, NewQ} = queue:out(Queue),
    ecount:count(Name),
    bench(queue:in(Name, NewQ)).

%%--------------------------------------------------------------------
%% Test cases

basic() ->
    [{doc, "Basic counting"}].

basic(Config) when is_list(Config) ->
    {ok, _Pid} = ecount:start_link(),
    ecount:count(basic),
    ?assertEqual(1, ecount:get(basic)),
    ecount:count(basic, 10),
    ?assertEqual(11, ecount:get(basic)),
    ecount:count(basic, -11),
    ?assertEqual(0, ecount:get(basic)).

large() ->
    [{doc, "Large amount of counters: tests additional atomic arrays allocation"}].

large(_Config) ->
    Counters = 2048, Shards = 32,
    {ok, _Pid} = ecount:start_link(#{chunk_size => Counters div Shards}),
    Expected = [{"counter_" ++ integer_to_list(N), rand:uniform(100)} || N <- lists:seq(1, Counters)],
    [ecount:count(N, C) || {N, C} <- Expected],
    ?assertEqual(maps:from_list(Expected), ecount:all()).

parallel() ->
    [{doc, "Test counting in parallel"}].

parallel(_Config) ->
    {ok, _Pid} = ecount:start_link(),
    NumCounters = 1024, %% number of counters to use
    Concurrency = 1024, %% number of processes to spawn
    BumpsPerProcess = 4096, %% every process does this amount of bumps
    BumpMax = 32, %% bump from 1 to this value (no negative increments)
    %% For every "concurrency" process create a list of bumps to go through
    Template = [
        [{rand:uniform(NumCounters), rand:uniform(BumpMax)} || _ <- lists:seq(1, BumpsPerProcess)]
        || _ <- lists:seq(1, Concurrency)],
    %%
    {_Time, ok} = timer:tc(fun () -> run(Template) end),
    %% calculate expectations: make a map CounterName => TotalCount
    Expected = lists:foldl(
        fun ({Name, Bump}, Acc) ->
            maps:update_with(Name, fun (Old) -> Old + Bump end, Bump, Acc)
        end, #{}, lists:concat(Template)),
    ct:pal("~s per second (~b processes)",
        [format_number(BumpsPerProcess * Concurrency * 1000000 div _Time), Concurrency]),
    Actual = ecount:all(),
    Expected =/= Actual andalso
    begin
        Extra = maps:without(maps:keys(Actual), Expected),
        Extra =/= #{} andalso ct:pal("Unexpected keys: ~p", [Extra]),
        [ct:pal("~p: expected ~p, actual ~p", [Key, Value, maps:get(Key, Actual, missing)])
            || {Key, Value} <- maps:to_list(Expected), Value =/= maps:get(Key, Actual, missing)],
        ?assert(false)
    end.

throughput() ->
    [{doc, "Test throughput - how many bumps are accepted (does not check correctness)"},
        {timetrap, {seconds, 60}}].

throughput(_Config) ->
    %% measure variants for 5 seconds
    [
        begin
            NoPT = benchmark(#{}, 30, 1024, Type, 1024, 3000),
            PT = benchmark(#{flush_after => 500}, 30, 1024, Type, 1024, 3000),
            ?assert(PT > NoPT)
        end
        || Type <- [atom, binary, string, tuple, integer]].
