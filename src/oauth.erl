% Copyright (c) 2008-2021 Tim Fletcher
%
% Permission is hereby granted, free of charge, to any person obtaining
% a copy of this software and associated documentation files (the
% "Software"), to deal in the Software without restriction, including
% without limitation the rights to use, copy, modify, merge, publish,
% distribute, sublicense, and/or sell copies of the Software, and to
% permit persons to whom the Software is furnished to do so, subject to
% the following conditions:
%
% The above copyright notice and this permission notice shall be
% included in all copies or substantial portions of the Software.
%
% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
% MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
% LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
% OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
% WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

-module(oauth).

-export([get/3, get/5, get/6, post/3, post/5, post/6, delete/3, delete/5, delete/6, put/6, put/7]).

-export([uri/2, header/1, sign/6, params_decode/1, token/1, token_secret/1, verify/6]).

-export([plaintext_signature/2, hmac_sha1_signature/5,
  hmac_sha1_signature/3, rsa_sha1_signature/4, rsa_sha1_signature/2,
  signature_base_string/3, params_encode/1, signature/5]).

-export([plaintext_verify/3, hmac_sha1_verify/6, hmac_sha1_verify/4,
  rsa_sha1_verify/5, rsa_sha1_verify/3]).

-export([header_params_encode/1, header_params_decode/1]).

-include_lib("public_key/include/public_key.hrl").

-if(?OTP_RELEASE >= 22).
-define(HMAC_SHA1(Key, Data), crypto:mac(hmac, sha, Key, Data)).
-else.
-define(HMAC_SHA1(Key, Data), crypto:hmac(sha, Key, Data)).
-endif.

get(URL, ExtraParams, Consumer) ->
  get(URL, ExtraParams, Consumer, "", "").

get(URL, ExtraParams, Consumer, Token, TokenSecret) ->
  get(URL, ExtraParams, Consumer, Token, TokenSecret, []).

get(URL, ExtraParams, Consumer, Token, TokenSecret, HttpcOptions) ->
  SignedParams = sign("GET", URL, ExtraParams, Consumer, Token, TokenSecret),
  http_request(get, {uri(URL, SignedParams), []}, HttpcOptions).

post(URL, ExtraParams, Consumer) ->
  post(URL, ExtraParams, Consumer, "", "").

post(URL, ExtraParams, Consumer, Token, TokenSecret) ->
  post(URL, ExtraParams, Consumer, Token, TokenSecret, []).

post(URL, ExtraParams, Consumer, Token, TokenSecret, HttpcOptions) ->
  SignedParams = sign("POST", URL, ExtraParams, Consumer, Token, TokenSecret),
  http_request(post, {URL, [], "application/x-www-form-urlencoded", uri_string:compose_query(SignedParams)}, HttpcOptions).

delete(URL, ExtraParams, Consumer) ->
  delete(URL, ExtraParams, Consumer, "", "").

delete(URL, ExtraParams, Consumer, Token, TokenSecret) ->
  delete(URL, ExtraParams, Consumer, Token, TokenSecret, []).

delete(URL, ExtraParams, Consumer, Token, TokenSecret, HttpcOptions) ->
  SignedParams = sign("DELETE", URL, ExtraParams, Consumer, Token, TokenSecret),
  http_request(delete, {URL, [], "application/x-www-form-urlencoded", uri_string:compose_query(SignedParams)}, HttpcOptions).

put(URL, ExtraParams, {ContentType, Body}, Consumer, Token, TokenSecret) ->
  put(URL, ExtraParams, {ContentType, Body}, Consumer, Token, TokenSecret, []).

put(URL, ExtraParams, {ContentType, Body}, Consumer, Token, TokenSecret, HttpcOptions) ->
  SignedParams = sign("PUT", URL, ExtraParams, Consumer, Token, TokenSecret),
  http_request(put, {uri(URL, SignedParams), [], ContentType, Body}, HttpcOptions).

uri(Base, []) ->
  Base;
uri(Base, Params) ->
  lists:concat([Base, "?", uri_string:compose_query(Params)]).

header(Params) ->
  {"Authorization", "OAuth " ++ header_params_encode(Params)}.

token(Params) ->
  proplists:get_value("oauth_token", Params).

token_secret(Params) ->
  proplists:get_value("oauth_token_secret", Params).

consumer_key(_Consumer={Key, _, _}) ->
  Key.

consumer_secret(_Consumer={_, Secret, _}) ->
  Secret.

signature_method(_Consumer={_, _, Method}) ->
  Method.

sign(HttpMethod, URL, Params, Consumer, Token, TokenSecret) ->
  SignatureParams = signature_params(Consumer, Params, Token),
  Signature = signature(HttpMethod, URL, SignatureParams, Consumer, TokenSecret),
  [{"oauth_signature", Signature} | SignatureParams].

signature_params(Consumer, Params, "") ->
  signature_params(Consumer, Params);
signature_params(Consumer, Params, Token) ->
  signature_params(Consumer, [{"oauth_token", Token} | Params]).

signature_params(Consumer, Params) ->
  Timestamp = unix_timestamp(),
  Nonce = base64:encode_to_string(crypto:strong_rand_bytes(32)), % cf. ruby-oauth
  [ {"oauth_version", "1.0"}
  , {"oauth_nonce", Nonce}
  , {"oauth_timestamp", integer_to_list(Timestamp)}
  , {"oauth_signature_method", signature_method_string(Consumer)}
  , {"oauth_consumer_key", consumer_key(Consumer)}
  | Params
  ].

verify(Signature, HttpMethod, URL, Params, Consumer, TokenSecret) ->
  case signature_method(Consumer) of
    plaintext ->
      plaintext_verify(Signature, Consumer, TokenSecret);
    hmac_sha1 ->
      hmac_sha1_verify(Signature, HttpMethod, URL, Params, Consumer, TokenSecret);
    rsa_sha1 ->
      rsa_sha1_verify(Signature, HttpMethod, URL, Params, Consumer)
  end.

signature(HttpMethod, URL, Params, Consumer, TokenSecret) ->
  case signature_method(Consumer) of
    plaintext ->
      plaintext_signature(Consumer, TokenSecret);
    hmac_sha1 ->
      hmac_sha1_signature(HttpMethod, URL, Params, Consumer, TokenSecret);
    rsa_sha1 ->
      rsa_sha1_signature(HttpMethod, URL, Params, Consumer)
  end.

signature_method_string(Consumer) ->
  case signature_method(Consumer) of
    plaintext ->
      "PLAINTEXT";
    hmac_sha1 ->
      "HMAC-SHA1";
    rsa_sha1 ->
      "RSA-SHA1"
  end.

plaintext_signature(Consumer, TokenSecret) ->
  uri_join([consumer_secret(Consumer), TokenSecret]).

plaintext_verify(Signature, Consumer, TokenSecret) ->
  verify_in_constant_time(Signature, plaintext_signature(Consumer, TokenSecret)).

hmac_sha1_signature(HttpMethod, URL, Params, Consumer, TokenSecret) ->
  BaseString = signature_base_string(HttpMethod, URL, Params),
  hmac_sha1_signature(BaseString, Consumer, TokenSecret).

hmac_sha1_signature(BaseString, Consumer, TokenSecret) ->
  Key = uri_join([consumer_secret(Consumer), TokenSecret]),
  base64:encode_to_string(?HMAC_SHA1(Key, BaseString)).

hmac_sha1_verify(Signature, HttpMethod, URL, Params, Consumer, TokenSecret) ->
  verify_in_constant_time(Signature, hmac_sha1_signature(HttpMethod, URL, Params, Consumer, TokenSecret)).

hmac_sha1_verify(Signature, BaseString, Consumer, TokenSecret) ->
  verify_in_constant_time(Signature, hmac_sha1_signature(BaseString, Consumer, TokenSecret)).

rsa_sha1_signature(HttpMethod, URL, Params, Consumer) ->
  BaseString = signature_base_string(HttpMethod, URL, Params),
  rsa_sha1_signature(BaseString, Consumer).

rsa_sha1_signature(BaseString, Consumer) ->
  Key = read_private_key(consumer_secret(Consumer)),
  base64:encode_to_string(public_key:sign(list_to_binary(BaseString), sha, Key)).

rsa_sha1_verify(Signature, HttpMethod, URL, Params, Consumer) ->
  BaseString = signature_base_string(HttpMethod, URL, Params),
  rsa_sha1_verify(Signature, BaseString, Consumer).

rsa_sha1_verify(Signature, BaseString, Consumer) when is_binary(BaseString) ->
  Key = read_cert_key(consumer_secret(Consumer)),
  public_key:verify(BaseString, sha, base64:decode(Signature), Key);
rsa_sha1_verify(Signature, BaseString, Consumer) when is_list(BaseString) ->
  rsa_sha1_verify(Signature, list_to_binary(BaseString), Consumer).

verify_in_constant_time(<<X/binary>>, <<Y/binary>>) ->
  verify_in_constant_time(binary_to_list(X), binary_to_list(Y));
verify_in_constant_time(X, Y) when is_list(X) and is_list(Y) ->
  case length(X) == length(Y) of
    true ->
      verify_in_constant_time(X, Y, 0);
    false ->
      false
  end.

verify_in_constant_time([X | RestX], [Y | RestY], Result) ->
  verify_in_constant_time(RestX, RestY, (X bxor Y) bor Result);
verify_in_constant_time([], [], Result) ->
  Result == 0.

signature_base_string(HttpMethod, URL, Params) ->
  uri_join([HttpMethod, base_string_uri(URL), params_encode(Params)]).

params_encode(Params) ->
  % cf. http://tools.ietf.org/html/rfc5849#section-3.4.1.3.2
  Encoded = [{uri_encode(K), uri_encode(V)} || {K, V} <- Params],
  Sorted = lists:sort(Encoded),
  Concatenated = [lists:concat([K, "=", V]) || {K, V} <- Sorted],
  string:join(Concatenated, "&").

params_decode(_Response={{_, _, _}, _, Body}) ->
  uri_string:dissect_query(Body).

http_request(Method, Request, Options) ->
  httpc:request(Method, Request, [{autoredirect, false}], Options).

-define(unix_epoch, 62167219200).

unix_timestamp() ->
  calendar:datetime_to_gregorian_seconds(calendar:universal_time()) - ?unix_epoch.

read_cert_key(Path) when is_list(Path) ->
  {ok, Contents} = file:read_file(Path),
  [{'Certificate', DerCert, not_encrypted}] = public_key:pem_decode(Contents),
  read_cert_key(public_key:pkix_decode_cert(DerCert, otp));
read_cert_key(#'OTPCertificate'{tbsCertificate=Cert}) ->
  read_cert_key(Cert);
read_cert_key(#'OTPTBSCertificate'{subjectPublicKeyInfo=Info}) ->
  read_cert_key(Info);
read_cert_key(#'OTPSubjectPublicKeyInfo'{subjectPublicKey=Key}) ->
  Key.

read_private_key(Path) ->
  {ok, Contents} = file:read_file(Path),
  [Info] = public_key:pem_decode(Contents),
  public_key:pem_entry_decode(Info).

header_params_encode(Params) ->
  intercalate(", ", [lists:concat([uri_encode(K), "=\"", uri_encode(V), "\""]) || {K, V} <- Params]).

header_params_decode(String) ->
  [header_param_decode(Param) || Param <- re:split(String, ",\\s*", [{return, list}]), Param =/= ""].

header_param_decode(Param) ->
  [Key, QuotedValue] = string:tokens(Param, "="),
  Value = string:substr(QuotedValue, 2, length(QuotedValue) - 2),
  {uri_decode(Key), uri_decode(Value)}.

base_string_uri(Str) ->
  % https://tools.ietf.org/html/rfc5849#section-3.4.1.2
  Map1 = uri_string:parse(Str),
  Scheme = string:to_lower(maps:get(scheme, Map1)),
  Host = string:to_lower(maps:get(host, Map1)),
  Map2 = maps:put(scheme, Scheme, Map1),
  Map3 = maps:put(host, Host, Map2),
  Map4 = maps:remove(query, Map3),
  Map5 = without_default_port(Scheme, Map4),
  uri_string:recompose(Map5).

without_default_port("http", #{ port := 80 } = Map) ->
  maps:remove(port, Map);
without_default_port("https", #{ port := 443 } = Map) ->
  maps:remove(port, Map);
without_default_port(_Scheme, Map) ->
  Map.

uri_join(Values) ->
  uri_join(Values, "&").

uri_join(Values, Separator) ->
  string:join(lists:map(fun uri_encode/1, Values), Separator).

intercalate(Sep, Xs) ->
  lists:concat(intersperse(Sep, Xs)).

intersperse(_, []) ->
  [];
intersperse(_, [X]) ->
  [X];
intersperse(Sep, [X | Xs]) ->
  [X, Sep | intersperse(Sep, Xs)].

uri_encode(Term) when is_integer(Term) ->
  integer_to_list(Term);
uri_encode(Term) when is_atom(Term) ->
  uri_encode(atom_to_list(Term));
uri_encode(Term) when is_binary(Term) ->
  uri_encode(binary_to_list(Term));
uri_encode(Term) when is_list(Term) ->
  uri_encode(lists:reverse(Term, []), []).

-define(is_alphanum(C), C >= $A, C =< $Z; C >= $a, C =< $z; C >= $0, C =< $9).

uri_encode([X | T], Acc) when ?is_alphanum(X); X =:= $-; X =:= $_; X =:= $.; X =:= $~ ->
  uri_encode(T, [X | Acc]);
uri_encode([X | T], Acc) ->
  NewAcc = [$%, dec2hex(X bsr 4), dec2hex(X band 16#0f) | Acc],
  uri_encode(T, NewAcc);
uri_encode([], Acc) ->
  Acc.

uri_decode(Str) when is_list(Str) ->
  uri_decode(Str, []).

uri_decode([$%, A, B | T], Acc) ->
  uri_decode(T, [(hex2dec(A) bsl 4) + hex2dec(B) | Acc]);
uri_decode([X | T], Acc) ->
  uri_decode(T, [X | Acc]);
uri_decode([], Acc) ->
  lists:reverse(Acc, []).

-compile({inline, [{dec2hex, 1}, {hex2dec, 1}]}).

dec2hex(N) when N >= 10 andalso N =< 15 ->
  N + $A - 10;
dec2hex(N) when N >= 0 andalso N =< 9 ->
  N + $0.

hex2dec(C) when C >= $A andalso C =< $F ->
  C - $A + 10;
hex2dec(C) when C >= $0 andalso C =< $9 ->
  C - $0.
