%%% @doc Main module for apns4erl API. Use this one from your own applications.
%%%
%%% Copyright 2017 Erlang Solutions Ltd.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Inaka <hello@inaka.net>
%%%
-module(apns).
-author("Felipe Ripoll <felipe@inakanetworks.com>").
-include("apns.hrl").
-compile({parse_transform, lager_transform}).

%% API
-export([ start/0
        , stop/0
%%        , connect/2
        , connect/5
        , connect_pool/6
        , close_connection/1
%%        , push_notification/3
        , push_notification/4
        , push_notification_in_pool/5
        , generate_connection_name_list/2
%%        , push_notification_token/4
%%        , push_notification_token/5
%%        , default_headers/0
        , generate_token/2
%%        , get_feedback/0
        ]).

-export_type([ json/0
             , device_id/0
             , response/0
             , token/0
             , headers/0
             ]).

-type json()      :: #{binary() => binary() | json()}.
-type device_id() :: binary().
-type response()  :: { integer()          % HTTP2 Code
                     , [term()]           % Response Headers
                     , [term()] | no_body % Response Body
                     } | timeout.
-type token()     :: binary().
-type headers()   :: #{ apns_id          => binary()
                      , apns_expiration  => binary()
                      , apns_priority    => binary()
                      , apns_topic       => binary()
                      , apns_collapse_id => binary()
                      , apns_auth_token  => binary()
                      }.
-type feedback()  :: apns_feedback:feedback().

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Used when starting the application on the shell.
-spec start() -> ok.
start() ->
  {ok, _} = application:ensure_all_started(apns),
  ok.

%% @doc Stops the Application
-spec stop() -> ok.
stop() ->
  ok = application:stop(apns),
  ok.

%% @doc Connects to APNs service with Provider Certificate
-spec connect( apns_connection:type(), apns_connection:name()) ->
  {ok, pid()} | {error, timeout}.
connect(Type, ConnectionName) ->
  DefaultConnection = apns_connection:default_connection(Type, ConnectionName),
  connect(DefaultConnection).

-spec connect( apns_connection:type(), apns_connection:name(), apns_connection:path(), apns_connection:path(), apns_connection:host()) ->
  {ok, pid()} | {error, timeout}.
connect(cert, ConnectionName, CertFilePath, KeyFilePath, AppleHost) ->
  CustomConnection = apns_connection:custom_connection(cert, ConnectionName, CertFilePath, KeyFilePath, AppleHost),
  connect(CustomConnection).

-spec connect_pool( apns_connection:type(), apns_connection:name(), integer(), apns_connection:path(), apns_connection:path(), apns_connection:host()) ->
  {ok, pid()} | {error, timeout}.
connect_pool(cert, ConnectionPoolName, ConnectionPoolSize, CertFilePath, KeyFilePath, AppleHost) ->
  CustomConnection = apns_connection:custom_connection(cert, connectionName, CertFilePath, KeyFilePath, AppleHost),

  ets:insert(?APNS_CONNECTION_POOL_TABLE, {ConnectionPoolName, ConnectionPoolSize}),

  %%FIXME: what if one a connection failed, return like this, extern the connection pool timeout
%%  [{ok,<0.565.0>},
%%{ok,<0.570.0>},
%%{ok,<0.573.0>},
%%{ok,<0.576.0>},
%%{ok,<0.579.0>},
%%{ok,<0.582.0>},
%%{ok,<0.585.0>},
%%{ok,<0.588.0>},
%%{ok,<0.591.0>},
%%{error,timeout},
%%{ok,<0.597.0>},
%%{ok,<0.600.0>},
%%{ok,<0.603.0>},
%%{ok,<0.606.0>},
%%{ok,<0.609.0>},
%%{ok,<0.612.0>},
%%{ok,<0.615.0>},
%%{ok,<0.618.0>},
%%{ok,<0.621.0>},
%%{ok,<0.624.0>}]
  ConnectionNameList = generate_connection_name_list(ConnectionPoolName, ConnectionPoolSize),
%%  lists:map(fun(ConnectionName) ->
%%    connect(cert, ConnectionName, CertFilePath, KeyFilePath, AppleHost) end, ConnectionNameList).
  lists:map(fun(ConnectionName) ->
    spawn(apns, connect, [cert, ConnectionName, CertFilePath, KeyFilePath, AppleHost]) end, ConnectionNameList).


%% @doc Closes the connection with APNs service.
-spec close_connection(apns_connection:name()) -> ok.
close_connection(ConnectionName) ->
  apns_connection:close_connection(ConnectionName).

%% @doc Push notification to APNs. It will use the headers provided on the
%%      environment variables.
-spec push_notification( apns_connection:name()
                       , device_id()
                       , json()
                       ) -> response().
push_notification(ConnectionName, DeviceId, JSONMap) ->
  Headers = default_headers(),
  push_notification(ConnectionName, DeviceId, JSONMap, Headers).

%% @doc Push notification to certificate APNs Connection.
-spec push_notification( apns_connection:name()
                       , device_id()
                       , json()
                       , headers()
                       ) -> response().
push_notification(ConnectionName, DeviceId, JSONMap, Headers) ->
  Notification = jsx:encode(JSONMap),
  apns_connection:push_notification( ConnectionName
                                   , DeviceId
                                   , Notification
                                   , Headers
                                   ).

-spec push_notification_in_pool( apns_connection:name()
                              , integer()
                              , device_id()
                              , json()
                              , headers()
                              ) -> response().
push_notification_in_pool(ConnectionPoolName, ConnectionPoolSize, DeviceId, JSONMap, Headers) ->
  Notification = jsx:encode(JSONMap),
  EtsResult  = ets:lookup(?APNS_CONNECTION_POOL_TABLE, ConnectionPoolName),

  lager:debug("EtsResult:~p", [EtsResult]),

  case ets:lookup(?APNS_CONNECTION_POOL_TABLE, ConnectionPoolName) of
    [{ConnectionPoolName, ConnectionPoolSize}] ->

      ConnectionName = list_to_atom(atom_to_list(ConnectionPoolName) ++ integer_to_list(random:uniform(ConnectionPoolSize))),
      lager:debug("send to connection name:~p", [ConnectionPoolName]),

      Result = apns_connection:push_notification( ConnectionName
        , DeviceId
        , Notification
        , Headers),

      lagere:debug("Resutl:~p, ConnectionName:~p", [Result, ConnectionPoolName]);

    [] ->
      {error, not_created};
    _ ->
      lager:error("push_notification_in_pool error")
  end.

%% @doc Push notification to APNs with authentication token. It will use the
%%      headers provided on the environment variables.
%% delete this API
-spec push_notification_token( apns_connection:name()
                             , token()
                             , device_id()
                             , json()
                             ) -> response().
push_notification_token(ConnectionName, Token, DeviceId, JSONMap) ->
  Headers = default_headers(),
  push_notification_token(ConnectionName, Token, DeviceId, JSONMap, Headers).

%% @doc Push notification to authentication token APNs Connection.
-spec push_notification_token( apns_connection:name()
                             , token()
                             , device_id()
                             , json()
                             , headers()
                             ) -> response().
push_notification_token(ConnectionName, Token, DeviceId, JSONMap, Headers) ->
  Notification = jsx:encode(JSONMap),
  apns_connection:push_notification( ConnectionName
                                   , Token
                                   , DeviceId
                                   , Notification
                                   , Headers
                                   ).

-spec generate_token(binary(), binary()) -> token().
generate_token(TeamId, KeyId) ->
  Algorithm = <<"ES256">>,
  Header = jsx:encode([ {alg, Algorithm}
                      , {typ, <<"JWT">>}
                      , {kid, KeyId}
                      ]),
  Payload = jsx:encode([ {iss, TeamId}
                       , {iat, apns_utils:epoch()}
                       ]),
  HeaderEncoded = base64url:encode(Header),
  PayloadEncoded = base64url:encode(Payload),
  DataEncoded = <<HeaderEncoded/binary, $., PayloadEncoded/binary>>,
  Signature = apns_utils:sign(DataEncoded),
  <<DataEncoded/binary, $., Signature/binary>>.

%% @doc Get the default headers from environment variables.
-spec default_headers() -> apns:headers().
default_headers() ->
  Headers = [ apns_id
            , apns_expiration
            , apns_priority
            , apns_topic
            , apns_collapse_id
            ],

  default_headers(Headers, #{}).

%% Requests for feedback to APNs. This requires Provider Certificate.
%% This application is not suportted
-spec get_feedback() -> [feedback()] | {error, term()} | timeout.
get_feedback() ->
  Timeout = ?TIMEOUT,
  apns_feedback:get_feedback(Timeout).

%%%===================================================================
%%% Internal Functions
%%%===================================================================

%% Connects to APNs service
-spec connect(apns_connection:connection()) -> {ok, pid()} | {error, timeout}.
connect(Connection) ->
  {ok, _} = apns_sup:create_connection(Connection),
  Server = whereis(apns_connection:name(Connection)),
  apns_connection:wait_apns_connection_up(Server).

%% Build a headers() structure from environment variables.
-spec default_headers(list(), headers()) -> headers().
default_headers([], Headers) ->
  Headers;
default_headers([Key | Keys], Headers) ->
  case application:get_env(apns, Key) of
    {ok, undefined} ->
      default_headers(Keys, Headers);
    {ok, Value} ->
      NewHeaders = Headers#{Key => to_binary(Value)},
      default_headers(Keys, NewHeaders)
  end.

%% Convert to binary
to_binary(Value) when is_integer(Value) ->
  list_to_binary(integer_to_list(Value));
to_binary(Value) when is_list(Value) ->
  list_to_binary(Value);
to_binary(Value) when is_binary(Value) ->
  Value.



%%FIXME: what if diffierent appkey have a same Generated_connection_name?
generate_connection_name_list(ConnectionPoolName, ConnectionPoolSize) ->
  generate_connection_name_list(ConnectionPoolName, ConnectionPoolSize, []).

generate_connection_name_list(ConnectionPoolName, ConnectionPoolSize, Generated_connection_name_list) ->
  case ConnectionPoolSize >= 1  of
    true ->
      ConnectionName = list_to_atom(atom_to_list(ConnectionPoolName) ++ integer_to_list(ConnectionPoolSize)),
      generate_connection_name_list(ConnectionPoolName, ConnectionPoolSize - 1, [ConnectionName] ++ Generated_connection_name_list);
    false ->
      Generated_connection_name_list
  end.


