%%%  This code was developped by Mickael Remond
%%%  <mickael.remond@erlang-fr.org> and contributors (their names can
%%%  be found in the CONTRIBUTORS file).  Copyright (C) 2003 Mickael
%%%  Remond
%%%
%%%  This program is free software; you can redistribute it and/or modify
%%%  it under the terms of the GNU General Public License as published by
%%%  the Free Software Foundation; either version 2 of the License, or
%%%  (at your option) any later version.
%%%
%%%  This program is distributed in the hope that it will be useful,
%%%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%  GNU General Public License for more details.
%%%
%%%  You should have received a copy of the GNU General Public License
%%%  along with this program; if not, write to the Free Software
%%%  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
%%% 

%%%  Created :  23 Dec 2003 by Mickael Remond <mickael.remond@erlang-fr.org>

%%----------------------------------------------------------------------
%% HEADER ts_os_mon
%% COPYRIGHT Mickael Remond (C) 2003
%% PURPOSE Monitor CPU, memory consumption and network traffic 
%%         on a cluster of machines
%% DESCRIPTION
%%   TODO ...
%%----------------------------------------------------------------------
%%%  In addition, as a special exception, you have the permission to
%%%  link the code of this program with any library released under
%%%  the EPL license and distribute linked combinations including
%%% the two.

-module(ts_os_mon).
-author('mickael.remond@erlang-fr.org').
-modifiedby('nicolas@niclux.org').
-vc('$Id$ ').

-behaviour(gen_server).


%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("ts_profile.hrl").

%% two types of monotoring: snmp or using an erlang agent
-record(state, {erlang_pids=[], snmp_pids=[], timer,
                interval,  % get data every 'interval' msec, default
                           % value is ?INTERVAL
                mon_server,% monitoring server to which every data is
                           % sent to (can be a pid or a registered
                           % process )
                dnscache=[]
               }).

-include_lib("snmp/include/snmp_types.hrl").

%%--------------------------------------------------------------------
%% External exports
-export([start/0, start/1, stop/0, activate/0, updatestats/2]).
-export([client_start/0]).
-export([node_data/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ts_os_mon).
-define(NODE, "os_mon").
-define(OTP_TIMEOUT, infinity).
-define(TIMEOUT, 30000).
-define(OPTIONS, [{timeout,?TIMEOUT}]).
-define(INTERVAL, 10000).


%% SNMP definitions
%% FIXME: make this customizable in the XML config file

-define(SNMP_PORT, 161).
-define(SNMP_COMMUNITY, "public").

-define(SNMP_CPU_RAW_USER, [1,3,6,1,4,1,2021,11,50,0]).
-define(SNMP_CPU_RAW_SYSTEM, [1,3,6,1,4,1,2021,11,52,0]).
-define(SNMP_CPU_RAW_IDLE, [1,3,6,1,4,1,2021,11,53,0]).

-define(SNMP_MEM_BUFFER, [1,3,6,1,4,1,2021,4,14,0]).
-define(SNMP_MEM_CACHED, [1,3,6,1,4,1,2021,4,15,0]).
-define(SNMP_MEM_AVAIL, [1,3,6,1,4,1,2021,4,6,0]).
-define(SNMP_MEM_TOTAL, [1,3,6,1,4,1,2021,4,5,0]).

%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: activate/0
%% Purpose: This is used by tsung to start the cluster monitor service
%% It will only be started if there are cluster/monitor@host element
%% in the config file.
%%--------------------------------------------------------------------
activate() ->
    case ts_config_server:get_monitor_hosts() of
    	[] ->
           ?LOG("os_mon disabled",?NOTICE),
            ok;
        Hosts ->
            gen_server:cast(?SERVER, {activate, Hosts})
    end.

%%--------------------------------------------------------------------
%% Function: start/1
%% Description: Starts the server, with a list of the hosts in the
%%              cluster to monitor
%%--------------------------------------------------------------------
start() ->
    ?LOG("starting os_mon",?NOTICE),
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], ?OPTIONS).

start(Args) ->
    ?LOGF("starting os_mon with args ~p",[Args],?NOTICE),
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, ?OPTIONS).

%%--------------------------------------------------------------------
%% Function: stop/0
%% Description: Stop the server
%%--------------------------------------------------------------------
stop() ->
    gen_server:call(?SERVER, {stop}, ?OTP_TIMEOUT).

%%--------------------------------------------------------------------
%% Function: client_start/0
%% Purpose: Start the monitor tools on the node that you want to spy on
%%--------------------------------------------------------------------
client_start() ->
    application:start(stdlib),
    application:start(sasl),
    application:start(os_mon).

%%--------------------------------------------------------------------
%% Function: updatestats/2
%% Purpose: update stats for erlang monitoring
%%--------------------------------------------------------------------
updatestats(Interval,Mon_Server) ->
    Node = atom_to_list(node()),
    {Cpu, FreeMem, RecvPackets, SentPackets} = node_data(),
    send(Mon_Server,[{sample, {cpu, Node}, Cpu},
				{sample, {freemem, Node}, FreeMem},
				{sample_counter, {recvpackets, Node}, RecvPackets},
				{sample_counter, {sentpackets,  Node}, SentPackets}]),

    timer:sleep(Interval),
    updatestats(Interval,Mon_Server).


%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%%--------------------------------------------------------------------
init({Mon_Server, Interval}) ->
    ?LOG(" os_mon started",?NOTICE),
    %% to get the EXIT signal from spawn processes on remote nodes
	process_flag(trap_exit,true), 
	{ok, #state{mon_server=Mon_Server, interval=Interval}};
init(_) ->
    ?LOG(" os_mon started",?NOTICE),
    %% to get the EXIT signal from spawn processes on remote nodes
	process_flag(trap_exit,true), 
	{ok, #state{mon_server={global, ts_mon}, interval=?INTERVAL}}.

%%--------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_call({stop}, _From, State) ->
    {stop, normal, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_cast({activate, Hosts}, State) ->
    NewState = active_host(Hosts,State),
    {noreply, NewState};

handle_cast(Msg, State) ->
    ?LOGF("handle cast: unknown msg ~p~n",[Msg],?WARN),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------
handle_info({timeout, _Ref, send_snmp_request},  State ) ->
    node_data(snmp, State),
    {noreply, State#state{timer=undefined}};

% response from the SNMP server    
handle_info({snmp_msg, Msg, Ip, _Udp}, State) ->
    PDU = snmp_mgr_misc:get_pdu(Msg),
    NewCache = case PDU#pdu.type of 
                   'get-response' ->
                       ?LOGF("Got SNMP PDU ~p from ~p~n",[PDU, Ip],?DEB),
                       {Hostname, Cache2} = ts_utils:resolve(Ip, State#state.dnscache),
                       analyse_snmp_data(PDU#pdu.varbinds, Hostname, State),
                       Cache2;
                   _ ->
                       ?LOGF("Got unknown SNMP data ~p from ~p~n",[PDU, Ip],?WARN),
                       State#state.dnscache   
               end,
    case  State#state.timer of 
        undefined ->
            erlang:start_timer(State#state.interval, self(), send_snmp_request ),
            {noreply, State#state{timer=on, dnscache=NewCache}};
        _ ->
            {noreply, State#state{dnscache=NewCache}}
    end;

handle_info({'EXIT', From, Reason}, State) ->
	?LOGF("received exit from ~p with reason ~p~n",[From, Reason],?ERR),
	%% get node name of died pid
	case lists:keysearch(From,1,State#state.erlang_pids) of 
		{value, {From, Node}} ->
			%% start a new process on this node
			Pid = spawn_link(Node, ?MODULE, updatestats, [State#state.interval, State#state.mon_server]),
			%% replace the pid value
			NewPids = lists:keyreplace(From,1,State#state.erlang_pids,{Pid, Node}),
			{noreply, State#state{erlang_pids=NewPids}};
		false -> %% the EXIT is not from a stats pid, do nothing 
			?LOGF("unknown exit from ~p !~n",[From],?WARN),
			{noreply, State}
	end;
handle_info(Info, State) ->
	?LOGF("handle info: unknown msg ~p~n",[Info],?WARN),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(normal, #state{erlang_pids=Nodes}) ->
    ?LOGF("Terminating ts_os_mon, stop beams: ~p~n",[Nodes],?NOTICE),
    stop_beam(Nodes),    
    ok;
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Func: node_data/0
%%--------------------------------------------------------------------
node_data() ->
    {RecvPackets, SentPackets} = get_os_data(packets),
    {get_os_data(cpu), get_os_data(freemem), RecvPackets, SentPackets}.

%%--------------------------------------------------------------------
%% Func: node_data/2
%%--------------------------------------------------------------------
node_data(snmp, #state{snmp_pids=Pids}) ->
    node_data(snmp,Pids);
node_data(snmp, [])->
    ok;
node_data(snmp, [Pid|List]) when is_pid(Pid)->
    snmp_get(Pid, [?SNMP_CPU_RAW_SYSTEM, ?SNMP_CPU_RAW_USER, ?SNMP_MEM_AVAIL ]),
    node_data(snmp, List).

%%--------------------------------------------------------------------
%% Func: get_os_data/1
%%--------------------------------------------------------------------
%% Return node cpu utilisation
get_os_data(cpu) -> cpu_sup:util();

%% Return node cpu average load on 1 minute; unused !
get_os_data(cpu1) -> cpu_sup:avg1()/256;

get_os_data(DataName) -> get_os_data(DataName,os:type()).
        
%%--------------------------------------------------------------------
%% Func: get_os_data/2
%%--------------------------------------------------------------------
%% Return free memory in bytes.
%% Use the result of the free commands on Linux and os_mon on all
%% other platforms
get_os_data(freemem, {unix, linux}) ->
    Result = os:cmd("free | grep '\\-/\\+'"),
    [_, _, _, Free] = string:tokens(Result, " \n"),
    list_to_integer(Free)/1024;
get_os_data(freemem, {unix, sunos}) ->
    Result = os:cmd("vmstat 1 2 | tail -1"),
    [_, _, _, _, Free | _] = string:tokens(Result, " "),
    list_to_integer(Free)/1024;
get_os_data(freemem, _OS) ->
    Data = memsup:get_system_memory_data(),
    {value,{free_memory,FreeMem}} = lists:keysearch(free_memory, 1, Data),
    %% We use Megabytes
    FreeMem/1048576;

%% Return packets sent/received on network interface
get_os_data(packets, {unix, linux}) ->
	%% get the cumulative traffic of all ethX interfaces
    {ok, Lines} = ts_utils:file_to_list("/proc/net/dev"),
    Eth = [io_lib:fread("~6s:~d~d~d~d~d~d~d~d~d~d", X) || X<-Lines, string:str(X,"eth") /= 0],
    Fun = fun (A, {Rcv, Sent}) ->
                  {ok,[_,_RcvBytes,RcvPkt,_,_,_,_,_,_,_SentBytes,SentPkt],_}=A,
                  {Rcv+RcvPkt,Sent+SentPkt}
          end,
    lists:foldl(Fun, {0,0}, Eth);

%% solaris, contributed by Jason Tucker
get_os_data(packets, {unix, sunos}) ->
    Result = os:cmd("netstat -in 1 1 | tail -1"),
    [_, _, _, _, _, RecvPackets, _, SentPackets | _] = string:tokens(Result, " "),
    {list_to_integer(RecvPackets), list_to_integer(SentPackets)};

get_os_data(packets, _OS) ->
    {0, 0 }. % FIXME: not implemented for other arch.


%%--------------------------------------------------------------------
%% Function: start_beam/1
%% Purpose: Start an Erlang node on given host
%%--------------------------------------------------------------------
start_beam(Host) ->
	Args = ts_utils:erl_system_args(),
    ?LOGF("starting os_mon beam (~p) on host ~p with Args ~p~n",
          [?NODE,Host, Args], ?INFO), 
    {ok, Node} = slave:start_link(Host, ?NODE, Args),
   ?LOGF("started os_mon newbeam on node ~p~n", [Node], ?INFO),
    {ok, Node}.

%%--------------------------------------------------------------------
%% Function: stop_beam/1
%%--------------------------------------------------------------------
stop_beam([]) ->
    ok;
stop_beam([{_Pid, Node}|Nodes]) ->
    ?LOGF("stopping os_mon beam on node ~p~n", [Node], ?INFO),
    rpc:cast(Node, erlang, halt, []),
    stop_beam(Nodes).

%%--------------------------------------------------------------------
%% Function: load_code/1
%% Purpose: Load ts_os_mon code on all Erlang nodes
%%--------------------------------------------------------------------
load_code(Nodes) ->
    ?LOGF("loading tsung monitor on nodes ~p~n", [Nodes], ?NOTICE),
    LoadCode = fun(Mod)-> 
                       {_, Binary, _} = code:get_object_code(Mod),
                       rpc:multicall(Nodes, code, load_binary, [Mod, Mod, Binary], infinity)
               end,
    LoadRes = lists:map(LoadCode, [ts_mon, ?MODULE, ts_utils]),
    Res = rpc:multicall(Nodes, ?MODULE, client_start, [], infinity),
    %% first value of load call is garbage
    ?LOGF("load_code: ~p start: ~p ~n", [LoadRes, Res],?DEB),
    ok.

%%--------------------------------------------------------------------
%% Function: active_host/2
%% Purpose: Activate monitoring
%%--------------------------------------------------------------------
active_host([], State) ->
    State;
%% monitoring using snmp
active_host([{HostStr, snmp} | HostList], State=#state{snmp_pids=PidList}) ->
    {ok, Host} = inet:getaddr(HostStr, inet),
    ?LOGF("Starting SNMP mgr on ~p~n", [Host], ?DEB),
    {ok, Pid} = snmp_mgr:start_link([{agent, Host},
                                     {agent_udp, ?SNMP_PORT},
                                     {community, ?SNMP_COMMUNITY},
                                     {receive_type, msg},
                                     quiet
                                    ]),
    %% since snmp_mgr can handle only a single snmp server, change the
    %% registered name to start several smp_mgr at once !
    unregister(snmp_mgr),
    ?LOGF("SNMP mgr started; remote node is ~p~n", [Host],?INFO),
    node_data(snmp, [Pid]),
    active_host(HostList, State#state{snmp_pids=[Pid|PidList]});

%% monitoring using a remote erlang node
active_host([{Host, erlang}| HostList], State=#state{erlang_pids=PidList}) ->
	%% because the stats for cpu has to be called from the same
	%% process (otherwise the same value (mean cpu% since the system
	%% last boot)  is returned by cpu_sup:util), we spawn a process
	%% that will do the stats collection and send it to ts_mon
    {ok, LocalHost} = ts_utils:node_to_hostname(node()),
    {Pid, RemNode} = case list_to_atom(LocalHost) of
              Host -> % same host, don't start a new beam
                  { spawn_link(?MODULE, updatestats, [State#state.interval, State#state.mon_server]), node()};
              _ ->
                  {ok, Node} = start_beam(Host),
                  Pong= net_adm:ping(Node),
                  ?LOGF("ping ~p: ~p~n", [Node, Pong],?INFO),
                  load_code([Node]),
                  { spawn_link(Node, ?MODULE, updatestats, [State#state.interval, State#state.mon_server]),
                    Node }
          end,
    active_host(HostList, State#state{erlang_pids=[{Pid, RemNode}|PidList]}).

%%--------------------------------------------------------------------
%% Function: analyse_snmp_data/3
%% Returns: any (send msg to ts_mon)
%%--------------------------------------------------------------------
analyse_snmp_data(Args, Host, State) ->
    analyse_snmp_data(Args, Host, [], State).

%% Function: analyse_snmp_data/4
analyse_snmp_data([], _Host, Resp, State) ->
    send(State#state.mon_server,Resp);

analyse_snmp_data([Val=#varbind{value='NULL'}| Tail], Host, Stats, State) ->
    ?LOGF("SNMP: Skip void result (~p) ~n", [Val],?DEB),
    analyse_snmp_data(Tail, Host, Stats, State);

%% FIXME: this may not be accurate: if we lost packets (the server is
%% overloaded), the value will be inconsistent, since we assume a
%% constant time across samples ($INTERVAL)

analyse_snmp_data([#varbind{oid=?SNMP_CPU_RAW_SYSTEM, value=Val}| Tail], Host, Stats, State) ->
    {value, User} = lists:keysearch(?SNMP_CPU_RAW_USER, #varbind.oid, Tail),
    Value = Val + User#varbind.value,
    CountName = {cpu , Host},
    NewValue = Value/(State#state.interval/1000),
    NewTail = lists:keydelete(?SNMP_CPU_RAW_USER, #varbind.oid, Tail),
    analyse_snmp_data(NewTail, Host, [{sample_counter, CountName, NewValue}| Stats], State);

analyse_snmp_data([User=#varbind{oid=?SNMP_CPU_RAW_USER}| Tail], Host, Stats, State) ->
    %%put this entry at the end, this will be used when SYSTEM match
    analyse_snmp_data(Tail ++ [User], Host, Stats, State);

analyse_snmp_data([#varbind{oid=OID, value=Val}| Tail], Host, Stats, State) ->
    {Type, Name, Value}= oid_to_statname(OID, Host, Val),
    ?LOGF("Analyse SNMP: ~p:~p:~p ~n", [Type, Name, Value],?DEB),
   analyse_snmp_data(Tail, Host, [{Type, Name, Value}| Stats], State).

%%--------------------------------------------------------------------
%% Function: oid_to_statname/3
%%--------------------------------------------------------------------
oid_to_statname(?SNMP_CPU_RAW_IDLE, Name, Value) ->
    CountName = {cpu_idle, Name},
    ?DebugF("Adding counter value for ~p~n",[CountName]),
    {sample_counter, CountName, Value/(?INTERVAL/1000)};
oid_to_statname(?SNMP_MEM_AVAIL, Name, Value)-> 
    CountName = {freemem, Name},
    ?DebugF("Adding counter value for ~p~n",[CountName]),
    {sample,CountName, Value/1000}.
    
%%--------------------------------------------------------------------
%% Function: snmp_get/2
%% Description: ask a list of OIDs to the given snmp_mgr
%%--------------------------------------------------------------------
snmp_get(Pid, Oids) ->
    ?DebugF("send snmp get for oid ~p to pid ~p ",[Oids,Pid]),
    Pid ! {get, Oids}, ok.

%%% send data back to the controlling node
send(Mon_Server, Data) when is_pid(Mon_Server) ->
    Mon_Server ! {add, Data};
send(Mon_Server, Data) ->
    gen_server:cast(Mon_Server, {add, Data}).
