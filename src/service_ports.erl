%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-2018 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% @doc helpers related to ports exposed by various revices

-module(service_ports).

-export([get_port/1,
         get_port/2,
         get_port/3,
         default/2,
         default_config/1,
         find_by_rest_name/1,
         services_port_keys/1,
         get_external_host_and_ports/3,
         get_ports_for_services/3]).

-include("ns_common.hrl").

-record(port, {key, rest, service, default, secure}).
-define(define_port(Key, RestName, Service, Default, Sec),
        #port{key     = Key,
              rest    = rest_name_to_bin(RestName),
              service = Service,
              default = Default,
              secure  = Sec}).

-define(define_port(ConfName, RestName, Service, Default),
        ?define_port(ConfName, RestName, Service, Default, unsecure)).

rest_name_to_bin(undefined) ->
    undefined;
rest_name_to_bin(RestName) ->
    atom_to_binary(RestName, latin1).

all_ports() ->
    [%% rest service ports
     ?define_port(rest_port,     mgmt,    rest, 8091),
     ?define_port(ssl_rest_port, mgmtSSL, rest, 18091, secure),
     %% xdcr ports
     ?define_port(xdcr_rest_port, undefined, xdcr, 9998),
     %% kv service ports
     ?define_port(memcached_port,           kv,        kv, 11210),
     ?define_port(memcached_ssl_port,       kvSSL,     kv, 11207, secure),
     ?define_port(memcached_dedicated_port, undefined, kv, 11209),
     ?define_port(capi_port,                capi,      kv, 8092),
     ?define_port(ssl_capi_port,            capiSSL,   kv, 18092, secure),
     ?define_port(projector_port,           projector, kv, 9999),
     %% query service ports
     ?define_port(query_port,     n1ql,    n1ql, 8093),
     ?define_port(ssl_query_port, n1qlSSL, n1ql, 18093, secure),
     %% index service ports
     ?define_port(indexer_admin_port,     indexAdmin,         index, 9100),
     ?define_port(indexer_scan_port,      indexScan,          index, 9101),
     ?define_port(indexer_http_port,      indexHttp,          index, 9102),
     ?define_port(indexer_stinit_port,    indexStreamInit,    index, 9103),
     ?define_port(indexer_stcatchup_port, indexStreamCatchup, index, 9104),
     ?define_port(indexer_stmaint_port,   indexStreamMaint,   index, 9105),
     ?define_port(indexer_https_port,     indexHttps,         index, 19102,
                  secure),
     %% fts service ports
     ?define_port(fts_http_port, fts,    fts, 8094),
     ?define_port(fts_ssl_port,  ftsSSL, fts, 18094, secure),
     %% eventing service ports
     ?define_port(eventing_http_port,  eventingAdminPort, eventing, 8096),
     ?define_port(eventing_debug_port, eventingDebug,     eventing, 9140),
     ?define_port(eventing_https_port, eventingSSL,       eventing, 18096,
                  secure),
     %% cbas service ports
     ?define_port(cbas_http_port,    cbas,      cbas, 8095),
     ?define_port(cbas_admin_port,   cbasAdmin, cbas, 9110),
     ?define_port(cbas_cc_http_port, cbasCc,    cbas, 9111),
     ?define_port(cbas_ssl_port,     cbasSSL,   cbas, 18095, secure),
     %% miscellaneous cbas ports
     ?define_port(cbas_cc_cluster_port,        cbasCcCluster,   misc, 9112),
     ?define_port(cbas_cc_client_port,         cbasCcClient,    misc, 9113),
     ?define_port(cbas_console_port,           cbasConsole,     misc, 9114),
     ?define_port(cbas_cluster_port,           cbasCluster,     misc, 9115),
     ?define_port(cbas_data_port,              cbasData,        misc, 9116),
     ?define_port(cbas_result_port,            cbasResult,      misc, 9117),
     ?define_port(cbas_messaging_port,         cbasMessaging,   misc, 9118),
     ?define_port(cbas_metadata_callback_port, undefined,       misc, 9119),
     ?define_port(cbas_replication_port,       cbasReplication, misc, 9120),
     ?define_port(cbas_metadata_port,          undefined,       misc, 9121),
     ?define_port(cbas_parent_port,            cbasParent,      misc, 9122),
     ?define_port(cbas_debug_port,             cbasDebug,       misc, -1)
    ].

config_key(memcached_port) ->
    {memcached, port};
config_key(memcached_ssl_port) ->
    {memcached, ssl_port};
config_key(memcached_dedicated_port) ->
    {memcached, dedicated_port};
config_key(Key) ->
    Key.

complex_config_key(Key) ->
    config_key(Key) =/= Key.

default(Key, IsEnterprise) ->
    default(Key, lists:keyfind(Key, #port.key, all_ports()), IsEnterprise).

default(_Key, #port{secure = secure}, false = _IsEnterprise) ->
    undefined;
default(Key, #port{default = Default}, _IsEnterprise) ->
    misc:get_env_default(Key, Default).

default_config(#port{key = rest_port, default = Default}, _IsEnterprise) ->
    PortMeta = case application:get_env(rest_port) of
                   {ok, _Port} -> local;
                   undefined -> global
               end,
    [{rest, [{port, Default}]},
     {{node, node(), rest},
      [{port, misc:get_env_default(rest_port, Default)},
       {port_meta, PortMeta}]}];
default_config(#port{key = Key} = P, IsEnterprise) ->
    [{{node, node(), Key}, default(Key, P, IsEnterprise)}].

default_config(IsEnterprise) ->
    lists:flatmap(fun (#port{key = Key} = P) ->
                          case complex_config_key(Key) of
                              true ->
                                  [];
                              false ->
                                  default_config(P, IsEnterprise)
                          end
                  end, all_ports()).

get_port(Key) ->
    get_port(Key, ns_config:latest()).

get_port(Key, Config) ->
    get_port(Key, Config, node()).

get_port(rest_port, Config, Node) ->
    case ns_config:search_node_prop(Node, Config, rest, port_meta, local) of
        local ->
            ns_config:search_node_prop(Node, Config, rest, port, 8091);
        global ->
            ns_config:search_prop(Config, rest, port, 8091)
    end;
get_port(Key, Config, Node) ->
    case config_key(Key) of
        {K, S} ->
            ns_config:search_node_prop(Node, Config, K, S);
        K ->
            ns_config:search_node_with_default(Node, Config, K, undefined)
    end.

services_port_keys(Services) ->
    AllPorts = all_ports(),
    [P#port.key || P <- AllPorts, lists:member(P#port.service, Services)].

find_by_rest_name(RestName) when is_list(RestName) ->
    RestNameBin = list_to_binary(RestName),
    case lists:keyfind(RestNameBin, #port.rest, all_ports()) of
        false ->
            undefined;
        Port ->
            Port#port.key
    end.

get_internal_ports(Node, Config) ->
    Services = ns_cluster_membership:node_active_services(Config, Node),
    get_ports_for_services_int(Node, Config, [rest | Services]).

get_external_host_and_ports(Node, Config, WantedPorts) ->
    External = ns_config:search_node_prop(Node, Config,
                                          alternate_addresses, external,
                                          []),
    Hostname = proplists:get_value(hostname, External),
    Ports =
        case proplists:get_value(ports, External, []) of
            [] when Hostname =/= undefined ->
                [{Rest, Value} ||
                    {#port{key = Key, rest = Rest}, Value} <-
                        get_internal_ports(Node, Config),
                    lists:member(Key, WantedPorts)];
            ExtPorts ->
                AllPorts = all_ports(),
                lists:filtermap(
                  fun (Key) ->
                          case lists:keyfind(Key, 1, ExtPorts) of
                              false ->
                                  false;
                              {Key, Value} ->
                                  P = lists:keyfind(Key, #port.key, AllPorts),
                                  {true, {P#port.rest, Value}}
                          end
                  end, WantedPorts)
        end,
    {Hostname, Ports}.

get_ports_for_services_int(Node, Config, Services) ->
    AllPorts = all_ports(),
    lists:flatmap(
      fun (Service) ->
              ServicePorts = [P || P <- AllPorts, P#port.service =:= Service],
              lists:filtermap(
                fun (#port{rest = undefined}) ->
                        false;
                    (#port{key = Key} = P) ->
                        case get_port(Key, Config, Node) of
                            undefined ->
                                false;
                            Port ->
                                {true, {P, Port}}
                        end
                end, ServicePorts)
      end, Services).

get_ports_for_services(Node, Config, Services) ->
    [{RestKey, Port} ||
        {#port{rest = RestKey}, Port}
            <- get_ports_for_services_int(Node, Config, Services)].
