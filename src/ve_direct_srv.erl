%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2015, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2015, Tony Rogvall
%%% @doc
%%%    Receive ve direct protocol items
%%% @end
%%% Created : 16 Oct 2015 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(ve_direct_srv).

-behaviour(gen_server).

-include_lib("lager/include/log.hrl").

%% API
-export([start_link/0]).
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_RETRY_INTERVAL, 2000).
-define(DEFAULT_BAUDRATE, 19200).

-record(s, 
	{
	  uart,            %% serial line port id
	  device,          %% device name
	  baud_rate,       %% baud rate to uart
	  retry_interval,  %% Timeout for open retry
	  retry_timer,     %% Timer reference for retry
	  dict,            %% Storage of last value
	  buf = <<>>       %% parse buffer
	}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    start_link([]).

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Opts0) ->
    Opts = Opts0 ++ application:get_all_env(ve_direct),
    RetryInterval = proplists:get_value(retry_interval,Opts,
					?DEFAULT_RETRY_INTERVAL),
    Device = case proplists:get_value(device, Opts) of
		 undefined -> os:getenv("VE_DIRECT_DEVICE");
		 D -> D
	     end,
    Baud = case proplists:get_value(baud, Opts) of
	       undefined ->
		   case os:getenv("VE_DIRECT_SPEED") of
		       false -> ?DEFAULT_BAUDRATE;
		       ""    -> ?DEFAULT_BAUDRATE;
		       Baud0 -> list_to_integer(Baud0)
		   end;
	       Baud1 -> Baud1
	   end,
    if Device =:= false; Device =:= "" ->
	    ?error("ve_direct: missing device argument"),
	    {stop, einval};
       true ->
	    S = #s{ device = Device,
		    baud_rate = Baud,
		    retry_interval = RetryInterval,
		    dict = dict:new()
		  },
	    ?info("ve_direct: using device ~s@~w\n", 
		  [Device, Baud]),
	    case open(S) of
		{ok, S1} -> {ok, S1};
		Error -> {stop, Error}
	    end
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({uart,U,Data}, S) when S#s.uart =:= U ->
    S1 = handle_input(<<(S#s.buf)/binary, Data/binary>>, S),
    uart:setopt(U, active, once),
    {noreply, S1};

handle_info({uart_error,U,Reason}, S) when U =:= S#s.uart ->
    if Reason =:= enxio ->
	    lager:error("ve_direct_srv: uart error ~p device ~s unplugged?", 
			[Reason,S#s.device]),
	    {noreply, reopen(S)};
       true ->
	    lager:error("ve_direct_srv: uart error ~p for device ~s", 
			[Reason,S#s.device]),
	    {noreply, S}
    end;

handle_info({uart_closed,U}, S) when U =:= S#s.uart ->
    lager:error("ve_direct_srv: uart device closed, will try again in ~p msecs.",
		[S#s.retry_interval]),
    S1 = reopen(S),
    {noreply, S1};

handle_info({timeout,TRef,reopen},S) when TRef =:= S#s.retry_timer ->
    case open(S#s { retry_timer = undefined }) of
	{ok, S1} ->
	    {noreply, S1};
	Error ->
	    {stop, Error, S}
    end;

handle_info(_Info, S) ->
    ?debug("ve_direct_srv: got info ~p", [_Info]),
    {noreply, S}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Input format:
%% \r\n<label>\t<value>
%% ...
%% \r\nChecksum\t<check>
%%
handle_input(Buffer, S) ->
    CheckField = <<"\r\nChecksum\t">>,
    case binary:split(Buffer, CheckField) of
	[Fields, <<Checksum,Buffer1/binary>>] ->
	    case checksum(Fields, checksum(CheckField,Checksum)) of
		0 ->
		    S1 = handle_fields(Fields, S),
		    S1#s { buf = Buffer1 };
		_I ->
		    ?error("ve_direct: checksum error"),
		    S#s { buf = Buffer1 }
	    end;
	_ ->
	    if byte_size(Buffer) > 2048 ->
		    %% maybe sync?
		    ?error("ve_direct: buffer to large, reset"),
		    reopen(S);
	       true ->
		    S#s { buf = Buffer }
	    end
    end.

handle_fields(Fields, S) ->
    handle_fields_(binary:split(Fields, <<"\r\n">>, [global]), S).

handle_fields_([<<>> | Fs], S) ->
    handle_fields_(Fs, S);
handle_fields_([F | Fs], S) ->
    case binary:split(F, <<"\t">>) of
	[Field, Value] ->
	    ?debug("~s = ~s\n", [Field, Value]),
	    %% FIXME: parse value and normalize!
	    Dict1 = dict:store(Field, Value, S#s.dict),
	    handle_fields(Fs, S#s { dict = Dict1 });
	_ ->
	    ?warning("bad field ~s", [F]),
	    handle_fields_(Fs, S)
    end;
handle_fields_([], S) ->
    S.

%% checksum(Bin) -> checksum(Bin, 0).

checksum(<<H,T/binary>>, Sum) -> checksum(T, Sum+H);
checksum(<<>>, Sum) -> Sum band 255.

open(S0=#s {device = DeviceName, baud_rate = Baud }) ->
    UartOpts = [{mode,binary}, {baud, Baud}, {packet, 0},
		{csize, 8}, {stopb,1}, {parity,none}, {active, once}],
    case uart:open(DeviceName, UartOpts) of
	{ok,Uart} ->
	    ?debug("ve_direct_srv:open: ~s@~w", [DeviceName,Baud]),
	    {ok, S0#s { uart = Uart }};
	{error,E} when E =:= eaccess; E =:= enoent ->
	    ?debug("ve_direct_srv:open: ~s@~w  error ~w, will try again "
		   "in ~p msecs.", [DeviceName,Baud,E,S0#s.retry_interval]),
	    {ok, reopen(S0)};
	Error ->
	    lager:error("ve_direct_srv: error ~w", [Error]),
	    Error
    end.

reopen(S) ->
    if S#s.uart =/= undefined ->
	    ?debug("ve_direct_srv: closing device ~s", [S#s.device]),
	    R = uart:close(S#s.uart),
	    ?debug("ve_direct_srv: closed ~p", [R]),
	    R;
       true ->
	    ok
    end,
    Timer = start_timer(S#s.retry_interval, reopen),
    S#s { uart=undefined, buf=(<<>>), retry_timer=Timer }.

start_timer(undefined, _Tag) ->
    undefined;
start_timer(infinity, _Tag) ->
    undefined;
start_timer(Time, Tag) ->
    erlang:start_timer(Time,self(),Tag).
