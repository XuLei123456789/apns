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
        , close_connection/1
%%        , push_notification/3
        , push_notification/4
        , create_connection_pool/5
        , connect_and_push_notification/8
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
  lager:debug("message"),
  CustomConnection = apns_connection:custom_connection(cert, ConnectionName, CertFilePath, KeyFilePath, AppleHost),
  connect(CustomConnection).

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

%%UniqueConnectionName is atom
connect_and_push_notification(UniqueConnectionName, ConnectionPoolSize, CertFilePath, KeyFilePath, AppleHost , DeviceId, JSONMap, Headers) ->
  case ets:info(UniqueConnectionName) of
    undefined ->
      create_connection_pool(UniqueConnectionName, ConnectionPoolSize, CertFilePath, KeyFilePath, AppleHost);
    _ ->
      do_noting
  end,

  case ets:first(UniqueConnectionName) of
    AvaiableConnection ->
      ets:delete(UniqueConnectionName, AvaiableConnection),
      push_notification(AvaiableConnection, DeviceId, JSONMap, Headers),
      ets:insert(UniqueConnectionName, {AvaiableConnection});
    '$end_of_table' ->
      create_more_process,
      use_the_connection_to_send_message,
      lager:error("process_use_up")
  end.

%%TODO: what if reconnect? reflush the ets table
create_connection_pool(UniqueConnectionName, ConnectionPoolSize, CertFilePath, KeyFilePath, AppleHost) ->
  ets:new(UniqueConnectionName, [public, {read_concurrency, true}, {write_concurrency, true}, named_table]),

  ets:give_away(UniqueConnectionName, whereis(apns_sup), []),

  ConnectionNameList = generate_connection_name_list(UniqueConnectionName, ConnectionPoolSize),

  lists:map(fun(ConnectionName) ->
    case connect(cert, ConnectionName, CertFilePath, KeyFilePath, AppleHost) of
      {ok, ConnectionPid} ->
        ets:insert(UniqueConnectionName, {ConnectionPid});
      {error, timeout} ->
        lager:debug("start connection timeout")
    end
    end, ConnectionNameList).


%%loop_connect(Times, ConnectionName, CertFilePath, KeyFilePath, AppleHost) ->
%%  case Times > 0 of
%%    true ->
%%      case connect(cert, ConnectionName, CertFilePath, KeyFilePath, AppleHost) of
%%        {ok, ConnectionPid} ->
%%          {ok, ConnectionPid};
%%        {error, timeout} ->
%%          loop_connect(Times - 1, ConnectionName, CertFilePath, KeyFilePath, AppleHost)
%%      end;
%%    false ->
%%      {error, timeout}
%%  end.









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