%% @author Couchbase <info@couchbase.com>
%% @copyright 2016-2018 Couchbase, Inc.
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
%%

%% @doc rest api's for rbac and ldap support

-module(menelaus_web_rbac).

-include("ns_common.hrl").
-include("pipes.hrl").
-include("rbac.hrl").

-include_lib("cut.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([handle_saslauthd_auth_settings/1,
         handle_saslauthd_auth_settings_post/1,
         handle_validate_saslauthd_creds_post/1,
         handle_get_roles/1,
         handle_get_users/2,
         handle_get_users/3,
         handle_get_user/3,
         handle_whoami/1,
         handle_put_user/3,
         handle_delete_user/3,
         handle_change_password/1,
         handle_settings_read_only_admin_name/1,
         handle_settings_read_only_user_post/1,
         handle_read_only_user_delete/1,
         handle_read_only_user_reset/1,
         handle_reset_admin_password/1,
         handle_check_permissions_post/1,
         check_permissions_url_version/1,
         handle_check_permission_for_cbauth/1,
         forbidden_response/1,
         role_to_string/1,
         validate_cred/2,
         handle_get_password_policy/1,
         handle_post_password_policy/1,
         assert_no_users_upgrade/0,
         domain_to_atom/1,
         handle_put_group/2,
         handle_delete_group/2,
         handle_get_groups/2,
         handle_get_group/2,
         handle_ldap_settings/1,
         handle_ldap_settings_post/1,
         handle_ldap_settings_validate_post/2]).

-define(MIN_USERS_PAGE_SIZE, 2).
-define(MAX_USERS_PAGE_SIZE, 100).

-define(SECURITY_READ, {[admin, security, admin], read}).
-define(SECURITY_WRITE, {[admin, security, admin], write}).

assert_is_saslauthd_enabled() ->
    case cluster_compat_mode:is_saslauthd_enabled() of
        true ->
            ok;
        false ->
            erlang:throw(
              {web_exception,
               400,
               "This http API endpoint is only supported in enterprise edition "
               "running on GNU/Linux",
               []})
    end.

handle_saslauthd_auth_settings(Req) ->
    assert_is_saslauthd_enabled(),

    menelaus_util:reply_json(Req, {saslauthd_auth:build_settings()}).

extract_user_list(undefined) ->
    asterisk;
extract_user_list(String) ->
    StringNoCR = [C || C <- String, C =/= $\r],
    Strings = string:tokens(StringNoCR, "\n"),
    [B || B <- [list_to_binary(string:trim(S)) || S <- Strings],
          B =/= <<>>].

parse_validate_saslauthd_settings(Params) ->
    EnabledR = case menelaus_util:parse_validate_boolean_field(
                      "enabled", enabled, Params) of
                   [] ->
                       [{error, enabled, <<"is missing">>}];
                   EnabledX -> EnabledX
               end,
    [AdminsParam, RoAdminsParam] =
        case EnabledR of
            [{ok, enabled, false}] ->
                ["", ""];
            _ ->
                [proplists:get_value(K, Params) || K <- ["admins", "roAdmins"]]
        end,
    Admins = extract_user_list(AdminsParam),
    RoAdmins = extract_user_list(RoAdminsParam),
    MaybeExtraFields =
        case proplists:get_keys(Params) -- ["enabled", "roAdmins", "admins"] of
            [] ->
                [];
            UnknownKeys ->
                Msg =
                    io_lib:format("failed to recognize the following fields ~s",
                                  [string:join(UnknownKeys, ", ")]),
                [{error, '_', iolist_to_binary(Msg)}]
        end,
    MaybeTwoAsterisks =
        case Admins =:= asterisk andalso RoAdmins =:= asterisk of
            true ->
                [{error, 'admins',
                  <<"at least one of admins or roAdmins needs to be given">>}];
            false ->
                []
        end,
    Everything = EnabledR ++ MaybeExtraFields ++ MaybeTwoAsterisks,
    case [{Field, Msg} || {error, Field, Msg} <- Everything] of
        [] ->
            [{ok, enabled, Enabled}] = EnabledR,
            {ok, [{enabled, Enabled},
                  {admins, Admins},
                  {roAdmins, RoAdmins}]};
        Errors ->
            {errors, Errors}
    end.

handle_saslauthd_auth_settings_post(Req) ->
    assert_is_saslauthd_enabled(),

    case parse_validate_saslauthd_settings(mochiweb_request:parse_post(Req)) of
        {ok, Props} ->
            saslauthd_auth:set_settings(Props),
            ns_audit:setup_saslauthd(Req, Props),
            handle_saslauthd_auth_settings(Req);
        {errors, Errors} ->
            menelaus_util:reply_json(Req, {Errors}, 400)
    end.

handle_validate_saslauthd_creds_post(Req) ->
    assert_is_saslauthd_enabled(),
    case cluster_compat_mode:is_cluster_45() of
        true ->
            erlang:throw(
              {web_exception,
               400,
               "This http API endpoint is not supported in 4.5 clusters", []});
        false ->
            ok
    end,

    Params = mochiweb_request:parse_post(Req),
    User = proplists:get_value("user", Params, ""),
    VRV = menelaus_auth:verify_login_creds(
            User, proplists:get_value("password", Params, "")),

    {Role, Src} =
        case VRV of
            {ok, {_, external}} ->
                {saslauthd_auth:get_role_pre_45(User), saslauthd};
            {ok, {_, R}} ->
                {R, builtin};
            {error, Error} ->
                erlang:throw({web_exception, 400, Error, []});
            _ ->
                {false, builtin}
        end,
    JRole = case Role of
                admin ->
                    fullAdmin;
                ro_admin ->
                    roAdmin;
                false ->
                    none
            end,
    menelaus_util:reply_json(Req, {[{role, JRole}, {source, Src}]}).

role_to_json(Name) when is_atom(Name) ->
    [{role, Name}];
role_to_json({Name, [any]}) ->
    [{role, Name}, {bucket_name, <<"*">>}];
role_to_json({Name, [{BucketName, _Id}]}) ->
    [{role, Name}, {bucket_name, list_to_binary(BucketName)}];
role_to_json({Name, [BucketName]}) ->
    [{role, Name}, {bucket_name, list_to_binary(BucketName)}].

role_to_json(Role, Origins) ->
    role_to_json(Role) ++
    [{origins, [role_origin_to_json(O) || O <- Origins]}
        || Origins =/= []].

role_origin_to_json(user) ->
    {[{type, user}]};
role_origin_to_json(O) ->
    {[{type, group}, {name, list_to_binary(O)}]}.

get_roles_by_permission(Permission) ->
    Config = ns_config:get(),
    Buckets = ns_bucket:get_buckets(Config),
    pipes:run(
      menelaus_roles:produce_roles_by_permission(Permission, Config, Buckets),
      pipes:collect()).

assert_api_can_be_used() ->
    menelaus_util:assert_is_45(),
    case cluster_compat_mode:is_cluster_50() of
        true ->
            ok;
        false ->
            menelaus_util:assert_is_enterprise()
    end.

handle_get_roles(Req) ->
    assert_api_can_be_used(),

    validator:handle(
      fun (Values) ->
              Permission = proplists:get_value(permission, Values),
              Roles =
                  get_roles_by_permission(Permission) --
                  case menelaus_auth:has_permission(?SECURITY_READ, Req) of
                      true ->
                          [];
                      false ->
                          menelaus_roles:get_security_roles()
                  end,
              Json =
                  [{role_to_json(Role) ++ Props} || {Role, Props} <- Roles],
              menelaus_util:reply_json(Req, Json)
      end, Req, qs, get_users_or_roles_validators()).

user_to_json({Id, Domain}, Props) ->
    IsMadHatter = cluster_compat_mode:is_cluster_madhatter(),
    RolesJson = user_roles_to_json(Props, IsMadHatter),
    Name = proplists:get_value(name, Props),
    Groups = proplists:get_value(groups, Props),
    Passwordless = proplists:get_value(passwordless, Props),
    PassChangeTime = format_password_change_time(
                       proplists:get_value(password_change_timestamp, Props)),

    {[{id, list_to_binary(Id)},
      {domain, Domain},
      {roles, RolesJson}] ++
     [{groups, [list_to_binary(G) || G <- Groups]} || Groups =/= undefined,
                                                      IsMadHatter] ++
     [{name, list_to_binary(Name)} || Name =/= undefined] ++
     [{passwordless, Passwordless} || Passwordless == true] ++
     [{password_change_date, PassChangeTime} || PassChangeTime =/= undefined]}.

user_roles_to_json(Props, true) ->
    UserRoles = proplists:get_value(user_roles, Props, []),
    GroupRoles = proplists:get_value(group_roles, Props, []),
    AddOrigin =
        fun (Origin, List, AccMap) ->
                lists:foldl(
                  fun (R, Acc) ->
                          maps:put(R, [Origin|maps:get(R, Acc, [])], Acc)
                  end, AccMap, List)
        end,
    Map = lists:foldl(
             fun ({G, R}, Acc) ->
                AddOrigin(G, R, Acc)
             end, #{}, [{user, UserRoles} | GroupRoles]),
    maps:fold(
       fun (Role, Origins, Acc) ->
           [{role_to_json(Role, Origins)}|Acc]
       end, [], Map);
user_roles_to_json(Props, false) ->
    UserRoles = proplists:get_value(user_roles, Props, []),
    [{role_to_json(Role)} || Role <- UserRoles].

format_password_change_time(undefined) -> undefined;
format_password_change_time(TS) ->
    Local = calendar:now_to_local_time(misc:time_to_timestamp(TS, millisecond)),
    menelaus_util:format_server_time(Local).

handle_get_users(Path, Req) ->
    assert_api_can_be_used(),

    case cluster_compat_mode:is_cluster_50() of
        true ->
            handle_get_users_with_domain(Req, '_', Path);
        false ->
            handle_get_users_45(Req)
    end.

get_users_or_roles_validators() ->
    [validate_permission(permission, _)].

get_users_page_validators(DomainAtom, HasStartFrom) ->
    [validator:integer(pageSize, ?MIN_USERS_PAGE_SIZE, ?MAX_USERS_PAGE_SIZE, _),
     validator:touch(startFrom, _)] ++
        case HasStartFrom of
            false ->
                [];
            true ->
                case DomainAtom of
                    '_' ->
                        [validator:required(startFromDomain, _),
                         validator:one_of(startFromDomain, known_domains(), _),
                         validator:convert(startFromDomain, fun list_to_atom/1,
                                           _)];
                    _ ->
                        [validator:prohibited(startFromDomain, _),
                         validator:return_value(startFromDomain, DomainAtom, _)]
                end
        end ++ get_users_or_roles_validators().

validate_permission(Name, State) ->
    validator:validate(
      fun (RawPermission) ->
              case parse_permission(RawPermission) of
                  error ->
                      {error, "Malformed permission"};
                  Permission ->
                      {value, Permission}
              end
      end, Name, State).

handle_get_users(Path, Domain, Req) ->
    menelaus_util:assert_is_50(),

    case domain_to_atom(Domain) of
        unknown ->
            menelaus_util:reply_json(Req, <<"Unknown user domain.">>, 404);
        DomainAtom ->
            handle_get_users_with_domain(Req, DomainAtom, Path)
    end.

get_roles_for_users_filtering(undefined) ->
    all;
get_roles_for_users_filtering(Permission) ->
    get_roles_by_permission(Permission).

handle_get_users_with_domain(Req, DomainAtom, Path) ->
    Query = mochiweb_request:parse_qs(Req),
    case lists:keyfind("pageSize", 1, Query) of
        false ->
            validator:handle(
              handle_get_all_users(Req, {'_', DomainAtom}, _), Req, Query,
              get_users_or_roles_validators());
        _ ->
            HasStartFrom = lists:keyfind("startFrom", 1, Query) =/= false,
            validator:handle(
              handle_get_users_page(Req, DomainAtom, Path, _),
              Req, Query, get_users_page_validators(DomainAtom, HasStartFrom))
    end.

handle_get_users_45(Req) ->
    Users = menelaus_users:get_users_45(ns_config:latest()),
    Json = lists:map(
             fun ({{LdapUser, saslauthd}, Props}) ->
                     NewProps = lists:map(fun ({roles, R}) -> {user_roles, R};
                                              (P) -> P
                                          end, Props),
                     user_to_json({LdapUser, external}, NewProps)
             end, Users),
    menelaus_util:reply_json(Req, Json).

security_filter(Req) ->
    case menelaus_auth:has_permission(?SECURITY_READ, Req) of
        true ->
            pipes:filter(fun (_) -> true end);
        false ->
            SecurityRoles = get_security_roles(),
            pipes:filter(
              fun ({_, Props}) ->
                      Roles = proplists:get_value(roles, Props, []),
                      UserRoles = proplists:get_value(user_roles, Props, []),
                      GroupsWRoles =
                          proplists:get_value(group_roles, Props, []),
                      GroupRoles = lists:concat([R || {_, R} <- GroupsWRoles]),
                      AllRoles = lists:usort(Roles ++ UserRoles ++ GroupRoles),
                      not overlap(AllRoles, SecurityRoles)
              end)
    end.

handle_get_all_users(Req, Pattern, Params) ->
    Roles = get_roles_for_users_filtering(
              proplists:get_value(permission, Params)),
    pipes:run(menelaus_users:select_users(Pattern),
              [filter_by_roles(Roles),
               security_filter(Req),
               jsonify_users(),
               sjson:encode_extended_json([{compact, true},
                                           {strict, false}]),
               pipes:simple_buffer(2048)],
              menelaus_util:send_chunked(
                Req, 200, [{"Content-Type", "application/json"}])).

handle_get_user(Domain, UserId, Req) ->
    menelaus_util:assert_is_50(),
    case domain_to_atom(Domain) of
        unknown ->
            menelaus_util:reply_json(Req, <<"Unknown user domain.">>, 404);
        DomainAtom ->
            Identity = {UserId, DomainAtom},
            case menelaus_users:user_exists(Identity) of
                false ->
                    menelaus_util:reply_json(Req, <<"Unknown user.">>, 404);
                true ->
                    perform_if_allowed(
                      menelaus_util:reply_json(_, get_user_json(Identity)),
                      Req, ?SECURITY_READ, menelaus_users:get_roles(Identity))
            end
    end.

filter_by_roles(all) ->
    pipes:filter(fun (_) -> true end);
filter_by_roles(Roles) ->
    RoleNames = [Name || {Name, _} <- Roles],
    pipes:filter(
      fun ({{user, _}, Props}) ->
          UserRoles = proplists:get_value(user_roles, Props, []),
          GroupsAndRoles = proplists:get_value(group_roles, Props, []),
          GroupRoles = lists:concat([R || {_, R} <- GroupsAndRoles]),
          overlap(RoleNames, lists:usort(UserRoles ++ GroupRoles))
      end).

jsonify_users() ->
    ?make_transducer(
       begin
           ?yield(array_start),
           pipes:foreach(
             ?producer(),
             fun ({{user, Identity}, Props}) ->
                     ?yield({json, user_to_json(Identity, Props)})
             end),
           ?yield(array_end)
       end).

-record(skew, {skew, size, less_fun, filter, skipped = 0}).

add_to_skew(_El, undefined) ->
    undefined;
add_to_skew(El, #skew{skew = CouchSkew,
                      size = Size,
                      filter = Filter,
                      less_fun = LessFun,
                      skipped = Skipped} = Skew) ->
    case Filter(El, LessFun) of
        false ->
            Skew#skew{skipped = Skipped + 1};
        true ->
            CouchSkew1 = couch_skew:in(El, LessFun, CouchSkew),
            case couch_skew:size(CouchSkew1) > Size of
                true ->
                    {_, CouchSkew2} = couch_skew:out(LessFun, CouchSkew1),
                    Skew#skew{skew = CouchSkew2};
                false ->
                    Skew#skew{skew = CouchSkew1}
            end
    end.

skew_to_list(#skew{skew = CouchSkew,
                   less_fun = LessFun}) ->
    skew_to_list(CouchSkew, LessFun, []).

skew_to_list(CouchSkew, LessFun, Acc) ->
    case couch_skew:size(CouchSkew) of
        0 ->
            Acc;
        _ ->
            {El, NewSkew} = couch_skew:out(LessFun, CouchSkew),
            skew_to_list(NewSkew, LessFun, [El | Acc])
    end.

skew_size(#skew{skew = CouchSkew}) ->
    couch_skew:size(CouchSkew).

skew_out(#skew{skew = CouchSkew, less_fun = LessFun} = Skew) ->
    {El, NewCouchSkew} = couch_skew:out(LessFun, CouchSkew),
    {El, Skew#skew{skew = NewCouchSkew}}.

skew_min(undefined) ->
    undefined;
skew_min(#skew{skew = CouchSkew}) ->
    case couch_skew:size(CouchSkew) of
        0 ->
            undefined;
        _ ->
            couch_skew:min(CouchSkew)
    end.

skew_skipped(#skew{skipped = Skipped}) ->
    Skipped.

create_skews(Start, PageSize) ->
    SkewThis =
        #skew{
           skew = couch_skew:new(),
           size = PageSize + 1,
           less_fun = fun ({A, _}, {B, _}) ->
                              A >= B
                      end,
           filter = fun (El, LessFun) ->
                            Start =:= undefined orelse LessFun(El, {Start, x})
                    end},
    SkewPrev =
        case Start of
            undefined ->
                undefined;
            _ ->
                #skew{
                   skew = couch_skew:new(),
                   size = PageSize,
                   less_fun = fun ({A, _}, {B, _}) ->
                                      A < B
                              end,
                   filter = fun (El, LessFun) ->
                                    LessFun(El, {Start, x})
                            end}
        end,
    SkewLast =
        #skew{
           skew = couch_skew:new(),
           size = PageSize,
           less_fun = fun ({A, _}, {B, _}) ->
                              A < B
                      end,
           filter = fun (_El, _LessFun) ->
                            true
                    end},
    [SkewPrev, SkewThis, SkewLast].

add_to_skews(El, Skews) ->
    [add_to_skew(El, Skew) || Skew <- Skews].

build_group_links(Links, PageSize, Path) ->
    {[{LinkName, build_pager_link(Path, StartFrom, PageSize, [])}
         || {LinkName, StartFrom} <- Links]}.

build_user_links(Links, PageSize, NeedDomain, Path, Permission) ->
    Extra = [{permission, permission_to_binary(Permission)}
                || Permission =/= undefined],
    Json = lists:map(
             fun ({LinkName, noparams = UName}) ->
                     {LinkName, build_pager_link(Path, UName, PageSize, Extra)};
                 ({LinkName, {UName, Domain}}) ->
                     DomainParams = [{startFromDomain, Domain} || NeedDomain],
                     {LinkName, build_pager_link(Path, UName, PageSize,
                                                 Extra ++ DomainParams)}
             end, Links),
    {Json}.

build_pager_link(Path, StartObj, PageSize, ExtraParams) ->
    PaginatorParams = format_paginator_params(StartObj, PageSize),
    Params = mochiweb_util:urlencode(ExtraParams ++ PaginatorParams),
    iolist_to_binary(io_lib:format("/~s?~s", [Path, Params])).

format_paginator_params(noparams, PageSize) ->
    [{pageSize, PageSize}];
format_paginator_params(ObjName, PageSize) ->
    [{pageSize, PageSize}, {startFrom, ObjName}].

seed_links(Pairs) ->
    [{Name, Object} || {Name, Object} <- Pairs, Object =/= undefined].

page_data_from_skews([SkewPrev, SkewThis, SkewLast], PageSize) ->
    {Objects, Next} =
        case skew_size(SkewThis) of
            Size when Size =:= PageSize + 1 ->
                {{N, _}, NewSkew} = skew_out(SkewThis),
                {skew_to_list(NewSkew), N};
            _ ->
                {skew_to_list(SkewThis), undefined}
        end,
    {First, Prev} = case skew_min(SkewPrev) of
                        undefined ->
                            {undefined, undefined};
                        {P, _} ->
                            {noparams, P}
                    end,
    {Last, CorrectedNext} =
        case Next of
            undefined ->
                {undefined, Next};
            _ ->
                case skew_min(SkewLast) of
                    {L, _} when L < Next ->
                        {L, L};
                    {L, _} ->
                        {L, Next}
                end
        end,
    {Objects,
     skew_skipped(SkewThis),
     seed_links([{first, First}, {prev, Prev},
                 {next, CorrectedNext}, {last, Last}])}.

handle_get_users_page(Req, DomainAtom, Path, Values) ->
    Start =
        case proplists:get_value(startFrom, Values) of
            undefined ->
                undefined;
            U ->
                {U, proplists:get_value(startFromDomain, Values)}
        end,
    PageSize = proplists:get_value(pageSize, Values),
    Permission = proplists:get_value(permission, Values),
    Roles = get_roles_for_users_filtering(Permission),

    {PageSkews, Total} =
        pipes:run(menelaus_users:select_users({'_', DomainAtom}),
                  [filter_by_roles(Roles),
                   security_filter(Req)],
                  ?make_consumer(
                     pipes:fold(
                       ?producer(),
                       fun ({{user, Identity}, Props}, {Skews, T}) ->
                               {add_to_skews({Identity, Props}, Skews), T + 1}
                       end, {create_skews(Start, PageSize), 0}))),

    UserJson = fun ({Identity, Props}) -> user_to_json(Identity, Props) end,

    {Users, Skipped, Links} = page_data_from_skews(PageSkews, PageSize),
    UsersJson = [UserJson(O) || O <- Users],
    LinksJson = build_user_links(Links, PageSize, DomainAtom == '_',
                                 Path, Permission),
    Json = {[{total, Total},
             {links, LinksJson},
             {skipped, Skipped},
             {users, UsersJson}]},
    menelaus_util:reply_json(Req, Json).

handle_whoami(Req) ->
    Identity = menelaus_auth:get_identity(Req),
    Props = menelaus_users:get_user_props(Identity,
                                          [name, passwordless,
                                           password_change_timestamp]),
    {JSON} = user_to_json(Identity, Props),
    Roles = menelaus_roles:get_roles(Identity),
    RolesJSON = [{roles, [{role_to_json(R)} || R <- Roles]}],
    menelaus_util:reply_json(Req, {misc:update_proplist(JSON, RolesJSON)}).

get_user_json(Identity) ->
    user_to_json(Identity, menelaus_users:get_user_props(Identity)).

parse_until(Str, Delimeters) ->
    lists:splitwith(fun (Char) ->
                            not lists:member(Char, Delimeters)
                    end, Str).

role_to_atom(Role) ->
    list_to_existing_atom(string:to_lower(Role)).

parse_role(RoleRaw) ->
    try
        case parse_until(RoleRaw, "[") of
            {Role, []} ->
                role_to_atom(Role);
            {Role, "[*]"} ->
                {role_to_atom(Role), [any]};
            {Role, [$[ | ParamAndBracket]} ->
                case parse_until(ParamAndBracket, "]") of
                    {Param, "]"} ->
                        {role_to_atom(Role), [Param]};
                    _ ->
                        {error, RoleRaw}
                end
        end
    catch error:badarg ->
            {error, RoleRaw}
    end.

parse_roles(undefined) ->
    [];
parse_roles(RolesStr) ->
    RolesRaw = string:tokens(RolesStr, ","),
    [parse_role(string:trim(RoleRaw)) || RoleRaw <- RolesRaw].

role_to_string(Role) when is_atom(Role) ->
    atom_to_list(Role);
role_to_string({Role, [any]}) ->
    lists:flatten(io_lib:format("~p[*]", [Role]));
role_to_string({Role, [{BucketName, _}]}) ->
    role_to_string({Role, [BucketName]});
role_to_string({Role, [BucketName]}) ->
    lists:flatten(io_lib:format("~p[~s]", [Role, BucketName])).

known_domains() ->
    ["local", "external"].

domain_to_atom(Domain) ->
    case lists:member(Domain, known_domains()) of
        true ->
            list_to_atom(Domain);
        false ->
            unknown
    end.

verify_length([P, Len]) ->
    length(P) >= Len.

verify_control_chars(P) ->
    lists:all(
      fun (C) ->
              C > 31 andalso C =/= 127
      end, P).

verify_utf8(P) ->
    couch_util:validate_utf8(P).

verify_lowercase(P) ->
    string:to_upper(P) =/= P.

verify_uppercase(P) ->
    string:to_lower(P) =/= P.

verify_digits(P) ->
    lists:any(
      fun (C) ->
              C > 47 andalso C < 58
      end, P).

password_special_characters() ->
    "@%+\\/'\"!#$^?:,(){}[]~`-_".

verify_special(P) ->
    lists:any(
      fun (C) ->
              lists:member(C, password_special_characters())
      end, P).

get_verifier(uppercase, P) ->
    {fun verify_uppercase/1, P,
     <<"The password must contain at least one uppercase letter">>};
get_verifier(lowercase, P) ->
    {fun verify_lowercase/1, P,
     <<"The password must contain at least one lowercase letter">>};
get_verifier(digits, P) ->
    {fun verify_digits/1, P,
     <<"The password must contain at least one digit">>};
get_verifier(special, P) ->
    {fun verify_special/1, P,
     list_to_binary(
       "The password must contain at least one of the following characters: " ++
           password_special_characters())}.

execute_verifiers([]) ->
    true;
execute_verifiers([{Fun, Arg, Error} | Rest]) ->
    case Fun(Arg) of
        true ->
            execute_verifiers(Rest);
        false ->
            Error
    end.

get_password_policy() ->
    {value, Policy} = ns_config:search(password_policy),
    MinLength = proplists:get_value(min_length, Policy),
    true = (MinLength =/= undefined),
    MustPresent = proplists:get_value(must_present, Policy),
    true = (MustPresent =/= undefined),
    {MinLength, MustPresent}.

validate_cred(undefined, _) -> <<"Field must be given">>;
validate_cred(P, password) ->
    is_valid_password(P, get_password_policy());
validate_cred(Username, username) ->
    validate_id(Username, <<"Username">>).

validate_id([], Fieldname) ->
    <<Fieldname/binary, " must not be empty">>;
validate_id(Id, Fieldname) when length(Id) > 128 ->
    <<Fieldname/binary, " may not exceed 128 characters">>;
validate_id(Id, Fieldname) ->
    V = lists:all(
          fun (C) ->
                  C > 32 andalso C =/= 127 andalso
                      not lists:member(C, "()<>@,;:\\\"/[]?={}")
          end, Id)
        andalso couch_util:validate_utf8(Id),

    V orelse
        <<Fieldname/binary, " must not contain spaces, control or any of "
          "()<>@,;:\\\"/[]?={} characters and must be valid utf8">>.

is_valid_password(P, {MinLength, MustPresent}) ->
    LengthError = io_lib:format(
                    "The password must be at least ~p characters long.",
                    [MinLength]),

    Verifiers =
        [{fun verify_length/1, [P, MinLength], list_to_binary(LengthError)},
         {fun verify_utf8/1, P, <<"The password must be valid utf8">>},
         {fun verify_control_chars/1, P,
          <<"The password must not contain control characters">>}] ++
        [get_verifier(V, P) || V <- MustPresent],

    execute_verifiers(Verifiers).

handle_put_user(Domain, UserId, Req) ->
    assert_api_can_be_used(),
    assert_no_users_upgrade(),

    case validate_cred(UserId, username) of
        true ->
            case domain_to_atom(Domain) of
                unknown ->
                    menelaus_util:reply_json(Req, <<"Unknown user domain.">>,
                                             404);
                external = T ->
                    menelaus_util:assert_is_enterprise(),
                    handle_put_user_with_identity({UserId, T}, Req);
                local = T ->
                    menelaus_util:assert_is_50(),
                    handle_put_user_with_identity({UserId, T}, Req)
            end;
        Error ->
            menelaus_util:reply_global_error(Req, Error)
    end.

validate_password(State) ->
    validator:validate(
      fun (P) ->
              case validate_cred(P, password) of
                  true ->
                      ok;
                  Error ->
                      {error, Error}
              end
      end, password, State).

put_user_validators(Domain) ->
    [validator:touch(name, _),
     validate_user_groups(groups, _),
     validator:required(roles, _),
     validate_roles(roles, _)] ++
        case Domain of
            local ->
                [validate_password(_)];
            external ->
                []
        end ++
        [validator:unsupported(_)].

bad_roles_error(BadRoles) ->
    Str = string:join(BadRoles, ","),
    io_lib:format(
      "Cannot assign roles to user because the following roles are unknown,"
      " malformed or role parameters are undefined: [~s]", [Str]).

validate_user_groups(Name, State) ->
    IsMadHatter = cluster_compat_mode:is_cluster_madhatter(),
    IsEnterprise = cluster_compat_mode:is_enterprise(),
    validator:validate(
      fun (_) when not IsEnterprise ->
              {error, "User groups require enterprise edition"};
          (_) when not IsMadHatter ->
              {error, "User groups are not supported in "
                      "mixed version clusters"};
          (GroupsRaw) ->
              Groups = parse_groups(GroupsRaw),
              case lists:filter(?cut(not menelaus_users:group_exists(_)),
                                Groups) of
                  [] -> {value, Groups};
                  BadGroups ->
                      BadGroupsStr = string:join(BadGroups, ","),
                      ErrorStr = io_lib:format("Groups do not exist: ~s",
                                               [BadGroupsStr]),
                      {error, ErrorStr}
              end
      end, Name, State).

parse_groups(GroupsStr) ->
    GroupsTokens = string:tokens(GroupsStr, ","),
    [string:trim(G) || G <- GroupsTokens].

validate_roles(Name, State) ->
    validator:validate(
      fun (RawRoles) ->
              Roles = parse_roles(RawRoles),

              BadRoles = [BadRole || BadRole = {error, _} <- Roles],
              case BadRoles of
                  [] ->
                      {value, Roles};
                  _ ->
                      GoodRoles = Roles -- BadRoles,
                      {_, MoreBadRoles} =
                          menelaus_roles:validate_roles(GoodRoles,
                                                        ns_config:latest()),
                      {error, bad_roles_error(
                                [Raw || {error, Raw} <- BadRoles] ++
                                    [role_to_string(R) || R <- MoreBadRoles])}
              end
      end, Name, State).

handle_put_user_with_identity({_UserId, Domain} = Identity, Req) ->
    validator:handle(
      fun (Values) ->
              handle_put_user_validated(Identity,
                                        proplists:get_value(name, Values),
                                        proplists:get_value(password, Values),
                                        proplists:get_value(roles, Values),
                                        proplists:get_value(groups, Values),
                                        Req)
      end, Req, form, put_user_validators(Domain)).

perform_if_allowed(Fun, Req, Permission, Roles) ->
    case menelaus_auth:has_permission(Permission, Req) orelse
        not overlap(Roles, get_security_roles()) of
        true ->
            Fun(Req);
        false ->
            menelaus_util:reply_json(Req, forbidden_response(Permission), 403)
    end.

overlap(List1, List2) ->
    lists:any(fun (V) -> lists:member(V, List1) end, List2).

get_security_roles() ->
    [R || {R, _} <- menelaus_roles:get_security_roles()].

handle_put_user_validated(Identity, Name, Password, Roles, Groups, Req) ->
    GroupRoles = lists:concat([menelaus_users:get_group_roles(G)
                                   || Groups =/= undefined, G <- Groups]),
    UniqueRoles = lists:usort(Roles),
    OldRoles = menelaus_users:get_roles(Identity),
    perform_if_allowed(
      do_store_user(Identity, Name, Password, UniqueRoles, Groups, _),
      Req, ?SECURITY_WRITE, lists:usort(GroupRoles ++ Roles ++ OldRoles)).

do_store_user(Identity, Name, Password, UniqueRoles, Groups, Req) ->
    case menelaus_users:store_user(Identity, Name, Password,
                                   UniqueRoles, Groups) of
        {commit, _} ->
            ns_audit:set_user(Req, Identity, UniqueRoles, Name, Groups),
            reply_put_delete_users(Req);
        {abort, {error, roles_validation, UnknownRoles}} ->
            menelaus_util:reply_error(
              Req, "roles",
              bad_roles_error([role_to_string(UR) || UR <- UnknownRoles]));
        {abort, password_required} ->
            menelaus_util:reply_error(Req, "password",
                                      "Password is required for new user.");
        {abort, too_many} ->
            menelaus_util:reply_error(
              Req, "_",
              "You cannot create any more users on Community Edition.");
        retry_needed ->
            erlang:error(exceeded_retries)
    end.

do_delete_user(Req, Identity) ->
    case menelaus_users:delete_user(Identity) of
        {commit, _} ->
            ns_audit:delete_user(Req, Identity),
            reply_put_delete_users(Req);
        {abort, {error, not_found}} ->
            menelaus_util:reply_json(Req, <<"User was not found.">>, 404);
        retry_needed ->
            erlang:error(exceeded_retries)
    end.

handle_delete_user(Domain, UserId, Req) ->
    menelaus_util:assert_is_45(),
    assert_no_users_upgrade(),

    case domain_to_atom(Domain) of
        unknown ->
            menelaus_util:reply_json(Req, <<"Unknown user domain.">>, 404);
        T ->
            Identity = {UserId, T},
            perform_if_allowed(
              do_delete_user(_, Identity), Req, ?SECURITY_WRITE,
              menelaus_users:get_roles(Identity))
    end.

reply_put_delete_users(Req) ->
    case cluster_compat_mode:is_cluster_50() of
        true ->
            menelaus_util:reply_json(Req, <<>>, 200);
        false ->
            handle_get_users_45(Req)
    end.

change_password_validators() ->
    [validator:required(password, _),
     validator:validate(
       fun (P) ->
               case validate_cred(P, password) of
                   true ->
                       ok;
                   Error ->
                       {error, Error}
               end
       end, password, _),
     validator:unsupported(_)].

handle_change_password(Req) ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_50(),

    case menelaus_auth:get_token(Req) of
        undefined ->
            case menelaus_auth:get_identity(Req) of
                {_, local} = Identity ->
                    handle_change_password_with_identity(Req, Identity);
                {_, admin} = Identity ->
                    handle_change_password_with_identity(Req, Identity);
                _ ->
                    menelaus_util:reply_json(
                      Req,
                      <<"Changing of password is not allowed for this user.">>,
                      404)
            end;
        _ ->
            menelaus_util:require_auth(Req)
    end.

handle_change_password_with_identity(Req, Identity) ->
    validator:handle(
      fun (Values) ->
              case do_change_password(Identity,
                                      proplists:get_value(password, Values)) of
                  ok ->
                      ns_audit:password_change(Req, Identity),
                      menelaus_util:reply(Req, 200);
                  user_not_found ->
                      menelaus_util:reply_json(Req, <<"User was not found.">>,
                                               404);
                  unchanged ->
                      menelaus_util:reply(Req, 200)
              end
      end, Req, form, change_password_validators()).

do_change_password({_, local} = Identity, Password) ->
    menelaus_users:change_password(Identity, Password);
do_change_password({User, admin}, Password) ->
    ns_config_auth:set_credentials(admin, User, Password).

handle_settings_read_only_admin_name(Req) ->
    case ns_config_auth:get_user(ro_admin) of
        undefined ->
            menelaus_util:reply_not_found(Req);
        Name ->
            menelaus_util:reply_json(Req, list_to_binary(Name), 200)
    end.

handle_settings_read_only_user_post(Req) ->
    assert_no_users_upgrade(),

    PostArgs = mochiweb_request:parse_post(Req),
    ValidateOnly = proplists:get_value("just_validate", mochiweb_request:parse_qs(Req)) =:= "1",
    U = proplists:get_value("username", PostArgs),
    P = proplists:get_value("password", PostArgs),
    Errors0 = [{K, V} || {K, V} <- [{username, validate_cred(U, username)},
                                    {password, validate_cred(P, password)}],
                         V =/= true],
    Errors = Errors0 ++
        case ns_config_auth:get_user(admin) of
            U ->
                [{username,
                  <<"Read-only user cannot be same user as administrator">>}];
            _ ->
                []
        end,

    case Errors of
        [] ->
            case ValidateOnly of
                false ->
                    ns_config_auth:set_credentials(ro_admin, U, P),
                    ns_audit:password_change(Req, {U, ro_admin});
                true ->
                    true
            end,
            menelaus_util:reply_json(Req, [], 200);
        _ ->
            menelaus_util:reply_json(Req,
                                     {struct, [{errors, {struct, Errors}}]},
                                     400)
    end.

handle_read_only_user_delete(Req) ->
    assert_no_users_upgrade(),

    case ns_config_auth:get_user(ro_admin) of
        undefined ->
            menelaus_util:reply_json(Req,
                                     <<"Read-Only admin does not exist">>, 404);
        User ->
            ns_config_auth:unset_credentials(ro_admin),
            ns_audit:delete_user(Req, {User, ro_admin}),
            menelaus_util:reply_json(Req, [], 200)
    end.

handle_read_only_user_reset(Req) ->
    assert_no_users_upgrade(),

    case ns_config_auth:get_user(ro_admin) of
        undefined ->
            menelaus_util:reply_json(Req,
                                     <<"Read-Only admin does not exist">>, 404);
        ROAName ->
            ReqArgs = mochiweb_request:parse_post(Req),
            NewROAPass = proplists:get_value("password", ReqArgs),
            case validate_cred(NewROAPass, password) of
                true ->
                    ns_config_auth:set_credentials(ro_admin, ROAName,
                                                   NewROAPass),
                    ns_audit:password_change(Req, {ROAName, ro_admin}),
                    menelaus_util:reply_json(Req, [], 200);
                Error ->
                    menelaus_util:reply_json(
                      Req, {struct, [{errors, {struct, [{password, Error}]}}]},
                      400)
            end
    end.

gen_password(Policy) ->
    gen_password(Policy, 100).

gen_password(Policy, 0) ->
    erlang:error({pass_gen_retries_exceeded, Policy});
gen_password({MinLength, _} = Policy, Retries) ->
    Length = max(MinLength, misc:rand_uniform(8, 16)),
    Letters =
        "0123456789abcdefghijklmnopqrstuvwxyz"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*?",
    Pass = crypto_random_string(Length, Letters),
    case is_valid_password(Pass, Policy) of
        true -> Pass;
        _ -> gen_password(Policy, Retries - 1)
    end.

crypto_random_string(Length, AllowedChars) ->
    S = rand:seed_s(exrop, misc:generate_crypto_seed()),
    AllowedLen = length(AllowedChars),
    {Password, _} = lists:mapfoldl(
        fun(_, Acc) ->
                {Rand, NewAcc} = rand:uniform_s(AllowedLen, Acc),
                {lists:nth(Rand, AllowedChars), NewAcc}
        end, S, lists:seq(1, Length)),
    Password.

reset_admin_password(Password) ->
    {User, Error} =
        case ns_config_auth:get_user(admin) of
            undefined ->
                {undefined, "Failed to reset administrative password. Node is "
                 "not initialized."};
            U ->
                {U, case validate_cred(Password, password) of
                        true ->
                            undefined;
                        ErrStr ->
                            ErrStr
                    end}
        end,

    case Error of
        undefined ->
            ok = ns_config_auth:set_credentials(admin, User, Password),
            ns_audit:password_change(undefined, {User, admin}),
            {ok, Password};
        _ ->
            {error, Error}
    end.

handle_reset_admin_password(Req) ->
    assert_no_users_upgrade(),

    menelaus_util:ensure_local(Req),
    Password =
        case proplists:get_value("generate", mochiweb_request:parse_qs(Req)) of
            "1" ->
                gen_password(get_password_policy());
            _ ->
                PostArgs = mochiweb_request:parse_post(Req),
                proplists:get_value("password", PostArgs)
        end,
    case Password of
        undefined ->
            menelaus_util:reply_error(Req, "password",
                                      "Password should be supplied");
        _ ->
            case reset_admin_password(Password) of
                {ok, Password} ->
                    menelaus_util:reply_json(
                      Req, {struct, [{password, list_to_binary(Password)}]});
                {error, Error} ->
                    menelaus_util:reply_global_error(Req, Error)
            end
    end.

list_to_rbac_atom(List) ->
    try
        list_to_existing_atom(List)
    catch error:badarg ->
            '_unknown_'
    end.

parse_permission(RawPermission) ->
    case string:tokens(RawPermission, "!") of
        [Object, Operation] ->
            case parse_object(Object) of
                error ->
                    error;
                Parsed ->
                    {Parsed, list_to_rbac_atom(Operation)}
            end;
        _ ->
            error
    end.

parse_object("cluster" ++ RawObject) ->
    parse_vertices(RawObject, []);
parse_object(_) ->
    error.

parse_vertices([], Acc) ->
    lists:reverse(Acc);
parse_vertices([$. | Rest], Acc) ->
    case parse_until(Rest, ".[") of
        {Name, [$. | Rest1]} ->
            parse_vertices([$. | Rest1], [list_to_rbac_atom(Name) | Acc]);
        {Name, []} ->
            parse_vertices([], [list_to_rbac_atom(Name) | Acc]);
        {Name, [$[ | Rest1]} ->
            case parse_until(Rest1, "]") of
                {Param, [$] | Rest2]} ->
                    parse_vertices(Rest2, [{list_to_rbac_atom(Name),
                                            case Param of
                                                "." ->
                                                    any;
                                                _ ->
                                                    Param
                                            end} | Acc]);
                _ ->
                    error
            end
    end;
parse_vertices(_, _) ->
    error.

parse_permissions(Body) ->
    RawPermissions = string:tokens(Body, ","),
    lists:map(fun (RawPermission) ->
                      Trimmed = string:trim(RawPermission),
                      {Trimmed, parse_permission(Trimmed)}
              end, RawPermissions).

handle_check_permissions_post(Req) ->
    Body = mochiweb_request:recv_body(Req),
    case Body of
        undefined ->
            menelaus_util:reply_json(
              Req, <<"Request body should not be empty.">>, 400);
        _ ->
            Permissions = parse_permissions(binary_to_list(Body)),
            Malformed = [Bad || {Bad, error} <- Permissions],
            case Malformed of
                [] ->
                    Tested =
                        [{list_to_binary(RawPermission),
                          menelaus_auth:has_permission(Permission, Req)} ||
                            {RawPermission, Permission} <- Permissions],
                    menelaus_util:reply_json(Req, {Tested});
                _ ->
                    Message = io_lib:format("Malformed permissions: [~s].",
                                            [string:join(Malformed, ",")]),
                    menelaus_util:reply_json(Req, iolist_to_binary(Message),
                                             400)
            end
    end.

check_permissions_url_version(Config) ->
    B = term_to_binary(
          [cluster_compat_mode:get_compat_version(Config),
           menelaus_users:get_users_version(),
           menelaus_users:get_groups_version(),
           [{Name, proplists:get_value(uuid, BucketConfig)} ||
               {Name, BucketConfig} <- ns_bucket:get_buckets(Config)],
           ns_config_auth:get_no_auth_buckets(Config)]),
    base64:encode(crypto:hash(sha, B)).

handle_check_permission_for_cbauth(Req) ->
    Params = mochiweb_request:parse_qs(Req),
    Identity = {proplists:get_value("user", Params),
                list_to_existing_atom(proplists:get_value("domain", Params))},
    RawPermission = proplists:get_value("permission", Params),
    Permission = parse_permission(string:trim(RawPermission)),

    case menelaus_roles:is_allowed(Permission, Identity) of
        true ->
            menelaus_util:reply_text(Req, "", 200);
        false ->
            menelaus_util:reply_text(Req, "", 401)
    end.

vertex_to_iolist(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
vertex_to_iolist({Atom, any}) ->
    [atom_to_list(Atom), "[.]"];
vertex_to_iolist({Atom, Param}) ->
    [atom_to_list(Atom), "[", Param, "]"].

permission_to_binary({Object, Operation}) ->
    FormattedVertices = ["cluster" | [vertex_to_iolist(Vertex) ||
                                         Vertex <- Object]],
    iolist_to_binary(
      [string:join(FormattedVertices, "."), "!", atom_to_list(Operation)]).

format_permissions(Permissions) ->
    lists:foldl(
      fun ({Object, Operations}, Acc) when is_list(Operations) ->
              lists:foldl(
                fun (Oper, Acc1) ->
                        [permission_to_binary({Object, Oper}) | Acc1]
                end, Acc, Operations);
          (Permission, Acc) ->
              [permission_to_binary(Permission) | Acc]
      end, [], Permissions).

forbidden_response(Permissions) when is_list(Permissions) ->
    {[{message, <<"Forbidden. User needs one of the following permissions">>},
      {permissions, format_permissions(Permissions)}]};
forbidden_response(Permission) ->
    forbidden_response([Permission]).

handle_get_password_policy(Req) ->
    menelaus_util:assert_is_50(),
    {MinLength, MustPresent} = get_password_policy(),
    menelaus_util:reply_json(
      Req,
      {[{minLength, MinLength},
        {enforceUppercase, lists:member(uppercase, MustPresent)},
        {enforceLowercase, lists:member(lowercase, MustPresent)},
        {enforceDigits, lists:member(digits, MustPresent)},
        {enforceSpecialChars, lists:member(special, MustPresent)}]}).

post_password_policy_validators() ->
    [validator:required(minLength, _),
     validator:integer(minLength, 0, 100, _),
     validator:boolean(enforceUppercase, _),
     validator:boolean(enforceLowercase, _),
     validator:boolean(enforceDigits, _),
     validator:boolean(enforceSpecialChars, _),
     validator:unsupported(_)].

must_present_value(JsonField, MustPresentAtom, Args) ->
    case proplists:get_value(JsonField, Args) of
        true ->
            [MustPresentAtom];
        _ ->
            []
    end.

handle_post_password_policy(Req) ->
    validator:handle(
      fun (Values) ->
              Policy =
                  [{min_length, proplists:get_value(minLength, Values)},
                   {must_present,
                    must_present_value(enforceUppercase, uppercase, Values) ++
                        must_present_value(enforceLowercase, lowercase,
                                           Values) ++
                        must_present_value(enforceDigits, digits, Values) ++
                        must_present_value(enforceSpecialChars, special,
                                           Values)}],
              ns_config:set(password_policy, Policy),
              ns_audit:password_policy(Req, Policy),
              menelaus_util:reply(Req, 200)
      end, Req, form, post_password_policy_validators()).

assert_no_users_upgrade() ->
    case menelaus_users:upgrade_status() of
        no_upgrade ->
            ok;
        upgrade_in_progress ->
            erlang:throw({web_exception,
                          503,
                          "Not allowed during cluster upgrade.",
                          []})
    end.

handle_put_group(GroupId, Req) ->
    assert_groups_and_ldap_enabled(),

    case validate_id(GroupId, <<"Group name">>) of
        true ->
            validator:handle(
              fun (Values) ->
                      Description = proplists:get_value(description, Values),
                      Roles = proplists:get_value(roles, Values),
                      UniqueRoles = lists:usort(Roles),
                      LDAPGroup = proplists:get_value(ldap_group_ref, Values),
                      perform_if_allowed(
                          do_store_group(GroupId, Description, UniqueRoles,
                                         LDAPGroup, _),
                          Req, ?SECURITY_WRITE,
                          UniqueRoles ++
                          menelaus_users:get_group_roles(GroupId))
              end, Req, form, put_group_validators());
        Error ->
            menelaus_util:reply_global_error(Req, Error)
    end.

put_group_validators() ->
    [validator:touch(description, _),
     validator:required(roles, _),
     validate_roles(roles, _),
     validate_ldap_ref(ldap_group_ref, _),
     validator:unsupported(_)].

validate_ldap_ref(Name, State) ->
    validator:validate(
      fun (undefined) -> undefined;
          (DN) ->
              case eldap:parse_dn(DN) of
                  {ok, _} ->
                      {value, DN};
                  {parse_error, Reason, _} ->
                      {error, io_lib:format("Should be valid LDAP DN: ~p",
                                            [Reason])}
              end
      end, Name, State).

do_store_group(GroupId, Description, UniqueRoles, LDAPGroup, Req) ->
    case menelaus_users:store_group(GroupId, Description, UniqueRoles,
                                    LDAPGroup) of
        ok ->
            ns_audit:set_user_group(Req, GroupId, UniqueRoles, Description,
                                    LDAPGroup),
            menelaus_util:reply_json(Req, <<>>, 200);
        {error, {roles_validation, UnknownRoles}} ->
            menelaus_util:reply_error(
              Req, "roles",
              bad_roles_error([role_to_string(UR) || UR <- UnknownRoles]))
    end.

handle_delete_group(GroupId, Req) ->
    assert_groups_and_ldap_enabled(),
    perform_if_allowed(
      do_delete_group(GroupId, _), Req, ?SECURITY_WRITE,
      menelaus_users:get_group_roles(GroupId)).

do_delete_group(GroupId, Req) ->
    case menelaus_users:delete_group(GroupId) of
        ok ->
            ns_audit:delete_user_group(Req, GroupId),
            menelaus_util:reply_json(Req, <<>>, 200);
        {error, not_found} ->
            menelaus_util:reply_json(Req, <<"Group was not found.">>, 404)
    end.

handle_get_groups(Path, Req) ->
    assert_groups_and_ldap_enabled(),
    Query = mochiweb_request:parse_qs(Req),
    case lists:keyfind("pageSize", 1, Query) of
        false ->
            handle_get_all_groups(Req);
        _ ->
            validator:handle(
              handle_get_groups_page(Req, Path, _),
              Req, Query, get_groups_page_validators())
    end.

get_groups_page_validators() ->
    [validator:integer(pageSize, ?MIN_USERS_PAGE_SIZE, ?MAX_USERS_PAGE_SIZE, _),
     validator:touch(startFrom, _)].

handle_get_groups_page(Req, Path, Values) ->
    Start = proplists:get_value(startFrom, Values),
    PageSize = proplists:get_value(pageSize, Values),

    {PageSkews, Total} =
        pipes:run(menelaus_users:select_groups('_'),
                  [security_filter(Req)],
                  ?make_consumer(
                     pipes:fold(
                       ?producer(),
                       fun ({{group, Identity}, Props}, {Skews, T}) ->
                               {add_to_skews({Identity, Props}, Skews), T + 1}
                       end, {create_skews(Start, PageSize), 0}))),

    {Groups, Skipped, Links} = page_data_from_skews(PageSkews, PageSize),
    GroupsJson = [group_to_json(Id, Props) || {Id, Props} <- Groups],
    LinksJson = build_group_links(Links, PageSize, Path),
    Json = {[{total, Total},
             {links, LinksJson},
             {skipped, Skipped},
             {groups, GroupsJson}]},

    menelaus_util:reply_json(Req, Json).

handle_get_all_groups(Req) ->
    pipes:run(menelaus_users:select_groups('_'),
              [security_filter(Req),
               jsonify_groups(),
               sjson:encode_extended_json([{compact, true},
                                           {strict, false}]),
               pipes:simple_buffer(2048)],
              menelaus_util:send_chunked(
                Req, 200, [{"Content-Type", "application/json"}])).

jsonify_groups() ->
    ?make_transducer(
       begin
           ?yield(array_start),
           pipes:foreach(
             ?producer(),
             fun ({{group, GroupId}, Props}) ->
                     ?yield({json, group_to_json(GroupId, Props)})
             end),
           ?yield(array_end)
       end).

handle_get_group(GroupId, Req) ->
    assert_groups_and_ldap_enabled(),
    case menelaus_users:group_exists(GroupId) of
        false ->
            menelaus_util:reply_json(Req, <<"Unknown group.">>, 404);
        true ->
            perform_if_allowed(
              menelaus_util:reply_json(_, get_group_json(GroupId)),
              Req, ?SECURITY_READ, menelaus_users:get_group_roles(GroupId))
    end.

get_group_json(GroupId) ->
    group_to_json(GroupId, menelaus_users:get_group_props(GroupId)).

group_to_json(GroupId, Props) ->
    Description = proplists:get_value(description, Props),
    LDAPGroup = proplists:get_value(ldap_group_ref, Props),
    {[{id, list_to_binary(GroupId)},
      {roles, [{role_to_json(R)} || R <- proplists:get_value(roles, Props)]}] ++
         [{ldap_group_ref, list_to_binary(LDAPGroup)}
          || LDAPGroup =/= undefined] ++
         [{description, list_to_binary(Description)}
          || Description =/= undefined]}.

handle_ldap_settings(Req) ->
    assert_groups_and_ldap_enabled(),
    Settings = ldap_auth:build_settings(),
    menelaus_util:reply_json(Req, {prepare_ldap_settings(Settings)}).

prepare_ldap_settings(Settings) ->
    Fun =
      fun (hosts, Hosts) ->
              [list_to_binary(H) || H <- Hosts];
          (user_dn_template, T) ->
              list_to_binary(T);
          (query_dn, DN) ->
              list_to_binary(DN);
          (query_pass, _) ->
              <<"**********">>;
          (groups_query, {user_filter, Orig, _Base, _Scope, _Filter}) ->
              list_to_binary(Orig);
          (groups_query, {user_attributes, Orig, _AttrName}) ->
              list_to_binary(Orig);
          (_, Value) ->
              Value
      end,
    [{K, Fun(K, V)} || {K, V} <- Settings].

handle_ldap_settings_post(Req) ->
    assert_groups_and_ldap_enabled(),
    validator:handle(
      fun (Props) ->
              NewProps = build_new_ldap_settings(Props),
              ?log_debug("Saving ldap settings: ~p", [Props]),
              ns_audit:ldap_settings(Req, prepare_ldap_settings(NewProps)),
              ldap_auth:set_settings(NewProps),
              handle_ldap_settings(Req)
      end, Req, form, ldap_settings_validators()).

build_new_ldap_settings(Props) ->
    misc:update_proplist(ldap_auth:build_settings(), Props).

handle_ldap_settings_validate_post(Type, Req) when Type =:= "connectivity";
                                                   Type =:= "authentication";
                                                   Type =:= "groups_query" ->
    assert_groups_and_ldap_enabled(),
    validator:handle(
      fun (Props) ->
              NewProps = build_new_ldap_settings(Props),
              Res = validate_ldap_settings(Type, NewProps),
              menelaus_util:reply_json(Req, {Res})
      end, Req, form, ldap_settings_validator_validators(Type) ++
                      ldap_settings_validators());
handle_ldap_settings_validate_post(_Type, Req) ->
    menelaus_util:reply_json(Req, <<"Unknown validation type">>, 404).

validate_ldap_settings("connectivity", Settings) ->
    case ldap_auth:with_connection(Settings, fun (_) -> ok end) of
        ok ->
            [{result, success}];
        {error, Error} ->
            Bin = iolist_to_binary(ldap_auth:format_error(Error)),
            [{result, error},
             {reason, Bin}]
    end;
validate_ldap_settings("authentication", Settings) ->
    User = proplists:get_value(auth_user, Settings),
    Pass = proplists:get_value(auth_pass, Settings),
    case ldap_auth:authenticate(User, Pass, Settings) of
        true -> [{result, success}];
        false -> [{result, error}]
    end;
validate_ldap_settings("groups_query", Settings) ->
    GroupsUser = proplists:get_value(groups_query_user, Settings),
    case ldap_auth:user_groups(GroupsUser, Settings) of
        {ok, Groups} ->
            [{result, success},
             {groups, [list_to_binary(G) || G <- Groups]}];
        {error, Error2} ->
            Bin2 = iolist_to_binary(ldap_auth:format_error(Error2)),
            [{result, error},
             {reason, Bin2}]
    end.

ldap_settings_validators() ->
    [
        validator:boolean(authentication_enabled, _),
        validator:boolean(authorization_enabled, _),
        validate_ldap_hosts(hosts, _),
        validator:integer(port, 0, 65535, _),
        validator:one_of(encryption, ["ssl", "tls", "false"], _),
        validator:convert(encryption, fun list_to_atom/1, _),
        validate_user_dn_template(user_dn_template, _),
        validate_ldap_dn(query_dn, _),
        validator:touch(query_pass, _),
        validate_ldap_groups_query(groups_query, _),
        validator:unsupported(_)
    ].

ldap_settings_validator_validators("connectivity") -> [];
ldap_settings_validator_validators("authentication") ->
    [validator:required(auth_user, _),
     validator:required(auth_pass, _)];
ldap_settings_validator_validators("groups_query") ->
    [validator:required(groups_query_user, _)].

validate_ldap_hosts(Name, State) ->
    validator:validate(
      fun (HostsRaw) ->
              {value, [string:trim(T) || T <- string:tokens(HostsRaw, ",")]}
      end, Name, State).

validate_user_dn_template(Name, State) ->
    validator:validate(
      fun (Str) ->
              case string:str(Str, "%u") of
                  0 -> {error, "user_dn_template must contain \"%u\""};
                  _ -> {value, Str}
              end
      end, Name, State).

validate_ldap_dn(Name, State) ->
    validator:validate(
      fun (DN) ->
              case eldap:parse_dn(DN) of
                  {ok, _} -> {value, DN};
                  {parse_error, Reason, _} ->
                      Msg = io_lib:format("Should be valid LDAP DN: ~p",
                                          [Reason]),
                      {error, Msg}
              end
      end, Name, State).

validate_ldap_groups_query(Name, State) ->
    validator:validate(
      fun (Query) ->
              case ldap_auth:parse_url("ldap:///" ++ Query) of
                  {ok, URLProps} ->
                      case proplists:get_value(attributes, URLProps, []) of
                          [] ->
                              Base = proplists:get_value(dn, URLProps, ""),
                              Scope = proplists:get_value(scope, URLProps,
                                                          "base"),
                              Filter = proplists:get_value(filter, URLProps,
                                                           "(objectClass=*)"),
                              {value,
                               {user_filter, Query, Base, Scope, Filter}};
                          [Attr] ->
                              {value, {user_attributes, Query, Attr}};
                          _ ->
                              {error, "Only one attribute can be specified"}
                      end;
                  {error, _} ->
                      {error, "Invalid ldap URL"}
              end
      end, Name, State).

assert_groups_and_ldap_enabled() ->
    menelaus_util:assert_is_enterprise(),
    menelaus_util:assert_is_madhatter().

-ifdef(EUNIT).
%% Tests
parse_roles_test() ->
    Res = parse_roles("admin, bucket_admin[test.test], bucket_admin[*], "
                      "no_such_atom, bucket_admin[default"),
    ?assertMatch([admin,
                  {bucket_admin, ["test.test"]},
                  {bucket_admin, [any]},
                  {error, "no_such_atom"},
                  {error, "bucket_admin[default"}], Res).

parse_permissions_test() ->
    ?assertMatch(
       [{"cluster.admin!write", {[admin], write}},
        {"cluster.admin", error},
        {"admin!write", error}],
       parse_permissions("cluster.admin!write, cluster.admin, admin!write")),
    ?assertMatch(
       [{"cluster.bucket[test.test]!read", {[{bucket, "test.test"}], read}},
        {"cluster.bucket[test.test].stats!read",
         {[{bucket, "test.test"}, stats], read}}],
       parse_permissions(" cluster.bucket[test.test]!read, "
                         "cluster.bucket[test.test].stats!read ")),
    ?assertMatch(
       [{"cluster.no_such_atom!no_such_atom", {['_unknown_'], '_unknown_'}}],
       parse_permissions("cluster.no_such_atom!no_such_atom")).

format_permissions_test() ->
    Permissions = [{[{bucket, any}, views], write},
                   {[{bucket, "default"}], all},
                   {[], all},
                   {[admin, diag], read},
                   {[{bucket, "test"}, xdcr], [write, execute]}],
    Formatted = [<<"cluster.bucket[.].views!write">>,
                 <<"cluster.bucket[default]!all">>,
                 <<"cluster!all">>,
                 <<"cluster.admin.diag!read">>,
                 <<"cluster.bucket[test].xdcr!write">>,
                 <<"cluster.bucket[test].xdcr!execute">>],
    ?assertEqual(
       lists:sort(Formatted),
       lists:sort(format_permissions(Permissions))).

toy_users(First, Last) ->
    [{{lists:flatten(io_lib:format("a~b", [U])), local}, []} ||
        U <- lists:seq(First, Last)].

process_toy_users(Users, Start, PageSize) ->
    {PageUsers, Skipped, Links} =
        page_data_from_skews(
          lists:foldl(
            fun (U, Skews) ->
                    add_to_skews(U, Skews)
            end, create_skews(Start, PageSize), Users),
          PageSize),
    {[{skipped, Skipped}, {users, PageUsers}], lists:sort(Links)}.

toy_result(Params, Links) ->
    {lists:sort(Params), lists:sort(seed_links(Links))}.

no_users_no_params_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, []}],
         []),
       process_toy_users([], undefined, 3)).

no_users_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, []}],
         []),
       process_toy_users([], {"a14", local}, 3)).

one_user_no_params_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, toy_users(10, 10)}],
         []),
       process_toy_users(toy_users(10, 10), undefined, 3)).

first_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, toy_users(10, 12)}],
         [{last, {"a28", local}},
          {next, {"a13", local}}]),
       process_toy_users(toy_users(10, 30), undefined, 3)).

first_page_with_params_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 0},
          {users, toy_users(10, 12)}],
         [{last, {"a28", local}},
          {next, {"a13", local}}]),
       process_toy_users(toy_users(10, 30), {"a10", local}, 3)).

middle_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 4},
          {users, toy_users(14, 16)}],
         [{first, noparams},
          {prev, {"a11", local}},
          {last, {"a28", local}},
          {next, {"a17", local}}]),
       process_toy_users(toy_users(10, 30), {"a14", local}, 3)).

middle_page_non_existent_user_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 5},
          {users, toy_users(15, 17)}],
         [{first, noparams},
          {prev, {"a12", local}},
          {last, {"a28", local}},
          {next, {"a18", local}}]),
       process_toy_users(toy_users(10, 30), {"a14b", local}, 3)).

near_the_end_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 17},
          {users, toy_users(27, 29)}],
         [{first, noparams},
          {prev, {"a24", local}},
          {last, {"a28", local}},
          {next, {"a28", local}}]),
       process_toy_users(toy_users(10, 30), {"a27", local}, 3)).

at_the_end_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 19},
          {users, toy_users(29, 30)}],
         [{first, noparams},
          {prev, {"a26", local}}]),
       process_toy_users(toy_users(10, 30), {"a29", local}, 3)).

after_the_end_page_test() ->
    ?assertEqual(
       toy_result(
         [{skipped, 21},
          {users, []}],
         [{first, noparams},
          {prev, {"a28", local}}]),
       process_toy_users(toy_users(10, 30), {"b29", local}, 3)).

validate_cred_username_test() ->
    LongButValid = "Username_that_is_127_characters_XXXXXXXXXXXXXXXXXXXXXXXXXX"
        "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    ?assertEqual(127, length(LongButValid)),
    ?assertEqual(true, validate_cred("valid", username)),
    ?assertEqual(true, validate_cred(LongButValid, username)),
    ?assertNotEqual(true, validate_cred([], username)),
    ?assertNotEqual(true, validate_cred("", username)),
    ?assertNotEqual(true, validate_cred(LongButValid ++
                                            "more_than_128_characters",
                                        username)),
    ?assertNotEqual(true, validate_cred([7], username)),
    ?assertNotEqual(true, validate_cred([127], username)),
    ?assertNotEqual(true, validate_cred("=", username)),

    %% The following block does not work after compilation with erralng 16
    %% due to non-native utf8 enoding of strings in .beam compiled files.
    %% TODO: re-enable this after upgrading to eralng 19+.
    %% Utf8 = "ξ",
    %% ?assertEqual(1,length(Utf8)),
    %% ?assertEqual(true, validate_cred(Utf8, username)),                  % "ξ" is codepoint 958
    %% ?assertEqual(true, validate_cred(LongButValid ++ Utf8, username)),  % 128 code points
    ok.

gen_password_test() ->
    Pass1 = gen_password({20, [uppercase]}),
    Pass2 = gen_password({0,  [digits]}),
    Pass3 = gen_password({5,  [uppercase, lowercase, digits, special]}),
    %% Using assertEqual instead of assert because assert is causing
    %% false dialyzer errors
    ?assertEqual(true, length(Pass1) >= 20),
    ?assertEqual(true, verify_uppercase(Pass1)),
    ?assertEqual(true, length(Pass2) >= 8),
    ?assertEqual(true, verify_digits(Pass2)),
    ?assertEqual(true, verify_lowercase(Pass3)),
    ?assertEqual(true, verify_uppercase(Pass3)),
    ?assertEqual(true, verify_special(Pass3)),
    ?assertEqual(true, verify_digits(Pass3)),
    ok.

gen_password_monkey_test_() ->
    GetRandomPolicy =
        fun () ->
            MustPresent = [uppercase || rand:uniform(2) == 1] ++
                          [lowercase || rand:uniform(2) == 1] ++
                          [digits    || rand:uniform(2) == 1] ++
                          [special   || rand:uniform(2) == 1],
            {rand:uniform(30), MustPresent}
        end,
    Test = fun () ->
                   [gen_password(GetRandomPolicy()) || _ <- lists:seq(1,100000)]
           end,
    {timeout, 100, Test}.

-endif.
