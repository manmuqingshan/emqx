%%--------------------------------------------------------------------
%% Copyright (c) 2023-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(emqx_dashboard_listener_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("common_test/include/ct.hrl").

all() ->
    emqx_common_test_helpers:all(?MODULE).

init_per_suite(Config) ->
    Apps = emqx_cth_suite:start(
        [
            emqx_conf,
            emqx_management,
            emqx_mgmt_api_test_util:emqx_dashboard()
        ],
        #{work_dir => emqx_cth_suite:work_dir(Config)}
    ),
    [{apps, Apps} | Config].

end_per_suite(Config) ->
    Apps = ?config(apps, Config),
    emqx_cth_suite:stop(Apps),
    ok.

t_change_i18n_lang(_Config) ->
    ?check_trace(
        begin
            ok = change_i18n_lang(zh),
            {ok, _} = ?block_until(#{?snk_kind := regenerate_minirest_dispatch}, 10_000),
            ok
        end,
        fun(ok, Trace) ->
            ?assertMatch([#{i18n_lang := zh}], ?of_kind(regenerate_minirest_dispatch, Trace))
        end
    ),
    ok.

change_i18n_lang(Lang) ->
    {ok, _} = emqx_conf:update([dashboard], {change_i18n_lang, Lang}, #{}),
    ok.
