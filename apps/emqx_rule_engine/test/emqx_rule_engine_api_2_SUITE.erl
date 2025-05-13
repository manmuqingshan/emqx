%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_rule_engine_api_2_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("emqx/include/asserts.hrl").

-import(emqx_common_test_helpers, [on_exit/1]).

%%------------------------------------------------------------------------------
%% CT boilerplate
%%------------------------------------------------------------------------------

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start(
        app_specs(),
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    Apps = ?config(apps, Config),
    ok = emqx_cth_suite:stop(Apps),
    ok.

app_specs() ->
    [
        emqx_conf,
        emqx_rule_engine,
        emqx_management,
        emqx_mgmt_api_test_util:emqx_dashboard()
    ].

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    emqx_common_test_helpers:call_janitor(),
    ok.

%%------------------------------------------------------------------------------
%% Helper fns
%%------------------------------------------------------------------------------

maybe_json_decode(X) ->
    case emqx_utils_json:safe_decode(X) of
        {ok, Decoded} -> Decoded;
        {error, _} -> X
    end.

request(Method, Path, Params) ->
    Opts = #{return_all => true},
    request(Method, Path, Params, Opts).

request(Method, Path, Params, Opts) ->
    request(Method, Path, Params, _QueryParams = [], Opts).

request(Method, Path, Params, QueryParams0, Opts) when is_list(QueryParams0) ->
    AuthHeader = emqx_mgmt_api_test_util:auth_header_(),
    QueryParams = uri_string:compose_query(QueryParams0, [{encoding, utf8}]),
    case emqx_mgmt_api_test_util:request_api(Method, Path, QueryParams, AuthHeader, Params, Opts) of
        {ok, {Status, Headers, Body0}} ->
            Body = maybe_json_decode(Body0),
            {ok, {Status, Headers, Body}};
        {error, {Status, Headers, Body0}} ->
            Body =
                case emqx_utils_json:safe_decode(Body0) of
                    {ok, Decoded0 = #{<<"message">> := Msg0}} ->
                        Msg = maybe_json_decode(Msg0),
                        Decoded0#{<<"message">> := Msg};
                    {ok, Decoded0} ->
                        Decoded0;
                    {error, _} ->
                        Body0
                end,
            {error, {Status, Headers, Body}};
        Error ->
            Error
    end.

sql_test_api(Params) ->
    Method = post,
    Path = emqx_mgmt_api_test_util:api_path(["rule_test"]),
    ct:pal("sql test (http):\n  ~p", [Params]),
    Res = request(Method, Path, Params),
    ct:pal("sql test (http) result:\n  ~p", [Res]),
    Res.

list_rules(QueryParams) when is_list(QueryParams) ->
    Method = get,
    Path = emqx_mgmt_api_test_util:api_path(["rules"]),
    Opts = #{return_all => true},
    Res = request(Method, Path, _Body = [], QueryParams, Opts),
    emqx_mgmt_api_test_util:simplify_result(Res).

list_rules_just_ids(QueryParams) when is_list(QueryParams) ->
    case list_rules(QueryParams) of
        {200, #{<<"data">> := Results0}} ->
            Results = lists:sort([Id || #{<<"id">> := Id} <- Results0]),
            {200, Results};
        Res ->
            Res
    end.

create_rule() ->
    create_rule(_Overrides = #{}).

create_rule(Overrides) ->
    Params0 = #{
        <<"enable">> => true,
        <<"sql">> => <<"select true from t">>
    },
    Params = emqx_utils_maps:deep_merge(Params0, Overrides),
    Method = post,
    Path = emqx_mgmt_api_test_util:api_path(["rules"]),
    Res = request(Method, Path, Params),
    case emqx_mgmt_api_test_util:simplify_result(Res) of
        {201, #{<<"id">> := RuleId}} = SRes ->
            on_exit(fun() ->
                {ok, _} = emqx_conf:remove([rule_engine, rules, RuleId], #{override_to => cluster})
            end),
            SRes;
        SRes ->
            SRes
    end.

update_rule(Id, Params) ->
    Method = put,
    Path = emqx_mgmt_api_test_util:api_path(["rules", Id]),
    Res = request(Method, Path, Params),
    emqx_mgmt_api_test_util:simplify_result(Res).

delete_rule(RuleId) ->
    emqx_mgmt_api_test_util:simple_request(#{
        method => delete,
        url => emqx_mgmt_api_test_util:api_path(["rules", RuleId])
    }).

list_rules() ->
    Method = get,
    Path = emqx_mgmt_api_test_util:api_path(["rules"]),
    Res = request(Method, Path, _Params = ""),
    emqx_mgmt_api_test_util:simplify_result(Res).

get_rule(Id) ->
    Method = get,
    Path = emqx_mgmt_api_test_util:api_path(["rules", Id]),
    Res = request(Method, Path, _Params = ""),
    emqx_mgmt_api_test_util:simplify_result(Res).

sources_sql(Sources) ->
    Froms = iolist_to_binary(lists:join(<<", ">>, lists:map(fun source_from/1, Sources))),
    <<"select * from ", Froms/binary>>.

source_from({v1, Id}) ->
    <<"\"$bridges/", Id/binary, "\" ">>;
source_from({v2, Id}) ->
    <<"\"$sources/", Id/binary, "\" ">>.

spy_action(Selected, Envs, #{pid := TestPidBin}) ->
    TestPid = list_to_pid(binary_to_list(TestPidBin)),
    TestPid ! {rule_called, #{selected => Selected, envs => Envs}},
    ok.

event_type(EventTopic) ->
    EventAtom = emqx_rule_events:event_name(EventTopic),
    emqx_rule_api_schema:event_to_event_type(EventAtom).

%%------------------------------------------------------------------------------
%% Test cases
%%------------------------------------------------------------------------------

t_rule_test_smoke(_Config) ->
    %% Example inputs recorded from frontend on 2023-12-04
    Publish = [
        #{
            expected => #{code => 200},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"message_publish">>,
                            <<"payload">> => <<"{\"msg\": \"hello\"}">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            hint => <<"wrong topic">>,
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"message_publish">>,
                            <<"payload">> => <<"{\"msg\": \"hello\"}">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            hint => <<
                "Currently, the frontend doesn't try to match against "
                "$events/message_published, but it may start sending "
                "the event topic in the future."
            >>,
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"message_publish">>,
                            <<"payload">> => <<"{\"msg\": \"hello\"}">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"$events/message_published\"">>
                }
        }
    ],
    %% Default input SQL doesn't match any event topic
    DefaultNoMatch = [
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx_2">>,
                            <<"event_type">> => <<"message_delivered">>,
                            <<"from_clientid">> => <<"c_emqx_1">>,
                            <<"from_username">> => <<"u_emqx_1">>,
                            <<"payload">> => <<"{\"msg\": \"hello\"}">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx_2">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx_2">>,
                            <<"event_type">> => <<"message_acked">>,
                            <<"from_clientid">> => <<"c_emqx_1">>,
                            <<"from_username">> => <<"u_emqx_1">>,
                            <<"payload">> => <<"{\"msg\": \"hello\"}">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx_2">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"message_dropped">>,
                            <<"payload">> => <<"{\"msg\": \"hello\"}">>,
                            <<"qos">> => 1,
                            <<"reason">> => <<"no_subscribers">>,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"client_connected">>,
                            <<"peername">> => <<"127.0.0.1:52918">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"client_disconnected">>,
                            <<"reason">> => <<"normal">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"client_connack">>,
                            <<"reason_code">> => <<"success">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"action">> => <<"publish">>,
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"client_check_authz_complete">>,
                            <<"result">> => <<"allow">>,
                            <<"topic">> => <<"t/1">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"client_check_authn_complete">>,
                            <<"reason_code">> => <<"success">>,
                            <<"is_superuser">> => true,
                            <<"is_anonymous">> => false,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"client_check_authn_complete">>,
                            <<"reason_code">> => <<"sucess">>,
                            <<"is_superuser">> => true,
                            <<"is_anonymous">> => false,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"session_subscribed">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"session_unsubscribed">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx_2">>,
                            <<"event_type">> => <<"delivery_dropped">>,
                            <<"from_clientid">> => <<"c_emqx_1">>,
                            <<"from_username">> => <<"u_emqx_1">>,
                            <<"payload">> => <<"{\"msg\": \"hello\"}">>,
                            <<"qos">> => 1,
                            <<"reason">> => <<"queue_full">>,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx_2">>
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
                }
        }
    ],
    MultipleFrom = [
        #{
            expected => #{code => 200},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"message_publish">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> =>
                        <<"SELECT\n  *\nFROM\n  \"t/#\", \"$bridges/mqtt:source\" ">>
                }
        },
        #{
            expected => #{code => 200},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"message_publish">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> =>
                        <<"SELECT\n  *\nFROM\n  \"t/#\", \"$sources/mqtt:source\" ">>
                }
        },
        #{
            expected => #{code => 200},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"session_unsubscribed">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> =>
                        <<"SELECT\n  *\nFROM\n  \"t/#\", \"$events/session_unsubscribed\" ">>
                }
        },
        #{
            expected => #{code => 200},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"session_unsubscribed">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> =>
                        <<"SELECT\n  *\nFROM\n  \"$events/message_dropped\", \"$events/session_unsubscribed\" ">>
                }
        },
        #{
            expected => #{code => 412},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"clientid">> => <<"c_emqx">>,
                            <<"event_type">> => <<"session_unsubscribed">>,
                            <<"qos">> => 1,
                            <<"topic">> => <<"t/a">>,
                            <<"username">> => <<"u_emqx">>
                        },
                    <<"sql">> =>
                        <<"SELECT\n  *\nFROM\n  \"$events/message_dropped\", \"$events/client_connected\" ">>
                }
        }
    ],
    Cases = Publish ++ DefaultNoMatch ++ MultipleFrom,
    FailedCases = lists:filtermap(fun do_t_rule_test_smoke/1, Cases),
    ?assertEqual([], FailedCases),
    ok.

%% Checks the behavior of MQTT wildcards when used with events (`$events/#`,
%% `$events/sys/+`, etc.).
t_rule_test_wildcards(_Config) ->
    Cases = [
        #{
            expected => #{code => 200},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"event_type">> => <<"alarm_activated">>,
                            <<"name">> => <<"alarm_name">>,
                            <<"details">> => #{
                                <<"some_key_that_is_not_a_known_atom">> => <<"yes">>
                            },
                            <<"message">> => <<"boom">>,
                            <<"activated_at">> => 1736512728666
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"$events/sys/+\"">>
                }
        },
        #{
            expected => #{code => 200},
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"event_type">> => <<"alarm_deactivated">>,
                            <<"name">> => <<"alarm_name">>,
                            <<"details">> => #{
                                <<"some_key_that_is_not_a_known_atom">> => <<"yes">>
                            },
                            <<"message">> => <<"boom">>,
                            <<"activated_at">> => 1736512728666,
                            <<"deactivated_at">> => 1736512728966
                        },
                    <<"sql">> => <<"SELECT\n  *\nFROM\n  \"$events/sys/+\"">>
                }
        }
    ],
    FailedCases = lists:filtermap(fun do_t_rule_test_smoke/1, Cases),
    ?assertEqual([], FailedCases),
    ok.

%% validate check_schema is function with bad content_type
t_rule_test_with_bad_content_type(_Config) ->
    Params =
        #{
            <<"context">> =>
                #{
                    <<"clientid">> => <<"c_emqx">>,
                    <<"event_type">> => <<"message_publish">>,
                    <<"payload">> => <<"{\"msg\": \"hello\"}">>,
                    <<"qos">> => 1,
                    <<"topic">> => <<"t/a">>,
                    <<"username">> => <<"u_emqx">>
                },
            <<"sql">> => <<"SELECT\n  *\nFROM\n  \"t/#\"">>
        },
    Method = post,
    Path = emqx_mgmt_api_test_util:api_path(["rule_test"]),
    Opts = #{return_all => true, 'content-type' => "application/xml"},
    ?assertMatch(
        {error,
            {
                {"HTTP/1.1", 415, "Unsupported Media Type"},
                _Headers,
                #{
                    <<"code">> := <<"UNSUPPORTED_MEDIA_TYPE">>,
                    <<"message">> := <<"content-type:application/json Required">>
                }
            }},
        request(Method, Path, Params, Opts)
    ),
    ok.

do_t_rule_test_smoke(#{input := Input, expected := #{code := ExpectedCode}} = Case) ->
    {_ErrOrOk, {{_, Code, _}, _, Body}} = sql_test_api(Input),
    case Code =:= ExpectedCode of
        true ->
            false;
        false ->
            {true, #{
                expected => ExpectedCode,
                hint => maps:get(hint, Case, <<>>),
                input => Input,
                got => Code,
                resp_body => Body
            }}
    end.

%% Checks that each event is recognized by `/rule_test' and the examples are valid.
t_rule_test_examples(_Config) ->
    AllEventInfos = emqx_rule_events:event_info(),
    Failures = lists:filtermap(
        fun
            (#{event := <<"$bridges/mqtt:*">>}) ->
                %% Currently, our frontend doesn't support simulating source events.
                false;
            (EventInfo) ->
                #{
                    sql_example := SQL,
                    test_columns := TestColumns,
                    event := EventTopic
                } = EventInfo,
                EventType = event_type(EventTopic),
                Context = lists:foldl(
                    fun
                        ({Field, [ExampleValue, _Description]}, Acc) ->
                            Acc#{Field => ExampleValue};
                        ({Field, ExampleValue}, Acc) ->
                            Acc#{Field => ExampleValue}
                    end,
                    #{<<"event_type">> => EventType},
                    TestColumns
                ),
                Case = #{
                    expected => #{code => 200},
                    input => #{<<"context">> => Context, <<"sql">> => SQL}
                },
                do_t_rule_test_smoke(Case)
        end,
        AllEventInfos
    ),
    ?assertEqual([], Failures),
    ok.

%% Tests filtering the rule list by used actions and/or sources.
t_filter_by_source_and_action(_Config) ->
    ?assertMatch(
        {200, #{<<"data">> := []}},
        list_rules([])
    ),

    ActionId1 = <<"mqtt:a1">>,
    ActionId2 = <<"mqtt:a2">>,
    SourceId1 = <<"mqtt:s1">>,
    SourceId2 = <<"mqtt:s2">>,
    {201, #{<<"id">> := Id1}} = create_rule(#{<<"actions">> => [ActionId1]}),
    {201, #{<<"id">> := Id2}} = create_rule(#{<<"actions">> => [ActionId2]}),
    {201, #{<<"id">> := Id3}} = create_rule(#{<<"actions">> => [ActionId2, ActionId1]}),
    {201, #{<<"id">> := Id4}} = create_rule(#{<<"sql">> => sources_sql([{v1, SourceId1}])}),
    {201, #{<<"id">> := Id5}} = create_rule(#{<<"sql">> => sources_sql([{v2, SourceId2}])}),
    {201, #{<<"id">> := Id6}} = create_rule(#{
        <<"sql">> => sources_sql([{v2, SourceId1}, {v2, SourceId1}])
    }),
    {201, #{<<"id">> := Id7}} = create_rule(#{
        <<"sql">> => sources_sql([{v2, SourceId1}]),
        <<"actions">> => [ActionId1]
    }),

    ?assertMatch(
        {200, [_, _, _, _, _, _, _]},
        list_rules_just_ids([])
    ),

    ?assertEqual(
        {200, lists:sort([Id1, Id3, Id7])},
        list_rules_just_ids([{<<"action">>, ActionId1}])
    ),

    ?assertEqual(
        {200, lists:sort([Id1, Id2, Id3, Id7])},
        list_rules_just_ids([{<<"action">>, ActionId1}, {<<"action">>, ActionId2}])
    ),

    ?assertEqual(
        {200, lists:sort([Id4, Id6, Id7])},
        list_rules_just_ids([{<<"source">>, SourceId1}])
    ),

    ?assertEqual(
        {200, lists:sort([Id4, Id5, Id6, Id7])},
        list_rules_just_ids([{<<"source">>, SourceId1}, {<<"source">>, SourceId2}])
    ),

    %% When mixing source and action id filters, we use AND.
    ?assertEqual(
        {200, lists:sort([])},
        list_rules_just_ids([{<<"source">>, SourceId2}, {<<"action">>, ActionId2}])
    ),
    ?assertEqual(
        {200, lists:sort([Id7])},
        list_rules_just_ids([{<<"source">>, SourceId1}, {<<"action">>, ActionId1}])
    ),

    ok.

%% Checks that creating a rule with a `null' JSON value id is forbidden.
t_create_rule_with_null_id(_Config) ->
    ?assertMatch(
        {400, #{<<"message">> := <<"rule id must be a string">>}},
        create_rule(#{<<"id">> => null})
    ),
    %% The string `"null"' should be fine.
    ?assertMatch(
        {201, _},
        create_rule(#{<<"id">> => <<"null">>})
    ),
    ?assertMatch({201, _}, create_rule(#{})),
    ?assertMatch(
        {200, #{<<"data">> := [_, _]}},
        list_rules([])
    ),
    ok.

%% Smoke tests for `$events/sys/alarm_activated' and `$events/sys/alarm_deactivated'.
t_alarm_events(Config) ->
    TestPidBin = list_to_binary(pid_to_list(self())),
    {201, _} = create_rule(#{
        <<"id">> => <<"alarms">>,
        <<"sql">> => iolist_to_binary([
            <<" select * from ">>,
            <<" \"$events/sys/alarm_activated\", ">>,
            <<" \"$events/sys/alarm_deactivated\" ">>
        ]),
        <<"actions">> => [
            #{
                <<"function">> => <<?MODULE_STRING, ":spy_action">>,
                <<"args">> => #{<<"pid">> => TestPidBin}
            }
        ]
    }),
    do_t_alarm_events(Config).

%% Smoke tests for `$events/sys/+'.
t_alarm_events_plus(Config) ->
    TestPidBin = list_to_binary(pid_to_list(self())),
    {201, _} = create_rule(#{
        <<"id">> => <<"alarms">>,
        <<"sql">> => iolist_to_binary([
            <<" select * from ">>,
            <<" \"$events/sys/+\" ">>
        ]),
        <<"actions">> => [
            #{
                <<"function">> => <<?MODULE_STRING, ":spy_action">>,
                <<"args">> => #{<<"pid">> => TestPidBin}
            }
        ]
    }),
    do_t_alarm_events(Config).

%% Smoke tests for `$events/#'.
t_alarm_events_hash(Config) ->
    TestPidBin = list_to_binary(pid_to_list(self())),
    RuleId = <<"alarms_hash">>,
    {201, _} = create_rule(#{
        <<"id">> => RuleId,
        <<"sql">> => iolist_to_binary([
            <<" select * from ">>,
            <<" \"$events/#\" ">>
        ]),
        <<"actions">> => [
            #{
                <<"function">> => <<?MODULE_STRING, ":spy_action">>,
                <<"args">> => #{<<"pid">> => TestPidBin}
            }
        ]
    }),
    do_t_alarm_events(Config),
    %% Message publish shouldn't match `$events/#`, but can match other events such as
    %% `$events/message_dropped`.
    emqx:publish(emqx_message:make(<<"t">>, <<"hey">>)),
    ?assertReceive(
        {rule_called, #{
            selected := #{event := 'message.dropped'},
            envs := #{
                metadata := #{
                    matched := <<"$events/#">>,
                    trigger := <<"$events/message_dropped">>
                }
            }
        }}
    ),
    {ok, _} = emqx_conf:remove([rule_engine, rules, RuleId], #{override_to => cluster}),
    %% Shouldn't match anymore.
    emqx:publish(emqx_message:make(<<"t">>, <<"hey">>)),
    ?assertNotReceive({rule_called, _}),
    ok.

do_t_alarm_events(_Config) ->
    AlarmName = <<"some_alarm">>,
    Details = #{more => details},
    Message = [<<"some">>, $\s | [<<"io">>, "list"]],
    emqx_alarm:activate(AlarmName, Details, Message),
    ?assertReceive(
        {rule_called, #{
            selected :=
                #{
                    message := <<"some iolist">>,
                    details := #{more := details},
                    name := AlarmName,
                    activated_at := _,
                    event := 'alarm.activated'
                }
        }}
    ),

    %% Activating an active alarm shouldn't trigger the event again.
    emqx_alarm:activate(AlarmName, Details, Message),
    emqx_alarm:activate(AlarmName, Details),
    emqx_alarm:activate(AlarmName),
    emqx_alarm:safe_activate(AlarmName, Details, Message),
    ?assertNotReceive({rule_called, _}),

    DeactivateMessage = <<"deactivating">>,
    DeactivateDetails = #{new => details},
    emqx_alarm:deactivate(AlarmName, DeactivateDetails, DeactivateMessage),
    ?assertReceive(
        {rule_called, #{
            selected :=
                #{
                    message := DeactivateMessage,
                    details := DeactivateDetails,
                    name := AlarmName,
                    activated_at := _,
                    deactivated_at := _,
                    event := 'alarm.deactivated'
                }
        }}
    ),

    %% Deactivating an inactive alarm shouldn't trigger the event again.
    emqx_alarm:deactivate(AlarmName),
    emqx_alarm:deactivate(AlarmName, Details),
    emqx_alarm:deactivate(AlarmName, Details, Message),
    emqx_alarm:safe_deactivate(AlarmName),
    ?assertNotReceive({rule_called, _}),

    ok.

%% Checks that, when removing a rule with a wildcard, we remove the hook function for each
%% event for which such rule is the last referencing one.
t_remove_rule_with_wildcard(_Config) ->
    %% This only hooks on `'message.publish'`.
    RuleId1 = <<"simple">>,
    {201, _} = create_rule(#{
        <<"id">> => RuleId1,
        <<"sql">> => iolist_to_binary([
            <<" select * from ">>,
            <<" \"concrete/topic\" ">>
        ]),
        <<"actions">> => []
    }),
    %% This hooks on all `$events/#`
    RuleId2 = <<"all">>,
    {201, _} = create_rule(#{
        <<"id">> => RuleId2,
        <<"sql">> => iolist_to_binary([
            <<" select * from ">>,
            <<" \"$events/#\" ">>
        ]),
        <<"actions">> => []
    }),
    Events = ['message.publish' | emqx_rule_events:match_event_names(<<"$events/#">>)],
    ListRuleHooks = fun() ->
        [
            E
         || E <- Events,
            {callback, {emqx_rule_events, _, _}, _, _} <- emqx_hooks:lookup(E)
        ]
    end,
    ?assertEqual(lists:sort(Events), lists:sort(ListRuleHooks())),
    {204, _} = delete_rule(RuleId2),
    %% Should have cleared up all hooks but `'message.publish'``.
    ?assertMatch(['message.publish'], ListRuleHooks()),
    {204, _} = delete_rule(RuleId1),
    ?assertMatch([], ListRuleHooks()),
    ok.

%% Smoke tests for `last_modified_at' field when creating/updating a rule.
t_last_modified_at(_Config) ->
    Id = <<"last_mod_at">>,
    CreateParams = #{
        <<"id">> => Id,
        <<"sql">> => iolist_to_binary([
            <<" select * from \"t/a\" ">>
        ]),
        <<"actions">> => [
            #{<<"function">> => <<"console">>}
        ]
    },
    {201, Res} = create_rule(CreateParams),
    ?assertMatch(
        #{
            <<"created_at">> := CreatedAt,
            <<"last_modified_at">> := CreatedAt
        },
        Res
    ),
    ?assertMatch(
        {200, #{
            <<"created_at">> := CreatedAt,
            <<"last_modified_at">> := CreatedAt
        }},
        get_rule(Id)
    ),
    ?assertMatch(
        {200, #{
            <<"data">> := [
                #{
                    <<"created_at">> := CreatedAt,
                    <<"last_modified_at">> := CreatedAt
                }
            ]
        }},
        list_rules()
    ),
    #{
        <<"created_at">> := CreatedAt,
        <<"last_modified_at">> := CreatedAt
    } = Res,
    ct:sleep(10),
    UpdateParams = maps:without([<<"id">>], CreateParams),
    {200, UpdateRes} = update_rule(Id, UpdateParams),
    ?assertMatch(
        #{
            <<"created_at">> := CreatedAt,
            <<"last_modified_at">> := LastModifiedAt
        } when LastModifiedAt =/= CreatedAt,
        UpdateRes,
        #{created_at => CreatedAt}
    ),
    #{<<"last_modified_at">> := LastModifiedAt} = UpdateRes,
    ?assertMatch(
        {200, #{
            <<"created_at">> := CreatedAt,
            <<"last_modified_at">> := LastModifiedAt
        }},
        get_rule(Id)
    ),
    ?assertMatch(
        {200, #{
            <<"data">> := [
                #{
                    <<"created_at">> := CreatedAt,
                    <<"last_modified_at">> := LastModifiedAt
                }
            ]
        }},
        list_rules()
    ),
    ok.

%% This verifies that we don't attempt to transform keys in the `details' value of an
%% alarm activated/deactivated rule test to atoms.
t_alarm_details_with_unknown_atom_key(_Config) ->
    Cases = [
        #{
            expected => #{code => 200},
            hint => <<
                "the original bug was that this failed with 500 when"
                " trying to convert a binary to existing atom"
            >>,
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"event_type">> => <<"alarm_activated">>,
                            <<"name">> => <<"alarm_name">>,
                            <<"details">> => #{
                                <<"some_key_that_is_not_a_known_atom">> => <<"yes">>
                            },
                            <<"message">> => <<"boom">>,
                            <<"activated_at">> => 1736512728666
                        },
                    <<"sql">> =>
                        <<"SELECT\n  *\nFROM\n  \"$events/sys/alarm_activated\" ">>
                }
        },
        #{
            expected => #{code => 200},
            hint => <<
                "the original bug was that this failed with 500 when"
                " trying to convert a binary to existing atom"
            >>,
            input =>
                #{
                    <<"context">> =>
                        #{
                            <<"event_type">> => <<"alarm_deactivated">>,
                            <<"name">> => <<"alarm_name">>,
                            <<"details">> => #{
                                <<"some_key_that_is_not_a_known_atom">> => <<"yes">>
                            },
                            <<"message">> => <<"boom">>,
                            <<"activated_at">> => 1736512728666,
                            <<"deactivated_at">> => 1736512828666
                        },
                    <<"sql">> =>
                        <<"SELECT\n  *\nFROM\n  \"$events/sys/alarm_deactivated\" ">>
                }
        }
    ],
    Failures = lists:filtermap(fun do_t_rule_test_smoke/1, Cases),
    ?assertEqual([], Failures),
    ok.

%% Verifies that we enrich the list response with status about the Actions in each rule,
%% if available.
t_action_details(Config) ->
    ExtraAppSpecs = [
        emqx_bridge_mqtt,
        emqx_bridge
    ],
    ExtraApps = emqx_cth_suite:start_apps(
        ExtraAppSpecs,
        #{work_dir => emqx_cth_suite:work_dir(?FUNCTION_NAME, Config)}
    ),
    on_exit(fun() -> emqx_cth_suite:stop_apps(ExtraApps) end),

    CreateBridge = fun(Name, MQTTPort) ->
        emqx_bridge_v2_testlib:create_bridge_api([
            {connector_type, <<"mqtt">>},
            {connector_name, Name},
            {connector_config,
                emqx_bridge_mqtt_v2_publisher_SUITE:connector_config(#{
                    <<"server">> => <<"127.0.0.1:", (integer_to_binary(MQTTPort))/binary>>
                })},
            {bridge_kind, action},
            {action_type, <<"mqtt">>},
            {action_name, Name},
            {action_config,
                emqx_bridge_mqtt_v2_publisher_SUITE:action_config(#{
                    <<"connector">> => Name
                })}
        ])
    end,
    on_exit(fun emqx_bridge_v2_testlib:delete_all_bridges_and_connectors/0),
    {ok, _} = CreateBridge(<<"a1">>, 1883),
    %% Bad port: will be disconnected
    {ok, _} = CreateBridge(<<"a2">>, 9999),

    ?assertMatch(
        {200, #{<<"data">> := []}},
        list_rules([])
    ),

    ActionId1 = <<"mqtt:a1">>,
    ActionId2 = <<"mqtt:a2">>,
    %% This onw does not exist.
    ActionId3 = <<"mqtt:a3">>,
    {201, _} = create_rule(#{<<"id">> => <<"1">>, <<"actions">> => [ActionId1]}),
    {201, _} = create_rule(#{<<"id">> => <<"2">>, <<"actions">> => [ActionId2]}),
    {201, _} = create_rule(#{<<"id">> => <<"3">>, <<"actions">> => [ActionId2, ActionId1]}),
    {201, _} = create_rule(#{<<"id">> => <<"4">>, <<"actions">> => [ActionId3]}),

    ?assertMatch(
        {200, #{
            <<"data">> := [
                #{
                    <<"action_details">> := [
                        #{
                            <<"type">> := <<"mqtt">>,
                            <<"name">> := <<"a3">>,
                            <<"status">> := <<"not_found">>
                        }
                    ]
                },
                #{
                    <<"action_details">> := [
                        #{
                            <<"type">> := <<"mqtt">>,
                            <<"name">> := <<"a2">>,
                            <<"status">> := <<"disconnected">>
                        },
                        #{
                            <<"type">> := <<"mqtt">>,
                            <<"name">> := <<"a1">>,
                            <<"status">> := <<"connected">>
                        }
                    ]
                },
                #{
                    <<"action_details">> := [
                        #{
                            <<"type">> := <<"mqtt">>,
                            <<"name">> := <<"a2">>,
                            <<"status">> := <<"disconnected">>
                        }
                    ]
                },
                #{
                    <<"action_details">> := [
                        #{
                            <<"type">> := <<"mqtt">>,
                            <<"name">> := <<"a1">>,
                            <<"status">> := <<"connected">>
                        }
                    ]
                }
            ]
        }},
        list_rules([])
    ),
    ok.
