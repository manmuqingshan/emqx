%%--------------------------------------------------------------------
%% Copyright (c) 2021-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_limiter_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%--------------------------------------------------------------------
%%  API functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%% @end
%%--------------------------------------------------------------------
-spec start_link() ->
    {ok, Pid :: pid()}
    | {error, {already_started, Pid :: pid()}}
    | {error, {shutdown, term()}}
    | {error, term()}
    | ignore.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%%  Supervisor callbacks
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart intensity, and child
%% specifications.
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) ->
    {ok, {SupFlags :: supervisor:sup_flags(), [ChildSpec :: supervisor:child_spec()]}}
    | ignore.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 3600
    },

    Childs = [
        make_child(emqx_limiter_manager, worker),
        make_child(emqx_limiter_server_sup, supervisor)
    ],

    {ok, {SupFlags, Childs}}.

make_child(Mod, Type) ->
    #{
        id => Mod,
        start => {Mod, start_link, []},
        restart => transient,
        type => Type,
        modules => [Mod]
    }.
