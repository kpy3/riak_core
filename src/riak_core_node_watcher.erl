%% -------------------------------------------------------------------
%%
%% riak_core: Core Riak Application
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(riak_core_node_watcher).

-behaviour(gen_server).

%% API
-export([start_link/0,
         service_up/2,
         service_up/3,
         service_up/4,
         service_down/1,
         service_down/2,
         node_up/0,
         node_down/0,
         services/0, services/1,
         nodes/1,
         avsn/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { status = up,
                 services = [],
                 health_checks = [],
                 peers = [],
                 avsn = 0,
                 bcast_tref,
                 bcast_mod = {gen_server, abcast}}).

-record(health_check, { callback :: mfa(),
                        service_pid :: pid(),
                        checking_pid :: pid(),
                        health_failures = 0 :: non_neg_integer(),
                        callback_failures = 0,
                        interval_tref,
                        % how many seconds to wait after a check has
                        % finished before starting a new one
                        check_interval = 60 :: timeout(),
                        max_callback_failures = 3,
                        max_health_failures = 1 }).


%% ===================================================================
%% Public API
%% ===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

service_up(Id, Pid) ->
    gen_server:call(?MODULE, {service_up, Id, Pid}, infinity).

service_up(Id, Pid, MFA) ->
    service_up(Id, Pid, MFA, []).

service_up(Id, Pid, {Module, Function, Args}, Options) ->
    gen_server:call(?MODULE, {service_up, Id, Pid, {Module, Function, Args}, Options}, infinity).

service_down(Id) ->
    gen_server:call(?MODULE, {service_down, Id}, infinity).

service_down(Id, true) ->
    gen_server:call(?MODULE, {service_down, Id, health_check}, infintiy);
service_down(Id, false) ->
    service_down(Id).

node_up() ->
    gen_server:call(?MODULE, {node_status, up}, infinity).

node_down() ->
    gen_server:call(?MODULE, {node_status, down}, infinity).

services() ->
    gen_server:call(?MODULE, services, infinity).

services(Node) ->
    internal_get_services(Node).

nodes(Service) ->
    internal_get_nodes(Service).


%% ===================================================================
%% Test API
%% ===================================================================

avsn() ->
    gen_server:call(?MODULE, get_avsn, infinity).


%% ====================================================================
%% gen_server callbacks
%% ====================================================================

init([]) ->
    %% Trap exits so that terminate/2 will get called
    process_flag(trap_exit, true),

    %% Setup callback notification for ring changes; note that we use the
    %% supervised variation so that the callback gets removed if this process
    %% exits
    watch_for_ring_events(),

    %% Watch for node up/down events
    net_kernel:monitor_nodes(true),

    %% Setup ETS table to track node status
    ets:new(?MODULE, [protected, {read_concurrency, true}, named_table]),

    {ok, schedule_broadcast(#state{})}.

handle_call({set_bcast_mod, Module, Fn}, _From, State) ->
    %% Call available for swapping out how broadcasts are generated
    {reply, ok, State#state {bcast_mod = {Module, Fn}}};

handle_call(get_avsn, _From, State) ->
    {reply, State#state.avsn, State};

handle_call({service_up, Id, Pid}, _From, State) ->
    %% Update the set of active services locally
    Services = ordsets:add_element(Id, State#state.services),
    S2 = State#state { services = Services },

    %% remove any existing health checks
    Healths = case orddict:find(Id, State#state.health_checks) of
        error ->
            State#state.health_checks;
        {ok, Check} ->
            health_fsm(remove, Id, Check),
            orddict:erase(Id, State#state.health_checks)
    end,

    %% Remove any existing mrefs for this service
    delete_service_mref(Id),

    %% Setup a monitor for the Pid representing this service
    Mref = erlang:monitor(process, Pid),
    erlang:put(Mref, Id),
    erlang:put(Id, Mref),

    %% Update our local ETS table and broadcast
    S3 = local_update(S2),
    {reply, ok, update_avsn(S3#state{health_checks = Healths})};

handle_call({service_up, Id, Pid, MFA, Options}, From, State) ->
    %% update the active set of services if needed.
    {reply, _, State1} = handle_call({service_up, Id, Pid}, From, State),

    %% uninstall old health check
    case orddict:find(Id, State#state.health_checks) of
        {ok, OldCheck} ->
            health_fsm(remove, Id, OldCheck);
        error ->
            ok
    end,

    %% install the health check
    CheckInterval = proplists:get_value(check_interval, Options, 60),
    CheckRec = #health_check{
        callback = MFA,
        check_interval = CheckInterval,
        service_pid = Pid,
        max_callback_failures = proplists:get_value(max_callback_failures, Options, 3),
        interval_tref = erlang:send_after(CheckInterval * 1000, self(), {health_check, Id})
    },
    Healths = orddict:store(Id, CheckRec, State1#state.health_checks),
    {reply, ok, State1#state{health_checks = Healths}};

handle_call({service_down, Id}, _From, State) ->
    %% Update the set of active services locally
    Services = ordsets:del_element(Id, State#state.services),
    S2 = State#state { services = Services },

    %% Remove any existing mrefs for this service
    delete_service_mref(Id),

    %% Update local ETS table and broadcast
    S3 = local_update(S2),

    %% Remove health check if any
    case orddict:find(Id, State#state.health_checks) of
        error ->
            ok;
        {ok, Check} ->
            health_fsm(remove, Id, Check)
    end,

    Healths = orddict:erase(Id, S3#state.health_checks),
    {reply, ok, update_avsn(S3#state{health_checks = Healths})};

handle_call({node_status, Status}, _From, State) ->
    Transition = {State#state.status, Status},
    S2 = case Transition of
             {up, down} -> %% up -> down
                 local_delete(State#state { status = down });

             {down, up} -> %% down -> up
                 local_update(State#state { status = up });

             {Status, Status} -> %% noop
                 State
    end,
    {reply, ok, update_avsn(S2)};
handle_call(services, _From, State) ->
    Res = [Service || {{by_service, Service}, Nds} <- ets:tab2list(?MODULE),
                      Nds /= []],
    {reply, lists:sort(Res), State}.


handle_cast({ring_update, R}, State) ->
    %% Ring has changed; determine what peers are new to us
    %% and broadcast out current status to those peers.
    Peers0 = ordsets:from_list(riak_core_ring:all_members(R)),
    Peers = ordsets:del_element(node(), Peers0),

    S2 = peers_update(Peers, State),
    {noreply, update_avsn(S2)};

handle_cast({up, Node, Services}, State) ->
    S2 = node_up(Node, Services, State),
    {noreply, update_avsn(S2)};

handle_cast({down, Node}, State) ->
    node_down(Node, State),
    {noreply, update_avsn(State)}.

handle_info({nodeup, _Node}, State) ->
    %% Ignore node up events; nothing to do here...
    {noreply, State};

handle_info({nodedown, Node}, State) ->
    node_down(Node, State),
    {noreply, update_avsn(State)};

handle_info({'DOWN', Mref, _, _Pid, _Info}, State) ->
    %% A sub-system monitored process has terminated. Identify
    %% the sub-system in question and notify our peers.
    case erlang:get(Mref) of
        undefined ->
            %% No entry found for this monitor; ignore the message
            {noreply, update_avsn(State)};

        Id ->
            %% Remove the id<->mref entries in the pdict
            delete_service_mref(Id),

            %% remove any health checks in place
            case orddict:find(Id, State#state.health_checks) of
                error ->
                    ok;
                {ok, Health} ->
                    health_fsm(remove, Id, Health)
            end,
            Healths = orddict:erase(Id, State#state.health_checks),

            %% Update our list of active services and ETS table
            Services = ordsets:del_element(Id, State#state.services),
            S2 = State#state { services = Services },
            local_update(S2),
            {noreply, update_avsn(S2#state{health_checks = Healths})}
    end;

handle_info({'EXIT', Pid, Cause} = Msg, State) ->
    Service = erlang:erase(Pid),
    State2 = handle_check_msg(Msg, Service, State),
    {noreply, State2};

handle_info({check_health, Id}, State) ->
    State2 = handle_check_msg(check_health, Id, State),
    {noreply, State2};

handle_info({gen_event_EXIT, _, _}, State) ->
    %% Ring event handler has been removed for some reason; re-register
    watch_for_ring_events(),
    {noreply, update_avsn(State)};

handle_info(broadcast, State) ->
    S2 = broadcast(State#state.peers, State),
    {noreply, S2}.


terminate(_Reason, State) ->
    %% Let our peers know that we are shutting down
    broadcast(State#state.peers, State#state { status = down }).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% ====================================================================
%% Internal functions
%% ====================================================================

update_avsn(State) ->
    State#state { avsn = State#state.avsn + 1 }.

watch_for_ring_events() ->
    Self = self(),
    Fn = fun(R) ->
                 gen_server:cast(Self, {ring_update, R})
         end,
    riak_core_ring_events:add_sup_callback(Fn).

delete_service_mref(Id) ->
    %% Cleanup the monitor if one exists
    case erlang:get(Id) of
        undefined ->
            ok;
        Mref ->
            erlang:erase(Mref),
            erlang:erase(Id),
            erlang:demonitor(Mref)
    end.


broadcast(Nodes, State) ->
    case (State#state.status) of
        up ->
            Msg = {up, node(), State#state.services};
        down ->
            Msg = {down, node()}
    end,
    {Mod, Fn} = State#state.bcast_mod,
    Mod:Fn(Nodes, ?MODULE, Msg),
    schedule_broadcast(State).

schedule_broadcast(State) ->
    case (State#state.bcast_tref) of
        undefined ->
            ok;
        OldTref ->
            erlang:cancel_timer(OldTref)
    end,
    Interval = app_helper:get_env(riak_core, gossip_interval),
    Tref = erlang:send_after(Interval, self(), broadcast),
    State#state { bcast_tref = Tref }.

is_peer(Node, State) ->
    ordsets:is_element(Node, State#state.peers).

is_node_up(Node) ->
    ets:member(?MODULE, Node).


node_up(Node, Services, State) ->
    case is_peer(Node, State) of
        true ->
            %% Before we alter the ETS table, see if this node was previously down. In
            %% that situation, we'll go ahead broadcast out.
            S2 = case is_node_up(Node) of
                     false ->
                         broadcast([Node], State);
                     true ->
                         State
                 end,

            case node_update(Node, Services) of
                [] ->
                    ok;
                AffectedServices ->
                    riak_core_node_watcher_events:service_update(AffectedServices)
            end,
            S2;

        false ->
            State
    end.

node_down(Node, State) ->
    case is_peer(Node, State) of
        true ->
            case node_delete(Node) of
                [] ->
                    ok;
                AffectedServices ->
                    riak_core_node_watcher_events:service_update(AffectedServices)
            end;
        false ->
            ok
    end.


node_delete(Node) ->
    Services = internal_get_services(Node),
    [internal_delete(Node, Service) || Service <- Services],
    ets:delete(?MODULE, Node),
    Services.

node_update(Node, Services) ->
    %% Check the list of up services against what we already
    %% know and determine what's changed (if anything).
    Now = riak_core_util:moment(),
    NewStatus = ordsets:from_list(Services),
    OldStatus = ordsets:from_list(internal_get_services(Node)),

    Added     = ordsets:subtract(NewStatus, OldStatus),
    Deleted   = ordsets:subtract(OldStatus, NewStatus),

    %% Update ets table with changes; make sure to touch unchanged
    %% service with latest timestamp
    [internal_delete(Node, Ss) || Ss <- Deleted],
    [internal_insert(Node, Ss) || Ss <- Added],

    %% Keep track of the last time we recv'd data from a node
    ets:insert(?MODULE, {Node, Now}),

    %% Return the list of affected services (added or deleted)
    ordsets:union(Added, Deleted).

local_update(#state { status = down } = State) ->
    %% Ignore subsystem changes when we're marked as down
    State;
local_update(State) ->
    %% Update our local ETS table
    case node_update(node(), State#state.services) of
        [] ->
            %% No material changes; no local notification necessary
            ok;

        AffectedServices ->
            %% Generate a local notification about the affected services and
            %% also broadcast our status
            riak_core_node_watcher_events:service_update(AffectedServices)
    end,
    broadcast(State#state.peers, State).

local_delete(State) ->
    case node_delete(node()) of
        [] ->
            %% No services changed; no local notification required
            State;

        AffectedServices ->
            riak_core_node_watcher_events:service_update(AffectedServices)
    end,
    broadcast(State#state.peers, State).

peers_update(NewPeers, State) ->
    %% Identify what peers have been added and deleted
    Added   = ordsets:subtract(NewPeers, State#state.peers),
    Deleted = ordsets:subtract(State#state.peers, NewPeers),

    %% For peers that have been deleted, remove their entries from
    %% the ETS table; we no longer care about their status
    Services0 = (lists:foldl(fun(Node, Acc) ->
                                    S = node_delete(Node),
                                    S ++ Acc
                            end, [], Deleted)),
    Services = ordsets:from_list(Services0),

    %% Notify local parties if any services are affected by this change
    case Services of
        [] ->
            ok;
        _  ->
            riak_core_node_watcher_events:service_update(Services)
    end,

    %% Broadcast our current status to new peers
    broadcast(Added, State#state { peers = NewPeers }).

internal_delete(Node, Service) ->
    Svcs = internal_get_services(Node),
    ets:insert(?MODULE, {{by_node, Node}, Svcs -- [Service]}),
    Nds = internal_get_nodes(Service),
    ets:insert(?MODULE, {{by_service, Service}, Nds -- [Node]}).

internal_insert(Node, Service) ->
    %% Remove Service & node before adding: avoid accidental duplicates
    Svcs = internal_get_services(Node) -- [Service],
    ets:insert(?MODULE, {{by_node, Node}, [Service|Svcs]}),
    Nds = internal_get_nodes(Service) -- [Node],
    ets:insert(?MODULE, {{by_service, Service}, [Node|Nds]}).

internal_get_services(Node) ->
    case ets:lookup(?MODULE, {by_node, Node}) of
        [{{by_node, Node}, Ss}] ->
            Ss;
        [] ->
            []
    end.

internal_get_nodes(Service) ->
    case ets:lookup(?MODULE, {by_service, Service}) of
        [{{by_service, Service}, Ns}] ->
            Ns;
        [] ->
            []
    end.

handle_check_msg(_Msg, undefined, State) ->
    State;
handle_check_msg(Msg, ServiceId, State) ->
    case orddict:find(ServiceId, State#state.health_checks) of
        error ->
            State;
        {ok, Check} ->
            CheckReturn = health_fsm(Msg, ServiceId, Check),
            handle_check_return(CheckReturn, ServiceId, State)
    end.

handle_check_return(ok, ServiceId, State) ->
    Healths = orddict:erase(ServiceId, State#state.health_checks),
    State#state{health_checks = Healths};
handle_check_return({ok, Check}, ServiceId, State) ->
    Healths = orddict:store(ServiceId, Check, State#state.health_checks),
    State#state{health_checks = Healths};
handle_check_return({up, Check}, ServiceId, State) ->
    #health_check{service_pid = Pid} = Check,
    Healths = orddict:store(ServiceId, Check, State#state.health_checks),

    %% Update the set of active services locally
    Services = ordsets:add_element(ServiceId, State#state.services),
    S2 = State#state { services = Services },

    %% Remove any existing mrefs for this service
    delete_service_mref(ServiceId),

    %% Setup a monitor for the Pid representing this service
    Mref = erlang:monitor(process, Pid),
    erlang:put(Mref, ServiceId),
    erlang:put(ServiceId, Mref),

    %% Update our local ETS table and broadcast
    S3 = local_update(S2),
    update_avsn(S3#state{health_checks = Healths});
handle_check_return({down, Check}, ServiceId, State) ->
    Healths = orddict:store(ServiceId, Check, State#state.health_checks),

    %% Update the set of active services locally
    Services = ordsets:del_element(ServiceId, State#state.services),
    S2 = State#state { services = Services },

    %% Remove any existing mrefs for this service
    delete_service_mref(ServiceId),

    %% Update local ETS table and broadcast
    S3 = local_update(S2),

    update_avsn(S3#state{health_checks = Healths}).

%% health checks are an fsm to make mental modeling easier.
%% There are X states:
%% waiting:  in between check intervals
%% dormant:  Check interval disabled
%% checking: health check in progress
%% messages to handle:
%% go dormant
%% do a scheduled health check
%% remove health check
%% health check finished

%% message handling when in dormant state
health_fsm(disable, _Service, #health_check{check_interval = infinity} = InCheck) ->
    {ok, InCheck};

health_fsm(check_health, Service, #health_check{check_interval = infinity} = InCheck) ->
    InCheck1 = start_health_check(Service, InCheck),
    {ok, InCheck1};

health_fsm(remove, _Service, #health_check{check_interval = infinity} = InCheck) ->
    ok;

%health_fsm({'EXIT', _Pid, _Cause}, _Service, InCheck) ->
%    {ok, InCheck};

%% message handling when checking state
health_fsm(disable, _Service, #health_check{checking_pid = Pid} = InCheck) when is_pid(Pid) ->
    {ok, InCheck#health_check{checking_pid = undefined, check_interval = infinity}};

health_fsm(check_health, _Service, #health_check{checking_pid = Pid} = InCheck) when is_pid(Pid) ->
    {ok, InCheck};

health_fsm(remove, _Service, #health_check{checking_pid = Pid}) when is_pid(Pid) ->
    ok;

health_fsm({'EXIT', Pid, normal}, Service, #health_check{checking_pid = Pid, health_failures = N, max_health_failures = M} = InCheck) when N >= M ->
    Time = determine_time(0, InCheck#health_check.check_interval) * 1000,
    OutCheck = InCheck#health_check{
        checking_pid = undefined,
        health_failures = 0,
        callback_failures = 0,
        interval_tref = erlang:send_after(Time * 1000, self(), {check_health, Service})
    },
    {up, OutCheck};

health_fsm({'EXIT', Pid, normal}, Service, #health_check{checking_pid = Pid, health_failures = N, max_health_failures = M} = InCheck) when N < M ->
    Time = determine_time(N, InCheck#health_check.check_interval) * 1000,
    OutCheck = InCheck#health_check{
        checking_pid = undefined,
        health_failures = 0,
        callback_failures = 0,
        interval_tref = erlang:send_after(Time * 1000, self(), {check_health, Service})
    },
    {ok, OutCheck};

health_fsm({'EXIT', Pid, false}, Service, #health_check{health_failures = N, max_health_failures = M, checking_pid = Pid} = InCheck) when N + 1 == M ->
    Time = determine_time(N + 1, InCheck#health_check.check_interval),
    OutCheck = InCheck#health_check{
        checking_pid = undefined,
        health_failures = N + 1,
        callback_failures = 0,
        interval_tref = erlang:send_after(Time * 1000, self(), {check_health, Service})
    },
    {down, OutCheck};

health_fsm({'EXIT', Pid, false}, Service, #health_check{health_failures = N, max_health_failures = M, checking_pid = Pid} = InCheck) when N >= M ->
    Time = determine_time(N + 1, InCheck#health_check.check_interval),
    OutCheck = InCheck#health_check{
        checking_pid = undefined,
        health_failures = N + 1,
        callback_failures = 0,
        interval_tref = erlang:send_after(Time * 1000, self(), {check_health, Service})
    },
    {ok, OutCheck};

health_fsm({'EXIT', Pid, false}, Service, #health_check{health_failures = N, max_health_failures = M, checking_pid = Pid} = InCheck) ->
    Time = determine_time(N + 1, InCheck#health_check.check_interval),
    OutCheck = InCheck#health_check{
        checking_pid = undefined,
        health_failures = N + 1,
        callback_failures = 0,
        interval_tref = erlang:send_after(Time * 1000, self(), {check_health, Service})
    },
    {ok, OutCheck};

health_fsm({'EXIT', Pid, Cause}, Service, #health_check{checking_pid = Pid} = InCheck) ->
    lager:error("health check process for ~p error'ed:  ~p", [Service, Cause]),
    Fails = InCheck#health_check.callback_failures + 1,
    if
        Fails == InCheck#health_check.max_callback_failures ->
            lager:error("health check callback for ~p failed too many times, disabling.", [Service]),
            {ok, InCheck#health_check{checking_pid = undefined, callback_failures = Fails}};
        Fails < InCheck#health_check.max_callback_failures ->
            #health_check{health_failures = N, check_interval = Inter} = InCheck,
            Time = determine_time(N, Inter),
            Tref = erlang:send_after(Time * 1000, self(), {check_health, Service}),
            OutCheck = InCheck#health_check{checking_pid = undefined,
                callback_failures = Fails, interval_tref = Tref},
            {ok, OutCheck};
        true ->
            {ok, InCheck#health_check{checking_pid = undefined, callback_failures = Fails}}
    end;

%% message handling when in waiting state
health_fsm(disable, _Service, #health_check{interval_tref = Tref} = InCheck) ->
    erlang:cancel_timer(Tref),
    {ok, InCheck#health_check{interval_tref = undefined, check_interval = infinity}};

health_fsm(check_health, Service, InCheck) ->
    InCheck1 = start_health_check(Service, InCheck),
    {ok, InCheck1};

health_fsm(remove, _Service, #health_check{interval_tref = Tref}) ->
    erlang:cancel_timer(Tref),
    ok;

% fallthrough handling
health_fsm(Msg, _Service, Health) ->
    {ok, Health}.

start_health_check(Service, #health_check{checking_pid = undefined} = CheckRec) ->
    {Mod, Func, Args} = CheckRec#health_check.callback,
    Pid = CheckRec#health_check.service_pid,
    Tref = CheckRec#health_check.interval_tref,
    erlang:cancel_timer(Tref),
    CheckingPid = proc_lib:spawn_link(fun() ->
        case erlang:apply(Mod, Func, [Pid | Args]) of
            true -> ok;
            false -> exit(false);
            Else -> exit(Else)
        end
    end),
    erlang:put(CheckingPid, Service),
    CheckRec#health_check{checking_pid = CheckingPid, interval_tref = undefined};
start_health_check(_Service, Check) ->
    Check.

determine_time(Failures, BaseInterval) when Failures < 4 ->
    BaseInterval;

determine_time(Failures, BaseInterval) when Failures < 11 ->
    BaseInterval * (math:pow(Failures, 1.3));

determine_time(Failures, BaseInterval) when Failures > 10 ->
    BaseInterval * 20.
