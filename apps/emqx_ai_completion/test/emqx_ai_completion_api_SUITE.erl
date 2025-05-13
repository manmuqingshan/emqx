%%--------------------------------------------------------------------
%% Copyright (c) 2024-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_ai_completion_api_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

-import(
    emqx_mgmt_api_test_util,
    [
        request/2,
        request/3,
        uri/1
    ]
).

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start(
        [
            emqx_conf,
            emqx,
            {emqx_ai_completion, #{config => "ai.providers = [], ai.completion_profiles = []"}},
            emqx_management,
            emqx_mgmt_api_test_util:emqx_dashboard()
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{suite_apps, Apps} | Config].

end_per_suite(Config) ->
    ok = emqx_cth_suite:stop(?config(suite_apps, Config)).

init_per_testcase(_TestCase, Config) ->
    emqx_ai_completion_test_helpers:clean_completion_profiles(),
    emqx_ai_completion_test_helpers:clean_providers(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    emqx_ai_completion_test_helpers:clean_completion_profiles(),
    emqx_ai_completion_test_helpers:clean_providers().

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

t_crud(_Config) ->
    %% Fail to create invalid providers
    ?assertMatch(
        {ok, 400, _},
        api_post([ai, providers], #{<<"foo">> => <<"bar">>})
    ),

    %% Create valid providers
    ?assertMatch(
        {ok, 204},
        api_post([ai, providers], #{
            name => <<"test-provider">>,
            type => <<"openai">>,
            api_key => <<"test-api-key">>
        })
    ),

    %% Fail to create provider with duplicate name
    ?assertMatch(
        {ok, 400, _},
        api_post([ai, providers], #{
            name => <<"test-provider">>,
            type => <<"openai">>,
            api_key => <<"test-api-key">>
        })
    ),

    %% Succeed to fetch provider
    ?assertMatch(
        {ok, 200, #{<<"name">> := <<"test-provider">>, <<"type">> := <<"openai">>}},
        api_get([ai, providers, <<"test-provider">>])
    ),

    %% Fail to fetch non-existent provider
    ?assertMatch(
        {ok, 404, _},
        api_get([ai, providers, <<"non-existent-provider">>])
    ),

    %% Succeed to fetch providers
    ?assertMatch(
        {ok, 200, [
            #{<<"name">> := <<"test-provider">>, <<"type">> := <<"openai">>}
        ]},
        api_get([ai, providers])
    ),

    %% Fail to create invalid completion profile
    ?assertMatch(
        {ok, 400, _},
        api_post([ai, completion_profiles], #{<<"foo">> => <<"bar">>})
    ),

    %% Fail to create with invalid provider
    ?assertMatch(
        {ok, 400, _},
        api_post([ai, completion_profiles], #{
            name => <<"test-completion-profile">>,
            type => <<"openai">>,
            provider_name => <<"non-existent-provider">>,
            model => <<"gpt-4o">>
        })
    ),

    %% Fail to create with mismatching provider type
    ?assertMatch(
        {ok, 400, _},
        api_post([ai, completion_profiles], #{
            name => <<"test-completion-profile">>,
            type => <<"anthropic">>,
            provider_name => <<"test-provider">>
        })
    ),

    %% Create valid completion profile
    ?assertMatch(
        {ok, 204},
        api_post([ai, completion_profiles], #{
            name => <<"test-completion-profile">>,
            type => <<"openai">>,
            provider_name => <<"test-provider">>,
            model => <<"gpt-4o">>
        })
    ),

    %% Fail to create completion profile with duplicate name
    ?assertMatch(
        {ok, 400, _},
        api_post([ai, completion_profiles], #{
            name => <<"test-completion-profile">>,
            type => <<"openai">>,
            provider_name => <<"test-provider">>,
            model => <<"gpt-4o">>
        })
    ),

    %% Succeed to fetch completion profile by name
    ?assertMatch(
        {ok, 200, #{<<"name">> := <<"test-completion-profile">>, <<"type">> := <<"openai">>}},
        api_get([ai, completion_profiles, <<"test-completion-profile">>])
    ),

    %% Fail to fetch non-existent completion profile
    ?assertMatch(
        {ok, 404, _},
        api_get([ai, completion_profiles, <<"non-existent-completion-profile">>])
    ),

    %% Succeed to fetch completion profiles
    ?assertMatch(
        {ok, 200, [
            #{<<"name">> := <<"test-completion-profile">>, <<"type">> := <<"openai">>}
        ]},
        api_get([ai, completion_profiles])
    ),

    %% Fail to update provider type of the used provider
    ?assertMatch(
        {ok, 400, _},
        api_put([ai, providers, <<"test-provider">>], #{
            type => <<"anthropic">>,
            api_key => <<"test-api-key">>
        })
    ),

    %% Fail to delete the used provider
    ?assertMatch(
        {ok, 400, _},
        api_delete([ai, providers, <<"test-provider">>])
    ),

    %% Succeed to update the used provider
    ?assertMatch(
        {ok, 204},
        api_put([ai, providers, <<"test-provider">>], #{
            type => <<"openai">>,
            api_key => <<"new-test-api-key">>
        })
    ),

    %% Fail to change completion profile type
    ?assertMatch(
        {ok, 400, _},
        api_put([ai, completion_profiles, <<"test-completion-profile">>], #{
            type => <<"anthropic">>,
            provider_name => <<"test-provider">>
        })
    ),

    %% Succeed to delete unknown completion profile
    ?assertMatch(
        {ok, 204},
        api_delete([ai, completion_profiles, <<"unknown-completion-profile">>])
    ),

    %% Succeed to update completion profile
    ?assertMatch(
        {ok, 204},
        api_put([ai, completion_profiles, <<"test-completion-profile">>], #{
            type => <<"openai">>,
            provider_name => <<"test-provider">>,
            model => <<"gpt-4o-mini">>
        })
    ),

    %% Succeed to delete the completion profile
    ?assertMatch(
        {ok, 204},
        api_delete([ai, completion_profiles, <<"test-completion-profile">>])
    ),

    %% Succeed to delete unknown provider
    ?assertMatch(
        {ok, 204},
        api_delete([ai, providers, <<"unknown-provider">>])
    ),

    %% Succeed to delete the provider
    ?assertMatch(
        {ok, 204},
        api_delete([ai, providers, <<"test-provider">>])
    ).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

api_get(Path) ->
    decode_body(request(get, uri(Path))).

api_post(Path, Data) ->
    decode_body(request(post, uri(Path), Data)).

api_put(Path, Data) ->
    decode_body(request(put, uri(Path), Data)).

api_delete(Path) ->
    decode_body(request(delete, uri(Path))).

decode_body(Response) ->
    ct:pal("Response: ~p", [Response]),
    do_decode_body(Response).

do_decode_body({ok, Code, <<>>}) ->
    {ok, Code};
do_decode_body({ok, Code, Body}) ->
    case emqx_utils_json:safe_decode(Body) of
        {ok, Decoded} ->
            {ok, Code, Decoded};
        {error, _} = Error ->
            ct:pal("Invalid body: ~p", [Body]),
            Error
    end;
do_decode_body(Error) ->
    Error.
