%%-------------------------------------------------------------------
%% @copyright Maxim Fedorov <maximfca@gmail.com>
%% @doc
%% Dynamic Erlang counters, simplified example.
%% Stores mapping of counter name to atomic array & index in an ETS
%%  table.
%% Table is ordered_set. This allows for a number of tricks:
%%  * avoids potential degradation for atom hashing (leading to very
%%    long lists in a single bucket)
%%  * provides foundation for counters aggregation queries
%%
%% When number of pre-allocated indices in current atomic array
%%  is exhausted, another array is allocated. Allocation size is
%%  always the same, decided upon server start, - while it is easy
%%  to implement some "growth stages" algorithm (e.g. doubling amount
%%  of counters to allocate next time), new array allocation is fast
%%  enough to make smarted logic useless.
%% However, it is possible to configure the size of each atomic chunk
%%  allocated, when starting the server.
%%
%% Thanks @Bryan Naegele, for an idea to use persistent_term as a
%%  caching layer for much faster counter name access.
%% @end
%%-------------------------------------------------------------------
-module(ecount).
-author("maximfca@gmail.com").

-behaviour(gen_server).

-compile(warn_missing_spec).

%% API
-export([
    start_link/0,
    start_link/1,
    count/1,
    count/2,
    all/0,
    get/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2
]).

%%--------------------------------------------------------------------
%% API

%% Define counter name type, initially just an unstructured term.
-type name() :: atom() | binary() | list() | tuple() |integer().

-export_type([name/0]).

%% @doc
%% Starts the server within supervision tree, with default 512-sized
%%  atomic array size increment.
-spec start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link() ->
    start_link(512). %% hardcode what can be hardcoded!

%% @doc
%% Starts the server within supervision tree, with some specified
%%  atomic array size increment.
-spec start_link(ArraySizeIncrement :: pos_integer()) -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(ArraySizeIncrement) when is_integer(ArraySizeIncrement), ArraySizeIncrement > 0 ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, ArraySizeIncrement, []).

%% @doc
%% Bumps a counter Name by 1.
-spec count(name()) -> ok.
count(Name) ->
    count(Name, 1).

%% @doc
%% Bumps a counter Name by Incr.
-spec count(name(), Incr :: integer()) -> ok.
count(Name, Incr) ->
    try ets:lookup_element(?MODULE, Name, 2) of
        {Ref, Ix} ->
            atomics:add(Ref, Ix, Incr)
    catch
        error:badarg ->
            % tough choice: cast or call?
            % for cast, sender is unblocked, for call, it has to wait
            % waiting is good if receiver may be overloaded
            gen_server:call(?MODULE, {count, Name, Incr})
    end.

%% @doc
%% Returns a map of all counter names to their current values.
-spec all() -> [{name(), integer()}].
all() ->
    lists:foldl(
        fun ({Name, {Ref, Ix}}, Acc) ->
            maps:put(Name, atomics:get(Ref, Ix), Acc)
        end, #{}, ets:tab2list(?MODULE)).

%% @doc
%% Returns a single counter value, or 'undefined' if this
%%  counter is not known.
-spec get(name()) -> undefined | integer().
get(What) ->
    try ets:lookup_element(?MODULE, What, 2) of
        {Ref, Ix} ->
            atomics:get(Ref, Ix)
    catch
        error:badarg ->
            undefined
    end.

%%--------------------------------------------------------------------
%% gen_server callbacks

-record(ecount_state, {
    %% table storing mapping between counter name and atomic ref/index
    counters :: ets:tid(),
    %% list of all atomic refs
    refs :: [atomics:atomics_ref()],
    %% index for the next counter
    next_ref = 1 :: pos_integer(),
    %% maximum number of counters in the current array, no doubling logic here
    max_ref :: pos_integer()
}).

-type ecount_state() :: #ecount_state{}.

-spec init(pos_integer()) -> ecount_state().
init(ArraySizeIncrement) ->
    {ok, #ecount_state{
        counters = ets:new(?MODULE, [named_table, ordered_set, protected, {read_concurrency, true}]),
        refs = [atomics:new(ArraySizeIncrement, [])],
        max_ref = ArraySizeIncrement
    }}.

-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()}, ecount_state()) ->
    {reply, ok, ecount_state()}.
handle_call({count, Name, Incr}, _From, #ecount_state{counters = Tab} = State) ->
    case ets:lookup(Tab, Name) of
        [] when State#ecount_state.next_ref =< State#ecount_state.max_ref ->
            Ix = State#ecount_state.next_ref,
            Ref = hd(State#ecount_state.refs),
            atomics:add(Ref, Ix, Incr),
            true = ets:insert_new(Tab, {Name, {Ref, Ix}}),
            {reply, ok, State#ecount_state{next_ref = Ix + 1}};
        [] ->
            Ref = atomics:new(State#ecount_state.max_ref, []),
            atomics:add(Ref, 1, Incr),
            true = ets:insert_new(Tab, {Name, {Ref, 1}}),
            {reply, ok, State#ecount_state{next_ref = 2, refs = [Ref | State#ecount_state.refs]}};
        [{Name, {Ref, Ix}}] ->
            atomics:add(Ref, Ix, Incr),
            {reply, ok, State}
    end;

handle_call(_Request, _From, _State) ->
    error(badarg).

-spec handle_cast(term(), ecount_state()) -> no_return().
handle_cast(_Request, _State) ->
    error(badarg).

%%--------------------------------------------------------------------
%%% Internal functions
