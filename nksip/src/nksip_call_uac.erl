%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
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

%% @doc Call UAC Management
-module(nksip_call_uac).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([request/4, response/2, cancel/2, timer/3]).
-export_type([status/0, id/0]).
-import(nksip_call_lib, [update/2, update_auth/2,
                         timeout_timer/3, retrans_timer/3, expire_timer/3, 
                         cancel_timers/2]).

-include("nksip.hrl").
-include("nksip_call.hrl").


-define(MAX_AUTH_TRIES, 5).


%% ===================================================================
%% Types
%% ===================================================================

-type status() :: invite_calling | invite_proceeding | invite_accepted |
                  invite_completed |
                  trying | proceeding | completed |
                  finished | ack.

-type id() :: integer().

-type trans() :: nksip_call:trans().

-type call() :: nksip_call:call().

-type uac_from() :: none | {srv, from()} | {fork, nksip_call_fork:id()}.



%% ===================================================================
%% Send Request
%% ===================================================================


%% @doc Starts a new UAC transaction.
-spec request(nksip:request(), nksip_lib:proplist(), uac_from(), call()) ->
    call().

request(Req, Opts, From, Call) ->
    #sipmsg{method=Method, id=MsgId} = Req,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    Req1 = case Method of 
        'CANCEL' -> Req;
        _ -> nksip_transport_uac:add_via(Req, GlobalId, AppOpts)
    end,
    {#trans{id=Id}=UAC, Call1} = new_uac(Req1, Opts, From, Call),
    case lists:member(async, Opts) andalso From of
        {srv, SrvFrom} when Method=:='ACK' -> 
            gen_server:reply(SrvFrom, async);
        {srv, SrvFrom} ->
            gen_server:reply(SrvFrom, {async, MsgId});
        _ ->
            ok
    end,
    case From of
        {fork, ForkId} ->
            ?call_debug("UAC ~p sending request ~p ~p (~s, fork: ~p)", 
                        [Id, Method, Opts, MsgId, ForkId], Call);
        _ ->
            ?call_debug("UAC ~p sending request ~p ~p (~s)", 
                        [Id, Method, Opts, MsgId], Call)
    end,
    do_send(Method, UAC, Call1).


%% @private
-spec new_uac(nksip:request(), nksip_lib:proplist(), uac_from(), call()) ->
    {trans(), call()}.

new_uac(Req, Opts, From, Call) ->
    #sipmsg{id=MsgId, method=Method, ruri=RUri} = Req, 
    #call{next=Id, trans=Trans, msgs=Msgs} = Call,
    Status = case Method of
        'ACK' -> ack;
        'INVITE'-> invite_calling;
        _ -> trying
    end,
    UAC = #trans{
        id = Id,
        class = uac,
        status = Status,
        start = nksip_lib:timestamp(),
        from = From,
        opts = Opts,
        trans_id = transaction_id(Req),
        request = Req,
        method = Method,
        ruri = RUri,
        response = undefined,
        code = 0,
        to_tags = [],
        cancel = undefined,
        iter = 1
    },
    Msg = {MsgId, Id, nksip_dialog:id(Req)},
    {UAC, Call#call{trans=[UAC|Trans], msgs=[Msg|Msgs], next=Id+1}}.



% @private
-spec do_send(nksip:method(), trans(), call()) ->
    call().

do_send('ACK', UAC, Call) ->
    #trans{id=Id, request=Req, opts=Opts} = UAC,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    case nksip_transport_uac:send_request(Req, GlobalId, Opts++AppOpts) of
       {ok, SentReq} ->
            ?call_debug("UAC ~p sent 'ACK' request", [Id], Call),
            Call1 = send_user_reply({req, SentReq}, UAC, Call),
            Call2 = case lists:member(no_dialog, Opts) of
                true -> Call1;
                false -> nksip_call_dialog_uac:ack(SentReq, Call1)
            end,
            Call3 = update_auth(SentReq, Call2),
            UAC1 = UAC#trans{status=finished, request=SentReq},
            update(UAC1, Call3);
        error ->
            ?call_debug("UAC ~p error sending 'ACK' request", [Id], Call),
            Call1 = send_user_reply({error, network_error}, UAC, Call),
            UAC1 = UAC#trans{status=finished},
            update(UAC1, Call1)
    end;

do_send(_, UAC, Call) ->
    #trans{method=Method, id=Id, request=Req, opts=Opts} = UAC,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    DialogResult = case lists:member(no_dialog, Opts) of
        true -> {ok, Call};
        false -> nksip_call_dialog_uac:request(Req, Call)
    end,
    case DialogResult of
        {ok, Call1} ->
            Send = case Method of 
                'CANCEL' -> nksip_transport_uac:resend_request(Req, Opts++AppOpts);
                _ -> nksip_transport_uac:send_request(Req, GlobalId, Opts++AppOpts)
            end,
            case Send of
                {ok, SentReq} ->
                    ?call_debug("UAC ~p sent ~p request", [Id, Method], Call),
                    Call2 = send_user_reply({req, SentReq}, UAC, Call1),
                    #sipmsg{transport=#transport{proto=Proto}} = SentReq,
                    Call3 = update_auth(SentReq, Call2),
                    UAC1 = UAC#trans{request=SentReq, proto=Proto},
                    UAC2 = sent_method(Method, UAC1, Call3),
                    update(UAC2, Call3);
                error ->
                    ?call_debug("UAC ~p error sending ~p request", 
                                [Id, Method], Call),
                    Call2 = send_user_reply({req, Req}, UAC, Call1),
                    {Resp, _} = nksip_reply:reply(Req, service_unavailable),
                    response(Resp, Call2)
            end;
        {error, finished} ->
            Call1 = send_user_reply({error, unknown_dialog}, UAC, Call),
            update(UAC#trans{status=finished}, Call1);
        {error, request_pending} ->
            Call1 = send_user_reply({error, request_pending}, UAC, Call),
            update(UAC#trans{status=finished}, Call1)
    end.


%% @private 
-spec sent_method(nksip:method(), trans(), call()) ->
    trans().

sent_method('INVITE', #trans{proto=Proto}=UAC, Call) ->
    UAC1 = expire_timer(expire, UAC#trans{status=invite_calling}, Call),
    UAC2 = timeout_timer(timer_b, UAC1, Call),
    case Proto of 
        udp -> retrans_timer(timer_a, UAC2, Call);
        _ -> UAC2
    end;

sent_method(_Other, #trans{proto=Proto}=UAC, Call) ->
    UAC1 = timeout_timer(timer_f, UAC#trans{status=trying}, Call),
    case Proto of 
        udp -> retrans_timer(timer_e, UAC1, Call);
        _ -> UAC1
    end.
    


%% ===================================================================
%% Receive response
%% ===================================================================


%% @doc Called when a new response is received.
-spec response(nksip:response(), call()) ->
    call().

response(Resp, #call{trans=Trans}=Call) ->
    #sipmsg{cseq_method=Method, response=Code} = Resp,
    TransId = transaction_id(Resp),
    case lists:keyfind(TransId, #trans.trans_id, Trans) of
        #trans{class=uac}=UAC -> 
            do_response(Resp, UAC, Call);
        _ -> 
            ?call_info("UAC received ~p ~p response for unknown request", 
                       [Method, Code], Call),
            Call
    end.


%% @private
-spec do_response(nksip:response(), trans(), call()) ->
    call().

do_response(Resp, UAC, Call) ->
    #sipmsg{id=MsgId, transport=Transport, response=Code} = Resp,
    #trans{
        id = Id, 
        start = Start, 
        status = Status,
        opts = Opts,
        method = Method,
        request = Req, 
        ruri = RUri
    } = UAC,
    #call{msgs=Msgs, opts=#call_opts{max_trans_time=MaxTime}} = Call,
    Now = nksip_lib:timestamp(),
    case Now-Start < MaxTime of
        true -> 
            Code1 = Code,
            Resp1 = Resp#sipmsg{ruri=RUri};
        false -> 
            Code1 = 408,
            {Resp1, _} = nksip_reply:reply(Req, {timeout, <<"Transaction Timeout">>})
    end,
    Call1 = case Code1>=200 andalso Code1<300 of
        true -> update_auth(Resp1, Call);
        false -> Call
    end,
    UAC1 = UAC#trans{response=Resp1, code=Code1},
    NoDialog = lists:member(no_dialog, Opts),
    case Transport of
        undefined -> 
            ok;    % It is own-generated
        _ -> 
            ?call_debug("UAC ~p ~p (~p) ~sreceived ~p", 
                        [Id, Method, Status, 
                         if NoDialog -> "(no dialog) "; true -> "" end, Code1], Call1)
    end,
    Call3 = case NoDialog of
        true -> update(UAC1, Call1);
        false -> nksip_call_dialog_uac:response(Req, Resp1, update(UAC1, Call1))
    end,
    Msg = {MsgId, Id, nksip_dialog:id(Resp)},
    Call4 = Call3#call{msgs=[Msg|Msgs]},
    do_response_status(Status, Resp1, UAC1, Call4).


%% @private
-spec do_response_status(status(), nksip:response(), trans(), call()) ->
    call().

do_response_status(invite_calling, Resp, UAC, Call) ->
    UAC1 = cancel_timers([retrans], UAC#trans{status=invite_proceeding}),
    do_response_status(invite_proceeding, Resp, UAC1, Call);

do_response_status(invite_proceeding, Resp, #trans{code=Code}=UAC, Call) 
                   when Code < 200 ->
    #trans{cancel=Cancel} = UAC,
    % Add another 3 minutes
    UAC1 = timeout_timer(timer_c, cancel_timers([timeout], UAC), Call),
    Call1 = send_user_reply({resp, Resp}, UAC1, Call),
    Call2 = update(UAC1, Call1),
    case Cancel of
        to_cancel -> cancel(UAC1, Call2);
        _ -> Call2
    end;

% Final 2xx response received
% Enters new RFC6026 'invite_accepted' state, to absorb 2xx retransmissions
% and forked responses
do_response_status(invite_proceeding, Resp, #trans{code=Code}=UAC, Call) 
                   when Code < 300 ->
    #sipmsg{to_tag=ToTag} = Resp,
    Call1 = send_user_reply({resp, Resp}, UAC, Call),
    UAC1 = cancel_timers([timeout, expire], UAC#trans{cancel=undefined}),
    UAC2 = UAC1#trans{
        status = invite_accepted, 
        response = undefined,       % Leave the request in case a new 2xx 
        to_tags = [ToTag]           % response is received
    },
    UAC3 = timeout_timer(timer_m, UAC2, Call),
    update(UAC3, Call1);


% Final [3456]xx response received, own error response
do_response_status(invite_proceeding, #sipmsg{transport=undefined}=Resp, UAC, Call) ->
    Call1 = send_user_reply({resp, Resp}, UAC, Call),
    UAC1 = cancel_timers([timeout, expire], UAC#trans{cancel=undefined}),
    update(UAC1#trans{status=finished}, Call1);


% Final [3456]xx response received, real response
do_response_status(invite_proceeding, Resp, UAC, Call) ->
    #sipmsg{to=To, to_tag=ToTag} = Resp,
    #trans{request=Req, proto=Proto} = UAC,
    UAC1 = cancel_timers([timeout, expire], UAC#trans{cancel=undefined}),
    Req1 = Req#sipmsg{to=To, to_tag=ToTag},
    UAC2 = UAC1#trans{request=Req1, response=undefined, to_tags=[ToTag]},
    send_ack(UAC2, Call),
    UAC3 = case Proto of
        udp -> timeout_timer(timer_d, UAC2#trans{status=invite_completed}, Call);
        _ -> UAC2#trans{status=finished}
    end,
    do_received_auth(Req, Resp, UAC3, update(UAC3, Call));


do_response_status(invite_accepted, _Resp, #trans{code=Code}, Call) 
                   when Code < 200 ->
    Call;

do_response_status(invite_accepted, Resp, UAC, Call) ->
    #sipmsg{to_tag=ToTag} = Resp,
    #trans{id=Id, code=Code, status=Status, to_tags=ToTags} = UAC,
    case ToTags of
        [ToTag|_] ->
            ?call_debug("UAC ~p (~p) received ~p retransmission",
                        [Id, Status, Code], Call),
            Call;
        _ ->
            do_received_hangup(Resp, UAC, Call)
    end;

do_response_status(invite_completed, Resp, UAC, Call) ->
    #sipmsg{to_tag=ToTag, response=RespCode} = Resp,
    #trans{id=Id, code=Code, to_tags=ToTags} = UAC,
    case ToTags of 
        [ToTag|_] ->
            case RespCode of
                Code ->
                    send_ack(UAC, Call);
                _ ->
                    ?call_info("UAC ~p (invite_completed) ignoring new ~p response "
                               "(previous was ~p)", [Id, RespCode, Code], Call)
            end,
            Call;
        _ ->  
            do_received_hangup(Resp, UAC, Call)
    end;

do_response_status(trying, Resp, UAC, Call) ->
    UAC1 = cancel_timers([retrans], UAC#trans{status=proceeding}),
    do_response_status(proceeding, Resp, UAC1, Call);

do_response_status(proceeding, #sipmsg{response=Code}=Resp, UAC, Call) 
                   when Code < 200 ->
    send_user_reply({resp, Resp}, UAC, Call);

% Final response received, own error response
do_response_status(proceeding, #sipmsg{transport=undefined}=Resp, UAC, Call) ->
    Call1 = send_user_reply({resp, Resp}, UAC, Call),
    UAC1 = cancel_timers([timeout], UAC#trans{status=finished}),
    update(UAC1, Call1);

% Final response received, real response
do_response_status(proceeding, Resp, UAC, Call) ->
    #sipmsg{to_tag=ToTag} = Resp,
    #trans{proto=Proto, request=Req} = UAC,
    UAC1 = cancel_timers([timeout], UAC),
    UAC3 = case Proto of
        udp -> 
            UAC2 = UAC1#trans{
                status = completed, 
                request = undefined, 
                response = undefined,
                to_tags = [ToTag]
            },
            timeout_timer(timer_k, UAC2, Call);
        _ -> 
            UAC1#trans{status=finished}
    end,
    do_received_auth(Req, Resp, UAC3, update(UAC3, Call));

do_response_status(completed, Resp, UAC, Call) ->
    #sipmsg{cseq_method=Method, response=Code, to_tag=ToTag} = Resp,
    #trans{id=Id, to_tags=ToTags} = UAC,
    case ToTags of
        [ToTag|_] ->
            ?call_info("UAC ~p ~p (completed) received ~p retransmission", 
                       [Id, Method, Code], Call),
            Call;
        _ ->
            ?call_info("UAC ~p ~p (completed) received new ~p response", 
                       [Id, Method, Code], Call),
            UAC1 = case lists:member(ToTag, ToTags) of
                true -> UAC;
                false -> UAC#trans{to_tags=ToTags++[ToTag]}
            end,
            update(UAC1, Call)
    end.


%% @private
-spec do_received_hangup(nksip:response(), trans(), call()) ->
    call().

do_received_hangup(Resp, UAC, Call) ->
    #sipmsg{id=_RespId, to_tag=ToTag} = Resp,
    #trans{id=Id, code=Code, status=Status, to_tags=ToTags} = UAC,
    #call{app_id=AppId} = Call,
    UAC1 = case lists:member(ToTag, ToTags) of
        true -> UAC;
        false -> UAC#trans{to_tags=ToTags++[ToTag]}
    end,
    DialogId = nksip_dialog:id(Resp),
    case Code < 300 of
        true ->
            ?call_info("UAC ~p (~p) sending ACK and BYE to secondary response " 
                       "(dialog ~s)", [Id, Status, DialogId], Call),
            spawn(
                fun() ->
                    case nksip_uac:ack(AppId, DialogId, []) of
                        ok ->
                            case nksip_uac:bye(AppId, DialogId, []) of
                                {ok, 200, []} ->
                                    ok;
                                ByeErr ->
                                    ?call_notice("UAC ~p could not send BYE: ~p", 
                                               [Id, ByeErr], Call)
                            end;
                        AckErr ->
                            ?call_notice("UAC ~p could not send ACK: ~p", 
                                       [Id, AckErr], Call)
                    end
                end);
        false ->       
            ?call_info("UAC ~p (~p) received new ~p response",
                        [Id, Status, Code], Call)
    end,
    update(UAC1, Call).


%% @private 
-spec do_received_auth(nksip:request(), nksip:response(), trans(), call()) ->
    call().

do_received_auth(Req, Resp, UAC, Call) ->
     #trans{
        id = Id,
        status = Status,
        opts = Opts,
        method = Method, 
        code = Code, 
        iter = Iter,
        from = From
    } = UAC,
    #call{opts=#call_opts{app_opts=AppOpts, global_id=GlobalId}} = Call,
    IsFork = case From of {fork, _} -> true; _ -> false end,
    case 
        (Code=:=401 orelse Code=:=407) andalso Iter < ?MAX_AUTH_TRIES
        andalso Method=/='CANCEL' andalso (not IsFork) andalso
        nksip_auth:make_request(Req, Resp, Opts++AppOpts) 
    of
        false ->
            send_user_reply({resp, Resp}, UAC, Call);
        {ok, #sipmsg{vias=[_|Vias]}=Req1} ->
            ?call_debug("UAC ~p ~p (~p) resending authorized request", 
                        [Id, Method, Status], Call),
            {CSeq, Call1} = nksip_call_dialog_uac:new_local_seq(Req, Call),
            Req2 = Req1#sipmsg{vias=Vias, cseq=CSeq},
            Req3 = nksip_transport_uac:add_via(Req2, GlobalId, AppOpts),
            Opts1 = nksip_lib:delete(Opts, make_contact),
            {NewUAC, Call2} = new_uac(Req3, Opts1, From, Call1),
            NewUAC1 = NewUAC#trans{iter=Iter+1},
            do_send(Method, NewUAC1, update(NewUAC1, Call2));
        {error, Error} ->
            ?call_debug("UAC ~p could not generate new auth request: ~p", 
                        [Id, Error], Call),    
            send_user_reply({resp, Resp}, UAC, Call)
    end.




%% ===================================================================
%% Cancel
%% ===================================================================


%% @doc Tries to cancel an ongoing invite request.
-spec cancel(id()|trans(), call()) ->
    call().

cancel(Id, #call{trans=Trans}=Call) when is_integer(Id) ->
    case lists:keyfind(Id, #trans.id, Trans) of
        #trans{class=uac, method='INVITE'} = UAC ->
            cancel(UAC, Call);
        _ -> 
            ?call_debug("UAC ~p not found to CANCEL", [Id], Call),
            Call
    end;

cancel(#trans{id=Id, class=uac, cancel=Cancel, status=Status}=UAC, Call)
       when Cancel=:=undefined; Cancel=:=to_cancel ->
    case Status of
        invite_calling ->
            ?call_debug("UAC ~p (invite_calling) delaying CANCEL", [Id], Call),
            UAC1 = UAC#trans{cancel=to_cancel},
            update(UAC1, Call);
        invite_proceeding ->
            ?call_debug("UAC ~p (invite_proceeding) generating CANCEL", [Id], Call),
            CancelReq = nksip_uac_lib:make_cancel(UAC#trans.request),
            UAC1 = UAC#trans{cancel=cancelled},
            request(CancelReq, [no_dialog], none, update(UAC1, Call))
    end;

cancel(#trans{id=Id, class=uac, cancel=Cancel, status=Status}, Call) ->
    ?call_debug("UAC ~p (~p) cannot CANCEL request: (~p)", [Id, Status, Cancel], Call),
    Call.





%% ===================================================================
%% Timers
%% ===================================================================


%% @private
-spec timer(nksip_call_lib:timer(), trans(), call()) ->
    call().

timer(timer_c, #trans{id=Id, request=Req}, Call) ->
    ?call_notice("UAC ~p 'INVITE' Timer C Fired", [Id], Call),
    {Resp, _} = nksip_reply:reply(Req, {timeout, <<"Timer C Timeout">>}),
    response(Resp, Call);

% INVITE retrans
timer(timer_a, UAC, Call) ->
    #trans{id=Id, request=Req, status=Status} = UAC,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    case nksip_transport_uac:resend_request(Req, Opts) of
        {ok, _} ->
            ?call_info("UAC ~p (~p) retransmitting 'INVITE'", [Id, Status], Call),
            UAC1 = retrans_timer(timer_a, UAC, Call),
            update(UAC1, Call);
        error ->
            ?call_notice("UAC ~p (~p) could not retransmit 'INVITE'", [Id, Status], Call),
            Reply = {service_unavailable, <<"Resend Error">>},
            {Resp, _} = nksip_reply:reply(Req, Reply),
            response(Resp, Call)
    end;

% INVITE timeout
timer(timer_b, #trans{id=Id, request=Req, status=Status}, Call) ->
    ?call_notice("UAC ~p 'INVITE' (~p) timeout (Timer B) fired", [Id, Status], Call),
    {Resp, _} = nksip_reply:reply(Req, {timeout, <<"Timer B Timeout">>}),
    response(Resp, Call);

% Finished in INVITE completed
timer(timer_d, #trans{id=Id, status=Status}=UAC, Call) ->
    ?call_debug("UAC ~p 'INVITE' (~p) Timer D fired", [Id, Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

% INVITE accepted finished
timer(timer_m,  #trans{id=Id, status=Status}=UAC, Call) ->
    ?call_debug("UAC ~p 'INVITE' (~p) Timer M fired", [Id, Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

% No INVITE retrans
timer(timer_e, UAC, Call) ->
    #trans{id=Id, status=Status, method=Method, request=Req} = UAC,
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    case nksip_transport_uac:resend_request(Req, Opts) of
        {ok, _} ->
            ?call_info("UAC ~p (~p) retransmitting ~p", [Id, Status, Method], Call),
            UAC1 = retrans_timer(timer_e, UAC, Call),
            update(UAC1, Call);
        error ->
            ?call_notice("UAC ~p (~p) could not retransmit ~p", 
                         [Id, Status, Method], Call),
            {Resp, _} = nksip_reply:reply(Req, {service_unavailable, <<"Resend Error">>}),
            response(Resp, Call)
    end;

% No INVITE timeout
timer(timer_f, #trans{id=Id, status=Status, method=Method, request=Req}, Call) ->
    ?call_notice("UAC ~p ~p (~p) timeout (Timer F) fired", [Id, Method, Status], Call),
    {Resp, _} = nksip_reply:reply(Req, {timeout, <<"Timer F Timeout">>}),
    response(Resp, Call);

% No INVITE completed finished
timer(timer_k,  #trans{id=Id, status=Status, method=Method}=UAC, Call) ->
    ?call_debug("UAC ~p ~p (~p) Timer K fired", [Id, Method, Status], Call),
    UAC1 = UAC#trans{status=finished, timeout_timer=undefined},
    update(UAC1, Call);

timer(expire, #trans{id=Id, status=Status}=UAC, Call) ->
    UAC1 = UAC#trans{expire_timer=undefined},
    if
        Status=:=invite_calling; Status=:=invite_proceeding ->
            ?call_debug("UAC ~p 'INVITE' (~p) Timer Expire fired, sending CANCEL", 
                        [Id, Status], Call),
            UAC2 = UAC1#trans{status=invite_proceeding},
            cancel(UAC2, update(UAC2, Call));
        true ->
            ?call_debug("UAC ~p 'INVITE' (~p) Timer Expire fired", [Id, Status], Call),
            update(UAC1, Call)
    end.




%% ===================================================================
%% Util
%% ===================================================================

send_user_reply({req, Req}, #trans{from={srv, From}, method='ACK', opts=Opts}, Call) ->
    Async = lists:member(async, Opts),
    Get = lists:member(get_request, Opts),
    if
        Async, Get -> fun_call({req, Req}, Opts);
        Async -> fun_call(ok, Opts);
        Get -> gen_server:reply(From, {req, Req});
        not Get -> gen_server:reply(From, ok)
    end,
    Call;

send_user_reply({req, Req}, #trans{from={srv, _From}, opts=Opts}, Call) ->
    case lists:member(get_request, Opts) of
        true -> fun_call({req, Req}, Opts);
        false ->  ok
    end,
    Call;


send_user_reply({resp, Resp}, #trans{from={srv, From}, opts=Opts}, Call) ->
    #sipmsg{response=Code} = Resp,
    Async = lists:member(async, Opts),
    if
        Code < 101 -> ok;
        Async -> fun_call(fun_response(Resp, Opts), Opts);
        Code < 200 -> fun_call(fun_response(Resp, Opts), Opts);
        Code >= 200 -> gen_server:reply(From, fun_response(Resp, Opts))
    end,
    Call;

send_user_reply({error, Error}, #trans{from={srv, From}, opts=Opts}, Call) ->
    case lists:member(async, Opts) of
        true -> fun_call({error, Error}, Opts);
        false -> gen_server:reply(From, {error, Error})
    end,
    Call;

send_user_reply({resp, Resp}, #trans{id=Id, from={fork, ForkId}}, Call) ->
    nksip_call_fork:response(ForkId, Id, Resp, Call);

send_user_reply(_Resp, _UAC, Call) ->
    Call.


%% @private
fun_call(Msg, Opts) ->
    case nksip_lib:get_value(callback, Opts) of
        Fun when is_function(Fun, 1) -> spawn(fun() -> Fun(Msg) end);
        _ -> ok
    end.


fun_response(#sipmsg{cseq_method=Method, response=Code}=Resp, Opts) ->
    case lists:member(get_response, Opts) of
        true ->
            {resp, Resp};
        false ->
            Fields0 = case Method of
                'INVITE' -> [{dialog_id, nksip_dialog:id(Resp)}];
                _ -> []
            end,
            Values = case nksip_lib:get_value(fields, Opts, []) of
                [] ->
                    Fields0;
                Fields when is_list(Fields) ->
                    Fields0 ++ lists:zip(Fields, nksip_sipmsg:fields(Resp, Fields));
                _ ->
                    Fields0
            end,
            {ok, Code, Values}
    end.


%% @private
-spec send_ack(trans(), call()) ->
    ok.

send_ack(#trans{request=Req, id=Id}, Call) ->
    #call{opts=#call_opts{app_opts=Opts}} = Call,
    Ack = nksip_uac_lib:make_ack(Req),
    case nksip_transport_uac:resend_request(Ack, Opts) of
        {ok, _} -> 
            ok;
        error -> 
            #sipmsg{app_id=AppId, call_id=CallId} = Ack,
            ?notice(AppId, CallId, "UAC ~p could not send non-2xx ACK", [Id])
    end.


%% @private
-spec transaction_id(nksip:request()) -> 
    integer().

transaction_id(#sipmsg{app_id=AppId, call_id=CallId, 
                cseq_method=Method, vias=[Via|_]}) ->
    Branch = nksip_lib:get_value(branch, Via#via.opts),
    erlang:phash2({AppId, CallId, Method, Branch}).
