"""Only loopback HTTP and injected transports; these tests cannot spend model tokens."""

import json
import ipaddress
import socket
import threading
import time
from contextlib import contextmanager
from types import SimpleNamespace

import httpx
import jwt
import pytest
import uvicorn
from azure.core.exceptions import ClientAuthenticationError
from azure.core.pipeline.transport import HttpResponse, HttpTransport
from azure.identity import ManagedIdentityCredential
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

from smoke_service import MAX_REQUEST_BYTES, Settings, create_app


TENANT = "00000000-0000-4000-8000-000000000002"
CALLER = "00000000-0000-4000-8000-000000000041"
GROUP = "00000000-0000-4000-8000-000000000042"
CLIENT = "00000000-0000-4000-8000-000000000031"
VERSION = "2" * 40
CORRELATION = "00000000-0000-4000-8000-000000000099"


def environment():
    return {
        "AZURE_TENANT_ID": TENANT,
        "AZURE_CLIENT_ID": CLIENT,
        "INFERENCE_ACCESS_MODE": "gateway",
        "INFERENCE_GATEWAY_ENDPOINT": "https://synthetic-gateway.azure-api.net/inference/v1/responses",
        "INFERENCE_GATEWAY_AUDIENCE": "api://synthetic-gateway",
        "SMOKE_API_AUDIENCE": "api://synthetic-smoke",
        "SMOKE_ALLOWED_OBJECT_IDS": json.dumps([CALLER]),
        "SMOKE_ALLOWED_GROUP_IDS": json.dumps([GROUP]),
        "SMOKE_MODEL_DEPLOYMENT": "synthetic-model",
        "SMOKE_MAX_OUTPUT_TOKENS": "64",
        "APP_CONFIG_ENDPOINT": "https://synthetic-config.azconfig.io",
    }


def model_response(text="Hello, caf\u00e9."):
    return {
        "id": "resp_synthetic",
        "object": "response",
        "status": "completed",
        "model": "synthetic-model",
        "output": [
            {
                "type": "message",
                "role": "assistant",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            }
        ],
        "usage": {"input_tokens": 7, "output_tokens": 5, "total_tokens": 12},
    }


class Fakes:
    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.jwk = json.loads(RSAAlgorithm.to_jwk(self.key.public_key()))
        self.jwk.update(kid="test-key", use="sig", alg="RS256")
        self.calls = {
            "jwks": [],
            "gateway": [],
            "tokens": [],
            "dns": [],
            "credentials": [],
        }
        self.reply = httpx.Response(
            200, json=model_response(), headers={"apim-request-id": "synthetic-apim-id"}
        )
        self.addresses = ["10.220.2.5"]
        self.token_failure = False

    def token(self, **overrides):
        claims = {
            "iss": f"https://login.microsoftonline.com/{TENANT}/v2.0",
            "tid": TENANT,
            "aud": "api://synthetic-smoke",
            "oid": CALLER,
            "ver": "2.0",
            "nbf": int(time.time()) - 1,
            "exp": int(time.time()) + 300,
        }
        key = overrides.pop("_key", self.key)
        algorithm = overrides.pop("_algorithm", "RS256")
        headers = overrides.pop("_headers", {"kid": "test-key"})
        claims.update(overrides)
        return jwt.encode(claims, key, algorithm=algorithm, headers=headers)

    def jwks(self, request):
        self.calls["jwks"].append(request)
        assert request.url.host == "login.microsoftonline.com"
        assert "authorization" not in request.headers
        if request.url.path.endswith("openid-configuration"):
            v2 = "/v2.0/" in request.url.path
            return httpx.Response(
                200,
                json={
                    "issuer": f"https://login.microsoftonline.com/{TENANT}/v2.0"
                    if v2
                    else f"https://sts.windows.net/{TENANT}/",
                    "jwks_uri": f"https://login.microsoftonline.com/{TENANT}/discovery/{'v2.0/' if v2 else ''}keys",
                },
            )
        return httpx.Response(200, json={"keys": [self.jwk]})

    def gateway(self, request):
        self.calls["gateway"].append(request)
        assert request.url.host == "10.220.2.5"
        assert request.headers["host"] == "synthetic-gateway.azure-api.net"
        assert request.extensions["sni_hostname"] == "synthetic-gateway.azure-api.net"
        return self.reply

    async def resolve(self, hostname):
        self.calls["dns"].append(hostname)
        return self.addresses

    def credential(self, **kwargs):
        self.calls["credentials"].append(kwargs)
        assert kwargs["client_id"] == CLIENT
        return self

    def get_token(self, scope):
        self.calls["tokens"].append(scope)
        if self.token_failure:
            raise ClientAuthenticationError("SENSITIVE error must not escape")
        return SimpleNamespace(
            token="synthetic-managed-identity-token", expires_on=int(time.time()) + 600
        )

    def close(self):
        pass

    def app(self, env=None):
        return create_app(
            environ=environment() if env is None else env,
            version=VERSION,
            jwks_transport=httpx.MockTransport(self.jwks),
            gateway_transport=httpx.MockTransport(self.gateway),
            credential_factory=self.credential,
            resolve_addresses=self.resolve,
        )


@contextmanager
def local_http(app):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    server = uvicorn.Server(
        uvicorn.Config(app, access_log=False, log_level="critical", lifespan="on")
    )
    thread = threading.Thread(
        target=server.run, kwargs={"sockets": [listener]}, daemon=True
    )
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started and thread.is_alive() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert server.started, "The real loopback HTTP server did not start"
    try:
        with httpx.Client(
            base_url=f"http://127.0.0.1:{port}", trust_env=False, timeout=5
        ) as client:
            yield client
    finally:
        server.should_exit = True
        thread.join(timeout=10)
        listener.close()
        assert not thread.is_alive(), "Local server was not stopped"


@pytest.fixture
def fake():
    return Fakes()


@pytest.fixture(autouse=True)
def deny_external_network(monkeypatch):
    original_lookup = socket.getaddrinfo
    original_connect = socket.socket.connect
    original_connect_ex = socket.socket.connect_ex

    def require_loopback(host):
        assert ipaddress.ip_address(host).is_loopback, (
            "External network is forbidden in local tests"
        )

    def lookup(host, *args, **kwargs):
        require_loopback(host)
        return original_lookup(host, *args, **kwargs)

    def connect(sock, address):
        require_loopback(address[0])
        return original_connect(sock, address)

    def connect_ex(sock, address):
        require_loopback(address[0])
        return original_connect_ex(sock, address)

    monkeypatch.setattr(socket, "getaddrinfo", lookup)
    monkeypatch.setattr(socket.socket, "connect", connect)
    monkeypatch.setattr(socket.socket, "connect_ex", connect_ex)


def infer(client, fake, body=None, token=None, headers=None):
    request_headers = {
        "Authorization": "Bearer " + (fake.token() if token is None else token),
        "x-correlation-id": CORRELATION,
    }
    request_headers.update(headers or {})
    return client.post(
        "/infer",
        json={"input": "Hello, caf\u00e9."} if body is None else body,
        headers=request_headers,
    )


def assert_no_inference(fake):
    assert fake.calls["tokens"] == []
    assert fake.calls["gateway"] == []


def test_startup_health_and_ready_make_zero_network_or_identity_calls(fake):
    with local_http(fake.app()) as client:
        for path in ["/health", "/ready", "/health"]:
            response = client.get(path)
            assert response.status_code == 200
            assert response.json()["service"] == "developer-smoke"
            assert response.json()["version"] == VERSION
    assert all(not calls for calls in fake.calls.values())


def test_health_works_but_ready_and_inference_fail_closed_without_config(fake):
    with local_http(fake.app({})) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/ready").status_code == 503
        assert infer(client, fake).status_code == 503
    assert all(not calls for calls in fake.calls.values())


def test_real_http_valid_jwt_utf8_and_managed_identity_gateway_only(fake, caplog):
    with local_http(fake.app()) as client:
        with caplog.at_level("INFO", logger="developer-smoke"):
            response = infer(client, fake)
    assert response.status_code == 200
    assert response.json() == model_response()
    assert response.headers["x-correlation-id"] == CORRELATION
    assert response.headers["apim-request-id"] == "synthetic-apim-id"
    assert fake.calls["tokens"] == ["api://synthetic-gateway/.default"]
    assert len(fake.calls["gateway"]) == 1
    request = fake.calls["gateway"][0]
    assert request.url.path == "/inference/v1/responses"
    assert request.headers["authorization"] == "Bearer synthetic-managed-identity-token"
    assert request.headers["x-correlation-id"] == CORRELATION
    assert json.loads(request.content) == {
        "input": "Hello, caf\u00e9.",
        "model": "synthetic-model",
        "max_output_tokens": 64,
        "stream": False,
        "store": False,
    }
    events = [
        json.loads(record.message)
        for record in caplog.records
        if record.name == "developer-smoke"
    ]
    assert events
    assert events[-1]["total_tokens"] == 12
    assert events[-1]["identity"] == CALLER
    assert set(events[-1]) == {
        "correlation",
        "identity",
        "model",
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "status",
    }
    for secret in [
        "Hello",
        "caf",
        "Authorization",
        "synthetic-managed-identity-token",
        fake.token(),
    ]:
        assert secret not in caplog.text


@pytest.mark.parametrize(
    "changes",
    [
        {"iss": "https://attacker.invalid/"},
        {"aud": "api://different-api"},
        {"aud": ["api://synthetic-smoke", "api://different-api"]},
        {"tid": "00000000-0000-4000-8000-000000000003"},
        {"exp": 1},
        {"nbf": 9999999999},
        {"exp": None},
        {"nbf": None},
        {"exp": True},
        {"oid": "not-an-object-id"},
        {"ver": "unknown"},
    ],
)
def test_invalid_claims_reject_without_inference(fake, changes):
    with local_http(fake.app()) as client:
        assert infer(client, fake, token=fake.token(**changes)).status_code == 401
    assert_no_inference(fake)


def test_invalid_signature_rejects_without_inference(fake):
    with local_http(fake.app()) as client:
        assert (
            infer(client, fake, token=fake.token(_key=fake.other_key)).status_code
            == 401
        )
    assert_no_inference(fake)


@pytest.mark.parametrize("token_kind", ["unsigned", "hmac", "malformed", "jku", "crit"])
def test_unsupported_token_headers_do_not_fetch_keys(fake, token_kind):
    token = {
        "unsigned": lambda: fake.token(_key=None, _algorithm="none"),
        "hmac": lambda: fake.token(
            _key="synthetic-not-a-production-secret", _algorithm="HS256"
        ),
        "malformed": lambda: "not.a.jwt",
        "jku": lambda: fake.token(
            _headers={"kid": "test-key", "jku": "https://attacker.invalid/keys"}
        ),
        "crit": lambda: fake.token(_headers={"kid": "test-key", "crit": ["b64"]}),
    }[token_kind]()
    with local_http(fake.app()) as client:
        assert infer(client, fake, token=token).status_code == 401
    assert fake.calls["jwks"] == []
    assert_no_inference(fake)


def test_missing_bearer_and_unlisted_caller_fail_closed(fake):
    with local_http(fake.app()) as client:
        assert client.post("/infer", json={"input": "Hello"}).status_code == 401
        assert (
            infer(
                client,
                fake,
                token=fake.token(oid="00000000-0000-4000-8000-000000000099"),
            ).status_code
            == 403
        )
    assert_no_inference(fake)


def test_signed_group_authorizes_without_graph_lookup(fake):
    with local_http(fake.app()) as client:
        assert (
            infer(
                client,
                fake,
                token=fake.token(
                    oid="00000000-0000-4000-8000-000000000099",
                    groups=[GROUP],
                ),
            ).status_code
            == 200
        )
    assert len(fake.calls["gateway"]) == 1
    assert all(
        request.url.host == "login.microsoftonline.com"
        for request in fake.calls["jwks"]
    )


def test_group_overage_does_not_grant_access_or_call_graph(fake):
    with local_http(fake.app()) as client:
        token = fake.token(
            oid="00000000-0000-4000-8000-000000000099", _claim_names={"groups": "src1"}
        )
        assert infer(client, fake, token=token).status_code == 403
    assert_no_inference(fake)


def test_tenant_specific_v1_metadata_and_issuer(fake):
    with local_http(fake.app()) as client:
        token = fake.token(ver="1.0", iss=f"https://sts.windows.net/{TENANT}/")
        assert infer(client, fake, token=token).status_code == 200
    assert (
        fake.calls["jwks"][0].url.path == f"/{TENANT}/.well-known/openid-configuration"
    )


@pytest.mark.parametrize(
    "body",
    [
        {},
        [],
        {"input": ""},
        {"input": 12},
        {"input": ["image"]},
        {"input": "text", "model": "different"},
        {"input": "text", "project": "spoof"},
        {"input": "text", "metadata": {"project": "spoof"}},
        {"input": "text", "max_output_tokens": 9999},
        {"input": "text", "tools": []},
        {"input": "text", "stream": True},
        {"input": "text", "background": True},
        {"input": "text", "conversation": "conversation-id"},
        {"input": "text", "previous_response_id": "resp_prior"},
        {"input": "text", "modalities": ["audio"]},
        {
            "input": [
                {
                    "role": "user",
                    "content": [
                        {"type": "input_image", "image_url": "https://attacker.invalid"}
                    ],
                }
            ]
        },
    ],
)
def test_unsupported_input_never_calls_model(fake, body):
    with local_http(fake.app()) as client:
        assert infer(client, fake, body=body).status_code == 400
    assert_no_inference(fake)


@pytest.mark.parametrize(
    "header", ["x-project-id", "x-model", "x-caller-id", "x-ms-client-principal"]
)
def test_spoofed_identity_project_model_headers_are_rejected(fake, header):
    with local_http(fake.app()) as client:
        assert infer(client, fake, headers={header: "spoof"}).status_code == 400
    assert_no_inference(fake)


def test_malformed_duplicate_keys_oversize_and_non_utf8(fake):
    with local_http(fake.app()) as client:
        headers = {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + fake.token(),
        }
        for body in [
            b'{"input":',
            b'{"input":"one","input":"two"}',
            b'{"input":"\xff"}',
        ]:
            assert (
                client.post("/infer", content=body, headers=headers).status_code == 400
            )
        assert (
            infer(client, fake, body={"input": "x" * MAX_REQUEST_BYTES}).status_code
            == 413
        )
        assert (
            client.post(
                "/infer", content=b"hello", headers={"Content-Type": "text/plain"}
            ).status_code
            == 415
        )
    assert_no_inference(fake)


@pytest.mark.parametrize("status", [403, 429, 500, 503])
def test_gateway_failure_status_retry_and_correlation_are_preserved(
    fake, status, caplog
):
    fake.reply = httpx.Response(
        status,
        json={"error": "SECRET prompt or token"},
        headers={
            "Retry-After": "17",
            "apim-request-id": "rejected-request",
        },
    )
    with local_http(fake.app()) as client:
        response = infer(client, fake)
    assert response.status_code == status
    assert response.headers["retry-after"] == "17"
    assert response.headers["apim-request-id"] == "rejected-request"
    assert response.headers["x-correlation-id"] == CORRELATION
    assert "SECRET" not in response.text + caplog.text
    assert len(fake.calls["gateway"]) == 1, (
        "Billable POST must never be automatically retried"
    )


@pytest.mark.parametrize(
    "redirect",
    [
        "https://attacker.invalid/steal",
        "https://synthetic-gateway.azure-api.net/other",
    ],
)
def test_gateway_redirect_never_receives_token(fake, redirect):
    fake.reply = httpx.Response(307, headers={"location": redirect})
    with local_http(fake.app()) as client:
        assert infer(client, fake).status_code == 502
    assert len(fake.calls["gateway"]) == 1


@pytest.mark.parametrize(
    "endpoint",
    [
        "",
        "https://synthetic.openai.azure.com/openai/v1/responses",
        "http://synthetic-gateway.azure-api.net/inference/v1/responses",
        "https://user:pass@synthetic-gateway.azure-api.net/inference/v1/responses",
        "https://synthetic-gateway.azure-api.net/inference/v1/responses?api-key=bad",
        "https://synthetic-gateway.azure-api.net/inference/v1/responses#fragment",
        "https://synthetic-gateway.azure-api.net:8443/inference/v1/responses",
        "https://synthetic-gateway.azure-api.net.attacker.invalid/inference/v1/responses",
        "https://10.220.2.5/inference/v1/responses",
        "https://synthetic-gateway.azure-api.net/inference/v1/../v1/responses",
    ],
)
def test_no_direct_backend_fallback_when_gateway_missing_or_invalid(fake, endpoint):
    env = environment()
    env["INFERENCE_GATEWAY_ENDPOINT"] = endpoint
    env["AZURE_OPENAI_ENDPOINT"] = "https://do-not-use.openai.azure.com"
    env["AZURE_OPENAI_API_KEY"] = "do-not-use"
    with local_http(fake.app(env)) as client:
        assert infer(client, fake).status_code == 503
    assert all(not calls for calls in fake.calls.values())


@pytest.mark.parametrize(
    "addresses",
    [
        ["8.8.8.8"],
        ["127.0.0.1"],
        ["169.254.169.254"],
        ["::1"],
        ["10.220.2.5", "8.8.8.8"],
        [],
    ],
)
def test_public_or_mixed_gateway_resolution_does_not_acquire_tokens(fake, addresses):
    fake.addresses = addresses
    with local_http(fake.app()) as client:
        assert infer(client, fake).status_code == 503
    assert_no_inference(fake)


def test_managed_identity_failure_cannot_fall_back(fake, caplog):
    fake.token_failure = True
    with local_http(fake.app()) as client:
        response = infer(client, fake)
    assert response.status_code == 503
    assert fake.calls["gateway"] == []
    assert len(fake.calls["credentials"]) == 1
    assert "SENSITIVE" not in response.text + caplog.text


@pytest.mark.parametrize(
    "reply",
    [
        {"error": {"message": "failed"}},
        {"object": "response", "status": "failed", "output": [], "usage": {}},
        {"object": "response", "status": "completed", "output": [], "usage": {}},
    ],
)
def test_success_shaped_provider_error_is_not_success(fake, reply):
    fake.reply = httpx.Response(200, json=reply)
    with local_http(fake.app()) as client:
        assert infer(client, fake).status_code == 502


def test_settings_reject_empty_authorization_and_nonpositive_cap():
    for key, value in [
        ("SMOKE_MAX_OUTPUT_TOKENS", "0"),
        ("SMOKE_MAX_OUTPUT_TOKENS", "true"),
        ("INFERENCE_ACCESS_MODE", "direct"),
    ]:
        env = environment()
        env[key] = value
        with pytest.raises(ValueError):
            Settings.from_environment(env)
    env = environment()
    env["SMOKE_ALLOWED_OBJECT_IDS"] = "[]"
    env["SMOKE_ALLOWED_GROUP_IDS"] = "[]"
    with pytest.raises(ValueError):
        Settings.from_environment(env)


def test_actual_managed_identity_sdk_uses_only_injected_transport(fake, monkeypatch):
    class IdentityResponse(HttpResponse):
        def __init__(self, request):
            super().__init__(request, None)
            self.status_code = 200
            self.headers = {"Content-Type": "application/json"}
            self.reason = "OK"

        def body(self):
            return json.dumps(
                {
                    "access_token": "synthetic-managed-identity-token",
                    "token_type": "Bearer",
                    "expires_on": str(int(time.time()) + 600),
                    "resource": "api://synthetic-gateway",
                }
            ).encode("utf-8")

    class IdentityTransport(HttpTransport):
        def __init__(self):
            self.requests = []

        def open(self):
            pass

        def close(self):
            pass

        def __exit__(self, *_args):
            self.close()

        def send(self, request, **_kwargs):
            self.requests.append(request)
            url = httpx.URL(request.url)
            assert url.host == "127.0.0.1"
            assert url.params["client_id"] == CLIENT
            assert url.params["resource"] == "api://synthetic-gateway"
            return IdentityResponse(request)

    transport = IdentityTransport()
    monkeypatch.setenv("IDENTITY_ENDPOINT", "http://127.0.0.1/managed-identity")
    monkeypatch.setenv("IDENTITY_HEADER", "synthetic-platform-identity-header")
    monkeypatch.delenv("IMDS_ENDPOINT", raising=False)
    app = create_app(
        environ=environment(),
        version=VERSION,
        jwks_transport=httpx.MockTransport(fake.jwks),
        gateway_transport=httpx.MockTransport(fake.gateway),
        credential_factory=lambda **kwargs: ManagedIdentityCredential(
            transport=transport, **kwargs
        ),
        resolve_addresses=fake.resolve,
    )
    with local_http(app) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/ready").status_code == 200
        assert transport.requests == []
        assert infer(client, fake).status_code == 200
    assert len(transport.requests) == 1
    assert len(fake.calls["gateway"]) == 1


def test_identity_metadata_redirects_are_not_followed(fake):
    calls = []

    def redirect(request):
        calls.append(request)
        return httpx.Response(
            302, headers={"Location": "https://attacker.invalid/keys"}
        )

    app = create_app(
        environ=environment(),
        version=VERSION,
        jwks_transport=httpx.MockTransport(redirect),
        gateway_transport=httpx.MockTransport(fake.gateway),
        credential_factory=fake.credential,
        resolve_addresses=fake.resolve,
    )
    with local_http(app) as client:
        assert infer(client, fake).status_code == 503
    assert len(calls) == 1
    assert_no_inference(fake)


def test_keys_are_cached_and_unknown_kid_cannot_cause_fetch_storm(fake):
    with local_http(fake.app()) as client:
        assert infer(client, fake).status_code == 200
        fetched = len(fake.calls["jwks"])
        assert fetched == 2
        for _ in range(3):
            assert infer(client, fake).status_code == 200
            assert (
                infer(
                    client, fake, token=fake.token(_headers={"kid": "unknown"})
                ).status_code
                == 401
            )
        assert len(fake.calls["jwks"]) == fetched
        assert len(fake.calls["gateway"]) == 4


@pytest.mark.parametrize(
    "key_change",
    [
        {"alg": "HS256"},
        {"use": "enc"},
        {"key_ops": ["sign"]},
        {"issuer": "https://login.microsoftonline.com/other-tenant/v2.0"},
    ],
)
def test_jwks_algorithm_use_and_issuer_are_constrained(fake, key_change):
    fake.jwk.update(key_change)
    with local_http(fake.app()) as client:
        assert infer(client, fake).status_code == 401
    assert_no_inference(fake)


def test_provider_cannot_report_output_above_configured_cap(fake):
    body = model_response()
    body["usage"] = {"input_tokens": 7, "output_tokens": 65, "total_tokens": 72}
    fake.reply = httpx.Response(200, json=body)
    with local_http(fake.app()) as client:
        assert infer(client, fake).status_code == 502


def test_lone_surrogate_input_is_rejected_without_credential_call(fake):
    with local_http(fake.app()) as client:
        response = client.post(
            "/infer",
            content=b'{"input":"\\ud800"}',
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer " + fake.token(),
            },
        )
        assert response.status_code == 400
    assert_no_inference(fake)


def test_incomplete_output_and_refusal_are_not_rewritten_as_successful_answers(fake):
    body = model_response()
    body["status"] = "incomplete"
    body["incomplete_details"] = {"reason": "max_output_tokens"}
    fake.reply = httpx.Response(200, json=body)
    with local_http(fake.app()) as client:
        assert infer(client, fake).json() == body
        body = model_response()
        body["output"][0]["content"] = [
            {"type": "refusal", "refusal": "Synthetic refusal."}
        ]
        fake.reply = httpx.Response(200, json=body)
        assert infer(client, fake).json() == body


def test_exact_audiences_are_not_silently_changed(fake):
    env = environment()
    env["SMOKE_API_AUDIENCE"] = "api://synthetic-smoke/"
    env["INFERENCE_GATEWAY_AUDIENCE"] = "api://synthetic-gateway/"
    with local_http(fake.app(env)) as client:
        assert (
            infer(
                client, fake, token=fake.token(aud="api://synthetic-smoke/")
            ).status_code
            == 200
        )
    assert fake.calls["tokens"] == ["api://synthetic-gateway//.default"]
