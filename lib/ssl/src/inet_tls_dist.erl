%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2011-2011. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%%
-module(inet_tls_dist).

-export([childspecs/0, listen/1, accept/1, accept_connection/5,
	 setup/5, close/1, select/1, is_node_name/1]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").

childspecs() ->
    {ok, [{ssl_dist_sup,{ssl_dist_sup, start_link, []},
	   permanent, 2000, worker, [ssl_dist_sup]}]}.

select(Node) ->
    case split_node(atom_to_list(Node), $@, []) of
	[_,_Host] -> 
	    true;
	_ -> 
	    false
    end.

is_node_name(Node) when is_atom(Node) ->
    select(Node);
is_node_name(_) ->
    false.

listen(Name) ->
    ssl_tls_dist_proxy:listen(Name).

accept(Listen) ->
    ssl_tls_dist_proxy:accept(Listen).

accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    Kernel = self(),
    spawn_link(fun() -> do_accept(Kernel, AcceptPid, Socket, 
				  MyNode, Allowed, SetupTime) end).

setup(Node, Type, MyNode, LongOrShortNames,SetupTime) ->
    Kernel = self(),
    spawn(fun() -> do_setup(Kernel, Node, Type, MyNode, LongOrShortNames, SetupTime) end).
		   
do_setup(Kernel, Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    [Name, Address] = splitnode(Node, LongOrShortNames),
    case inet:getaddr(Address, inet) of
	{ok, Ip} ->
	    Timer = dist_util:start_timer(SetupTime),
	    case erl_epmd:port_please(Name, Ip) of
		{port, TcpPort, Version} ->
		    ?trace("port_please(~p) -> version ~p~n", 
			   [Node,Version]),
		    dist_util:reset_timer(Timer),
		    case ssl_tls_dist_proxy:connect(Ip, TcpPort) of
			{ok, Socket} ->
			    HSData = connect_hs_data(Kernel, Node, MyNode, Socket, 
						     Timer, Version, Ip, TcpPort, Address,
						     Type),
			    dist_util:handshake_we_started(HSData);
			_ ->
			    %% Other Node may have closed since 
			    %% port_please !
			    ?trace("other node (~p) "
				   "closed since port_please.~n", 
				   [Node]),
			    ?shutdown(Node)
		    end;
		_ ->
		    ?trace("port_please (~p) "
			   "failed.~n", [Node]),
		    ?shutdown(Node)
	    end;
	_Other ->
	    ?trace("inet_getaddr(~p) "
		   "failed (~p).~n", [Node,Other]),
	    ?shutdown(Node)
    end.

close(Socket) ->
    try
	erlang:error(foo)
    catch _:_ ->
	    io:format("close called ~p ~p~n",[Socket, erlang:get_stacktrace()])
    end,
    gen_tcp:close(Socket),
    ok.

do_accept(Kernel, AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    process_flag(priority, max),
    receive
	{AcceptPid, controller} ->
	    Timer = dist_util:start_timer(SetupTime),
	    case check_ip(Socket) of
		true ->
		    HSData = accept_hs_data(Kernel, MyNode, Socket, Timer, Allowed),
		    dist_util:handshake_other_started(HSData);
		{false,IP} ->
		    error_logger:error_msg("** Connection attempt from "
					   "disallowed IP ~w ** ~n", [IP]),
		    ?shutdown(no_node)
	    end
    end.
%% ------------------------------------------------------------
%% Do only accept new connection attempts from nodes at our
%% own LAN, if the check_ip environment parameter is true.
%% ------------------------------------------------------------
check_ip(Socket) ->
    case application:get_env(check_ip) of
	{ok, true} ->
	    case get_ifs(Socket) of
		{ok, IFs, IP} ->
		    check_ip(IFs, IP);
		_ ->
		    ?shutdown(no_node)
	    end;
	_ ->
	    true
    end.

get_ifs(Socket) ->
    case ssl_prim:peername(Socket) of
	{ok, {IP, _}} ->
	    case ssl_prim:getif(Socket) of
		{ok, IFs} -> {ok, IFs, IP};
		Error     -> Error
	    end;
	Error ->
	    Error
    end.

check_ip([{OwnIP, _, Netmask}|IFs], PeerIP) ->
    case {mask(Netmask, PeerIP), mask(Netmask, OwnIP)} of
	{M, M} -> true;
	_      -> check_ip(IFs, PeerIP)
    end;
check_ip([], PeerIP) ->
    {false, PeerIP}.

mask({M1,M2,M3,M4}, {IP1,IP2,IP3,IP4}) ->
    {M1 band IP1,
     M2 band IP2,
     M3 band IP3,
     M4 band IP4};

mask({M1,M2,M3,M4, M5, M6, M7, M8}, {IP1,IP2,IP3,IP4, IP5, IP6, IP7, IP8}) ->
    {M1 band IP1,
     M2 band IP2,
     M3 band IP3,
     M4 band IP4,
     M5 band IP5,
     M6 band IP6,
     M7 band IP7,
     M8 band IP8}.


%% If Node is illegal terminate the connection setup!!
splitnode(Node, LongOrShortNames) ->
    case split_node(atom_to_list(Node), $@, []) of
	[Name|Tail] when Tail =/= [] ->
	    Host = lists:append(Tail),
	    check_node(Name, Node, Host, LongOrShortNames);
	[_] ->
	    error_logger:error_msg("** Nodename ~p illegal, no '@' character **~n",
		      [Node]),
	    ?shutdown(Node);
	_ ->
	    error_logger:error_msg("** Nodename ~p illegal **~n", [Node]),
	    ?shutdown(Node)
    end.

check_node(Name, Node, Host, LongOrShortNames) ->
    case split_node(Host, $., []) of
	[_] when LongOrShortNames == longnames ->
	    error_logger:error_msg("** System running to use "
		      "fully qualified "
		      "hostnames **~n"
		      "** Hostname ~s is illegal **~n",
		      [Host]),
	    ?shutdown(Node);
	[_, _ | _] when LongOrShortNames == shortnames ->
	    error_logger:error_msg("** System NOT running to use fully qualified "
			      "hostnames **~n"
		      "** Hostname ~s is illegal **~n",
		      [Host]),
	    ?shutdown(Node);
	_ ->
	    [Name, Host]
    end.

split_node([Chr|T], Chr, Ack) -> 
    [lists:reverse(Ack)|split_node(T, Chr, [])];
split_node([H|T], Chr, Ack) -> 
    split_node(T, Chr, [H|Ack]);
split_node([], _, Ack) -> 
    [lists:reverse(Ack)].

connect_hs_data(Kernel, Node, MyNode, Socket, Timer, Version, Ip, TcpPort, Address, Type) ->
    common_hs_data(Kernel, MyNode, Socket, Timer, 
		   #hs_data{other_node = Node,
			    other_version = Version,
			    f_address = 
				fun(_,_) ->
					#net_address{address = {Ip,TcpPort},
						     host = Address,
						     protocol = proxy,
						     family = inet}
				end,
			    request_type = Type
			   }).

accept_hs_data(Kernel, MyNode, Socket, Timer, Allowed) ->
    common_hs_data(Kernel, MyNode, Socket, Timer, #hs_data{
					     allowed = Allowed,
					     f_address = fun(S, N) -> 
								 ssl_tls_dist_proxy:get_remote_id(S, N)
							 end
					    }).

common_hs_data(Kernel, MyNode, Socket, Timer, HsData) ->
    HsData#hs_data{
      kernel_pid = Kernel,
      this_node = MyNode,
      socket = Socket,
      timer = Timer,
      this_flags = 0,
      f_send = 
	  fun(S,D) -> 
		  gen_tcp:send(S,D) 
	  end,
      f_recv = 
	  fun(S,N,T) -> 
		  gen_tcp:recv(S,N,T) 
	  end,
      f_setopts_pre_nodeup = 
	  fun(S) ->
		  inet:setopts(S, [{active, false}, {packet, 4}])
	  end,
		   f_setopts_post_nodeup = 
	  fun(S) -> 
		  inet:setopts(S, [{deliver, port},{active, true}])
	  end,
      f_getll = 
	  fun(S) -> 
		  inet:getll(S) 
	  end,
      mf_tick = 
	  fun(S) -> 
		  gen_tcp:send(S, <<>>)
	  end,
      mf_getstat = 
	  fun(S) ->
		  {ok, Stats} = inet:getstat(S, [recv_cnt, send_cnt, send_pend]),
		  R = proplists:get_value(recv_cnt, Stats, 0),
		  W = proplists:get_value(send_cnt, Stats, 0),
		  P = proplists:get_value(send_pend, Stats, 0),
		  {ok, R,W,P}
	  end}.