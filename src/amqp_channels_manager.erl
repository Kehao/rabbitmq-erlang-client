%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

%% @private
-module(amqp_channels_manager).

-include("amqp_client.hrl").

-behaviour(gen_server).

-export([start_link/2, open_channel/3, set_channel_max/2, is_empty/1,
         num_channels/1, pass_frame/3, signal_connection_closing/3]).
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-record(state, {connection,
                channel_sup_sup,
                map_num_pa      = gb_trees:empty(), %% Number -> {Pid, AState}
                map_pid_num     = dict:new(),       %% Pid -> Number
                channel_max     = ?MAX_CHANNEL_NUMBER,
                closing         = false}).

%%---------------------------------------------------------------------------
%% Interface
%%---------------------------------------------------------------------------

start_link(Connection, ChSupSup) ->
    gen_server:start_link(?MODULE, [Connection, ChSupSup], []).

open_channel(ChMgr, ProposedNumber, InfraArgs) ->
    gen_server:call(ChMgr, {open_channel, ProposedNumber, InfraArgs}, infinity).

set_channel_max(ChMgr, ChannelMax) ->
    gen_server:cast(ChMgr, {set_channel_max, ChannelMax}).

is_empty(ChMgr) ->
    gen_server:call(ChMgr, is_empty, infinity).

num_channels(ChMgr) ->
    gen_server:call(ChMgr, num_channels, infinity).

pass_frame(ChMgr, ChNumber, Frame) ->
    gen_server:cast(ChMgr, {pass_frame, ChNumber, Frame}).

signal_connection_closing(ChMgr, ChannelCloseType, Reason) ->
    gen_server:cast(ChMgr, {connection_closing, ChannelCloseType, Reason}).

%%---------------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------------

init([Connection, ChSupSup]) ->
    {ok, #state{connection = Connection, channel_sup_sup = ChSupSup}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    State.

handle_call({open_channel, ProposedNumber, InfraArgs}, _,
            State = #state{closing = false}) ->
    handle_open_channel(ProposedNumber, InfraArgs, State);
handle_call(is_empty, _, State) ->
    {reply, internal_is_empty(State), State};
handle_call(num_channels, _, State) ->
    {reply, internal_num_channels(State), State}.

handle_cast({set_channel_max, ChannelMax}, State) ->
    {noreply, State#state{channel_max = ChannelMax}};
handle_cast({pass_frame, ChNumber, Frame}, State) ->
    {noreply, internal_pass_frame(ChNumber, Frame, State)};
handle_cast({connection_closing, ChannelCloseType, Reason}, State) ->
    handle_connection_closing(ChannelCloseType, Reason, State).

handle_info({'DOWN', _, process, Pid, Reason}, State) ->
    handle_down(Pid, Reason, State).

%%---------------------------------------------------------------------------
%% Internal plumbing
%%---------------------------------------------------------------------------

handle_open_channel(ProposedNumber, InfraArgs,
                    State = #state{channel_sup_sup = ChSupSup}) ->
    case new_number(ProposedNumber, State) of
        {ok, Number} ->
            {ok, _ChSup, {Ch, AState}} =
                amqp_channel_sup_sup:start_channel_sup(ChSupSup, InfraArgs,
                                                       Number),
            NewState = internal_register(Number, Ch, AState, State),
            erlang:monitor(process, Ch),
            {reply, {ok, Ch}, NewState};
        {error, _} = Error ->
            {reply, Error, State}
    end.

new_number(none, #state{channel_max = ChannelMax, map_num_pa = MapNPA}) ->
    case gb_trees:is_empty(MapNPA) of
        true  -> {ok, 1};
        false -> {Smallest, _} = gb_trees:smallest(MapNPA),
                 if Smallest > 1 ->
                        {ok, Smallest - 1};
                    true ->
                        {Largest, _} = gb_trees:largest(MapNPA),
                        if Largest < ChannelMax -> {ok, Largest + 1};
                           true                 -> find_free(MapNPA)
                        end
                 end
    end;
new_number(Proposed, State = #state{channel_max = ChannelMax,
                                    map_num_pa  = MapNPA}) ->
    IsValid = Proposed > 0 andalso Proposed =< ChannelMax andalso
        not gb_trees:is_defined(Proposed, MapNPA),
    case IsValid of true  -> {ok, Proposed};
                    false -> new_number(none, State)
    end.

find_free(MapNPA) ->
    find_free(gb_trees:iterator(MapNPA), 1).

find_free(It, Candidate) ->
    case gb_trees:next(It) of
        {Number, _, It1} -> if Number > Candidate ->
                                   {ok, Number - 1};
                               Number =:= Candidate ->
                                   find_free(It1, Candidate + 1)
                            end;
        none             -> {error, out_of_channel_numbers}
    end.

handle_down(Pid, Reason, State) ->
    case internal_lookup_pn(Pid, State) of
        undefined -> {stop, {error, unexpected_down}, State};
        Number    -> handle_channel_down(Pid, Number, Reason, State)
    end.

handle_channel_down(Pid, Number, Reason, State) ->
    maybe_report_down(Pid, Reason, State),
    NewState = internal_unregister(Number, Pid, State),
    check_all_channels_terminated(NewState),
    {noreply, NewState}.

maybe_report_down(_Pid, normal, _State) ->
    ok;
maybe_report_down(_Pid, {app_initiated_close, _, _}, _State) ->
    ok;
maybe_report_down(_Pid, {server_initiated_close, _, _}, _State) ->
    ok;
maybe_report_down(Pid, {connection_closing,
                        {server_initiated_hard_close, _, _} = Reason},
                  #state{connection = Connection}) ->
    amqp_gen_connection:hard_error_in_channel(Connection, Pid, Reason);
maybe_report_down(_Pid, {connection_closing, _}, _State) ->
    ok;
maybe_report_down(_Pid, {server_misbehaved, AmqpError},
                  #state{connection = Connection}) ->
    amqp_gen_connection:server_misbehaved(Connection, AmqpError);
maybe_report_down(Pid, Other, #state{connection = Connection}) ->
    amqp_gen_connection:channel_internal_error(Connection, Pid, Other).

check_all_channels_terminated(#state{closing = false}) ->
    ok;
check_all_channels_terminated(State = #state{closing = true,
                                             connection = Connection}) ->
    case internal_is_empty(State) of
        true  -> amqp_gen_connection:channels_terminated(Connection);
        false -> ok
    end.

handle_connection_closing(ChannelCloseType, Reason,
                          State = #state{connection = Connection}) ->
    case internal_is_empty(State) of
        true  -> amqp_gen_connection:channels_terminated(Connection);
        false -> signal_channels_connection_closing(ChannelCloseType, Reason,
                                                    State)
    end,
    {noreply, State#state{closing = true}}.

%%---------------------------------------------------------------------------

internal_pass_frame(Number, Frame, State) ->
    case internal_lookup_npa(Number, State) of
        undefined ->
            ?LOG_INFO("Dropping frame ~p for invalid or closed "
                      "channel number ~p~n", [Frame, Number]);
        {ChPid, AState} ->
            NewAState = rabbit_reader:process_channel_frame(
                          Frame, ChPid, Number, ChPid, AState),
            internal_update_npa(Number, ChPid, NewAState, State)
    end.

internal_register(Number, Pid, AState,
                  State = #state{map_num_pa = MapNPA, map_pid_num = MapPN}) ->
    MapNPA1 = gb_trees:enter(Number, {Pid, AState}, MapNPA),
    MapPN1 = dict:store(Pid, Number, MapPN),
    State#state{map_num_pa  = MapNPA1,
                map_pid_num = MapPN1}.

internal_unregister(Number, Pid,
                    State = #state{map_num_pa = MapNPA, map_pid_num = MapPN}) ->
    MapNPA1 = gb_trees:delete(Number, MapNPA),
    MapPN1 = dict:erase(Pid, MapPN),
    State#state{map_num_pa  = MapNPA1,
                map_pid_num = MapPN1}.

internal_is_empty(#state{map_num_pa = MapNPA}) ->
    gb_trees:is_empty(MapNPA).

internal_num_channels(#state{map_num_pa = MapNPA}) ->
    gb_trees:size(MapNPA).

internal_lookup_npa(Number, #state{map_num_pa = MapNPA}) ->
    case gb_trees:lookup(Number, MapNPA) of {value, PA} -> PA;
                                            none        -> undefined
    end.

internal_lookup_pn(Pid, #state{map_pid_num = MapPN}) ->
    case dict:find(Pid, MapPN) of {ok, Number} -> Number;
                                  error        -> undefined
    end.

internal_update_npa(Number, Pid, AState, State = #state{map_num_pa = MapNPA}) ->
    State#state{map_num_pa = gb_trees:update(Number, {Pid, AState}, MapNPA)}.

signal_channels_connection_closing(ChannelCloseType, Reason,
                                   #state{map_pid_num = MapPN}) ->
    [amqp_channel:connection_closing(Pid, ChannelCloseType, Reason)
        || Pid <- dict:fetch_keys(MapPN)].
