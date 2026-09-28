"""A stateless, text-only Entra API. No credential or network work at startup."""

import asyncio
import ipaddress
import json
import logging
import os
import re
import socket
import time
import uuid
from collections.abc import Awaitable, Callable, Mapping
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import urlsplit

import httpx
import jwt
from azure.core.credentials import AccessToken
from azure.core.exceptions import AzureError
from azure.identity import ManagedIdentityCredential
from starlette.applications import Starlette
from starlette.concurrency import run_in_threadpool
from starlette.requests import ClientDisconnect, Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route


MAX_REQUEST_BYTES = 65536
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_JWT_BYTES = 16384
LOGGER = logging.getLogger("developer-smoke")
PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(cidr)
    for cidr in (
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "fc00::/7",
    )
)
SPOOF_HEADERS = frozenset(
    {
        "x-project",
        "x-project-id",
        "x-model",
        "x-model-id",
        "x-caller-id",
        "x-ms-client-principal",
        "x-ms-client-principal-id",
        "x-ms-token-aad-access-token",
        "api-key",
        "ocp-apim-subscription-key",
    }
)


class Credential(Protocol):
    def get_token(self, scope: str) -> AccessToken: ...
    def close(self) -> None: ...


class ServiceError(Exception):
    def __init__(
        self, status: int, code: str, headers: Mapping[str, str] | None = None
    ):
        super().__init__(code)
        self.status = status
        self.code = code
        self.headers = dict(headers or {})


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_json_key")
        result[key] = value
    return result


def strict_json(value: bytes | str):
    def invalid_constant(_):
        raise ValueError("invalid_json_constant")

    return json.loads(
        value, object_pairs_hook=unique_object, parse_constant=invalid_constant
    )


def canonical_uuid(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}",
        value,
    ):
        raise ValueError("invalid_object_id")
    return str(uuid.UUID(value))


def https_endpoint(value: str, host_pattern: str, path: str) -> str:
    if not isinstance(value, str) or not value or re.search(r"[\s\\\x00-\x1f]", value):
        raise ValueError("invalid_endpoint")
    uri = urlsplit(value)
    if (
        uri.scheme != "https"
        or uri.username is not None
        or uri.password is not None
        or uri.port not in (None, 443)
        or uri.query
        or uri.fragment
        or uri.path != path
        or not re.fullmatch(host_pattern, uri.hostname or "", re.ASCII)
        or uri.netloc.endswith(".")
        or "%" in uri.netloc
    ):
        raise ValueError("invalid_endpoint")
    return f"https://{uri.hostname}{path}"


def audience(value: str) -> str:
    if re.fullmatch(r"[0-9a-fA-F-]{36}", value or ""):
        canonical_uuid(value)
        return value
    uri = urlsplit(value or "")
    if (
        uri.scheme not in ("api", "https")
        or not uri.netloc
        or uri.username
        or uri.password
        or uri.query
        or uri.fragment
        or re.search(r"[\s\\\x00-\x1f]", value)
        or value.endswith("/.default")
    ):
        raise ValueError("invalid_audience")
    return value


@dataclass(frozen=True)
class Settings:
    tenant: str
    client_id: str
    gateway_endpoint: str
    gateway_audience: str
    api_audience: str
    object_ids: frozenset[str]
    group_ids: frozenset[str]
    model: str
    max_output_tokens: int
    app_config_endpoint: str

    @classmethod
    def from_environment(cls, env: Mapping[str, str]) -> "Settings":
        def required(name):
            value = env.get(name)
            if not isinstance(value, str) or not value:
                raise ValueError("missing_" + name)
            return value

        def identifiers(name):
            values = strict_json(required(name))
            if not isinstance(values, list):
                raise ValueError("invalid_" + name)
            return frozenset(canonical_uuid(value) for value in values)

        if required("INFERENCE_ACCESS_MODE") != "gateway":
            raise ValueError("gateway_mode_required")
        model = required("SMOKE_MODEL_DEPLOYMENT")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", model):
            raise ValueError("invalid_model")
        cap = required("SMOKE_MAX_OUTPUT_TOKENS")
        if not re.fullmatch(r"[1-9][0-9]{0,9}", cap) or int(cap) > 2147483647:
            raise ValueError("invalid_output_token_cap")
        objects, groups = (
            identifiers("SMOKE_ALLOWED_OBJECT_IDS"),
            identifiers("SMOKE_ALLOWED_GROUP_IDS"),
        )
        if not objects and not groups:
            raise ValueError("caller_allowlist_required")
        return cls(
            canonical_uuid(required("AZURE_TENANT_ID")),
            canonical_uuid(required("AZURE_CLIENT_ID")),
            https_endpoint(
                required("INFERENCE_GATEWAY_ENDPOINT"),
                r"[a-z0-9][a-z0-9-]*\.azure-api\.net",
                "/inference/v1/responses",
            ),
            audience(required("INFERENCE_GATEWAY_AUDIENCE")),
            audience(required("SMOKE_API_AUDIENCE")),
            objects,
            groups,
            model,
            int(cap),
            https_endpoint(
                required("APP_CONFIG_ENDPOINT").removesuffix("/"),
                r"[a-z0-9][a-z0-9-]*\.azconfig\.io",
                "",
            ),
        )


async def system_addresses(hostname: str) -> list[str]:
    records = await asyncio.get_running_loop().getaddrinfo(
        hostname,
        443,
        type=socket.SOCK_STREAM,
        proto=socket.IPPROTO_TCP,
    )
    return list(dict.fromkeys(record[4][0] for record in records))


async def bounded_body(response: httpx.Response, maximum: int) -> bytes:
    chunks = bytearray()
    async for chunk in response.aiter_bytes():
        chunks.extend(chunk)
        if len(chunks) > maximum:
            raise ServiceError(502, "upstream_body_too_large")
    return bytes(chunks)


class EntraValidator:
    def __init__(self, transport: httpx.AsyncBaseTransport | None):
        self.transport = transport
        self.cache = {}
        self.lock = asyncio.Lock()
        self.client = None

    async def document(self, url: str) -> dict:
        if self.client is None:
            self.client = httpx.AsyncClient(
                transport=self.transport,
                trust_env=False,
                follow_redirects=False,
                timeout=10,
            )
        async with self.client.stream(
            "GET", url, headers={"Accept": "application/json"}
        ) as response:
            if response.status_code != 200:
                raise ServiceError(503, "identity_provider_unavailable")
            try:
                result = strict_json(await bounded_body(response, MAX_REQUEST_BYTES))
            except (ValueError, UnicodeError, RecursionError) as error:
                raise ServiceError(503, "invalid_identity_metadata") from error
            if not isinstance(result, dict):
                raise ServiceError(503, "invalid_identity_metadata")
            return result

    async def key(self, settings: Settings, version: str, kid: str):
        expected_issuer = (
            f"https://login.microsoftonline.com/{settings.tenant}/v2.0"
            if version == "2.0"
            else f"https://sts.windows.net/{settings.tenant}/"
        )
        cache_key = (settings.tenant, version)
        async with self.lock:
            cached = self.cache.get(cache_key)
            now = time.monotonic()
            # Cache misses are refreshable, but unknown kid values cannot cause an unbounded fetch storm.
            refresh = cached is None or now - cached[0] >= 300
            if cached and not any(key.get("kid") == kid for key in cached[1]):
                refresh = now - cached[0] >= 30
            if refresh:
                version_path = "/v2.0" if version == "2.0" else ""
                metadata = await self.document(
                    f"https://login.microsoftonline.com/{settings.tenant}{version_path}/.well-known/openid-configuration",
                )
                if metadata.get("issuer") != expected_issuer:
                    raise ServiceError(503, "identity_issuer_mismatch")
                jwks_uri = metadata.get("jwks_uri", "")
                allowed = (
                    rf"https://login\.microsoftonline\.com/(?:{re.escape(settings.tenant)}|common|organizations)"
                    r"/discovery/(?:v2\.0/)?keys"
                )
                if not isinstance(jwks_uri, str) or not re.fullmatch(allowed, jwks_uri):
                    raise ServiceError(503, "invalid_identity_key_endpoint")
                document = await self.document(jwks_uri)
                keys = document.get("keys")
                if (
                    not isinstance(keys, list)
                    or not keys
                    or any(not isinstance(key, dict) for key in keys)
                ):
                    raise ServiceError(503, "invalid_identity_keys")
                cached = (now, keys)
                self.cache[cache_key] = cached
            matches = [key for key in cached[1] if key.get("kid") == kid]
        if len(matches) != 1:
            raise ServiceError(401, "invalid_caller")
        key = matches[0]
        key_issuer = key.get("issuer", expected_issuer)
        if (
            key.get("kty") != "RSA"
            or key.get("use") != "sig"
            or key.get("alg", "RS256") != "RS256"
            or key.get("key_ops", ["verify"]) != ["verify"]
            or not isinstance(key_issuer, str)
            or key_issuer.replace("{tenantid}", settings.tenant) != expected_issuer
        ):
            raise ServiceError(401, "invalid_caller")
        return jwt.PyJWK.from_dict(key, algorithm="RS256").key, expected_issuer

    async def validate(self, request: Request, settings: Settings) -> str:
        values = request.headers.getlist("authorization")
        if len(values) != 1 or not values[0].startswith("Bearer "):
            raise ServiceError(401, "invalid_caller")
        token = values[0][7:]
        if (
            not token
            or len(token) > MAX_JWT_BYTES
            or any(char.isspace() for char in token)
        ):
            raise ServiceError(401, "invalid_caller")
        try:
            header = jwt.get_unverified_header(token)
            if (
                header.get("alg") != "RS256"
                or not isinstance(header.get("kid"), str)
                or not 0 < len(header["kid"]) <= 256
                or any(name in header for name in ("jku", "jwk", "x5u", "crit", "b64"))
            ):
                raise ServiceError(401, "invalid_caller")
            unverified = jwt.decode(token, options={"verify_signature": False})
            version = unverified.get("ver")
            if version not in ("1.0", "2.0"):
                raise ServiceError(401, "invalid_caller")
            key, issuer = await self.key(settings, version, header["kid"])
            claims = jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                audience=settings.api_audience,
                issuer=issuer,
                options={
                    "require": ["exp", "nbf", "iss", "aud", "tid", "oid", "ver"],
                    "strict_aud": True,
                },
            )
            if (
                canonical_uuid(claims["tid"]) != settings.tenant
                or type(claims["exp"]) not in (int, float)
                or type(claims["nbf"]) not in (int, float)
                or claims["nbf"] >= claims["exp"]
            ):
                raise ServiceError(401, "invalid_caller")
            oid = canonical_uuid(claims["oid"])
            groups = claims.get("groups", [])
            if not isinstance(groups, list):
                raise ServiceError(401, "invalid_caller")
            groups = {canonical_uuid(group) for group in groups}
        except (jwt.PyJWTError, ValueError, TypeError, KeyError) as error:
            raise ServiceError(401, "invalid_caller") from error
        if oid not in settings.object_ids and not groups.intersection(
            settings.group_ids
        ):
            raise ServiceError(403, "caller_not_allowed")
        return oid

    async def close(self):
        if self.client is not None:
            await self.client.aclose()


class Gateway:
    def __init__(self, transport, credential_factory, resolve_addresses):
        self.transport = transport
        self.credential_factory = credential_factory
        self.resolve_addresses = resolve_addresses
        self.credential = None
        self.client = None

    async def infer(self, settings: Settings, text: str, correlation: str):
        uri = httpx.URL(settings.gateway_endpoint)
        addresses = await self.resolve_addresses(uri.host)
        if not addresses:
            raise ServiceError(503, "private_gateway_unavailable")
        for value in addresses:
            address = ipaddress.ip_address(value)
            if not any(
                address.version == network.version and address in network
                for network in PRIVATE_NETWORKS
            ):
                raise ServiceError(503, "private_gateway_required")
        # Pin the connection to the checked address, retaining the real host for TLS/SNI.
        # A second DNS lookup must not redirect a bearer token to a public address.
        pinned_uri = uri.copy_with(host=addresses[0])
        if self.credential is None:
            self.credential = self.credential_factory(
                client_id=settings.client_id,
                retry_total=0,
                connection_timeout=10,
                read_timeout=10,
                logging_enable=False,
            )
        access = await run_in_threadpool(
            self.credential.get_token,
            settings.gateway_audience + "/.default",
        )
        if not access.token or access.expires_on <= time.time():
            raise ServiceError(503, "managed_identity_unavailable")
        if self.client is None:
            self.client = httpx.AsyncClient(
                transport=self.transport,
                trust_env=False,
                follow_redirects=False,
                timeout=httpx.Timeout(45, connect=10),
                limits=httpx.Limits(max_connections=16),
            )
        async with self.client.stream(
            "POST",
            pinned_uri,
            headers={
                "Host": uri.host,
                "Authorization": "Bearer " + access.token,
                "Accept": "application/json",
                "x-correlation-id": correlation,
                "x-ms-client-request-id": correlation,
            },
            extensions={"sni_hostname": uri.host},
            json={
                "input": text,
                "model": settings.model,
                "max_output_tokens": settings.max_output_tokens,
                "stream": False,
                "store": False,
            },
        ) as response:
            forwarded = {}
            for name in (
                "retry-after",
                "apim-request-id",
                "x-request-id",
                "x-ms-request-id",
            ):
                value = response.headers.get(name)
                if value and len(value) <= 256 and re.fullmatch(r"[ -~]+", value):
                    forwarded[name] = value
            if response.status_code != 200:
                status = (
                    response.status_code if 400 <= response.status_code <= 599 else 502
                )
                raise ServiceError(status, "gateway_rejected", forwarded)
            if (
                response.headers.get("content-type", "").split(";")[0].strip()
                != "application/json"
            ):
                raise ServiceError(502, "invalid_gateway_response")
            raw = await bounded_body(response, MAX_RESPONSE_BYTES)
        try:
            body = strict_json(raw)
            if (
                not isinstance(body, dict)
                or body.get("error")
                or body.get("object") != "response"
                or body.get("status") not in ("completed", "incomplete")
                or not isinstance(body.get("id"), str)
                or not isinstance(body.get("output"), list)
            ):
                raise ValueError("invalid_response")
            usage = body.get("usage")
            if not isinstance(usage, dict) or any(
                type(usage.get(key)) is not int or usage[key] < 0
                for key in ("input_tokens", "output_tokens", "total_tokens")
            ):
                raise ValueError("invalid_usage")
            if usage["total_tokens"] != usage["input_tokens"] + usage["output_tokens"]:
                raise ValueError("invalid_usage")
            if usage["output_tokens"] > settings.max_output_tokens:
                raise ValueError("output_cap_exceeded")
            has_text = False
            for item in body["output"]:
                if not isinstance(item, dict) or item.get("type") not in (
                    "message",
                    "reasoning",
                ):
                    raise ValueError("unsupported_output")
                if item["type"] == "message":
                    if item.get("role") != "assistant" or not isinstance(
                        item.get("content"), list
                    ):
                        raise ValueError("unsupported_output")
                    for content in item["content"]:
                        if not isinstance(content, dict) or content.get("type") not in (
                            "output_text",
                            "refusal",
                        ):
                            raise ValueError("unsupported_output")
                        value = content.get(
                            "text" if content["type"] == "output_text" else "refusal"
                        )
                        if not isinstance(value, str):
                            raise ValueError("unsupported_output")
                        has_text = has_text or bool(value)
            if body["status"] == "completed" and not has_text:
                raise ValueError("missing_output")
        except (ValueError, TypeError, KeyError, UnicodeError, RecursionError) as error:
            raise ServiceError(502, "invalid_gateway_response") from error
        return Response(raw, media_type="application/json", headers=forwarded), usage

    async def close(self):
        if self.client is not None:
            await self.client.aclose()
        if self.credential is not None:
            await run_in_threadpool(self.credential.close)


def build_version() -> str:
    path = Path(__file__).with_name("BUILD_VERSION")
    return path.read_text(encoding="ascii").strip() if path.is_file() else "unbuilt"


def create_app(
    *,
    environ: Mapping[str, str] | None = None,
    version: str | None = None,
    jwks_transport: httpx.AsyncBaseTransport | None = None,
    gateway_transport: httpx.AsyncBaseTransport | None = None,
    credential_factory: Callable[..., Credential] = ManagedIdentityCredential,
    resolve_addresses: Callable[[str], Awaitable[list[str]]] = system_addresses,
) -> Starlette:
    """Python-level transport injection is for tests; no production auth-bypass setting exists."""
    env = dict(os.environ if environ is None else environ)
    application_version = build_version() if version is None else version
    validator = EntraValidator(jwks_transport)
    gateway = Gateway(gateway_transport, credential_factory, resolve_addresses)

    @asynccontextmanager
    async def lifespan(_app):
        yield
        await validator.close()
        await gateway.close()

    def identity(status):
        return {
            "service": "developer-smoke",
            "version": application_version,
            "status": status,
        }

    def settings():
        try:
            value = Settings.from_environment(env)
            if not re.fullmatch(r"[0-9a-f]{40}", application_version):
                raise ValueError("immutable_build_version_required")
            return value
        except (ValueError, TypeError, UnicodeError, RecursionError) as error:
            raise ServiceError(503, "invalid_local_configuration") from error

    async def health(_request):
        return JSONResponse(identity("ok"))

    async def ready(_request):
        try:
            settings()
        except ServiceError as error:
            return JSONResponse(
                {**identity("not_ready"), "error": {"code": error.code}},
                status_code=error.status,
            )
        return JSONResponse(identity("ready"))

    async def infer(request):
        correlation, oid, model, usage = str(uuid.uuid4()), None, None, {}
        try:
            config = settings()
            model = config.model
            correlations = request.headers.getlist("x-correlation-id")
            if correlations:
                if len(correlations) != 1:
                    raise ServiceError(400, "invalid_correlation")
                try:
                    correlation = canonical_uuid(correlations[0])
                except ValueError as error:
                    raise ServiceError(400, "invalid_correlation") from error
            if request.query_params or SPOOF_HEADERS.intersection(
                request.headers.keys()
            ):
                raise ServiceError(400, "unsupported_request")
            if (
                request.headers.get("content-type", "").lower().replace(" ", "")
                not in (
                    "application/json",
                    "application/json;charset=utf-8",
                )
                or request.headers.get("content-encoding", "identity") != "identity"
            ):
                raise ServiceError(415, "json_utf8_required")
            body = bytearray()
            async with asyncio.timeout(60):
                async for chunk in request.stream():
                    body.extend(chunk)
                    if len(body) > MAX_REQUEST_BYTES:
                        raise ServiceError(413, "request_too_large")
                try:
                    payload = strict_json(bytes(body).decode("utf-8"))
                except (ValueError, UnicodeError, RecursionError) as error:
                    raise ServiceError(400, "invalid_json") from error
                if (
                    not isinstance(payload, dict)
                    or set(payload) != {"input"}
                    or not isinstance(payload["input"], str)
                    or not payload["input"].strip()
                ):
                    raise ServiceError(400, "text_input_only")
                # Reject lone surrogate escapes before acquiring a token or sending UTF-8.
                try:
                    payload["input"].encode("utf-8")
                except UnicodeError as error:
                    raise ServiceError(400, "invalid_utf8") from error
                oid = await validator.validate(request, config)
                response, usage = await gateway.infer(
                    config, payload["input"], correlation
                )
        except ServiceError as error:
            headers = error.headers
            if error.status == 401:
                headers["WWW-Authenticate"] = "Bearer"
            response = JSONResponse(
                {"error": {"code": error.code}},
                status_code=error.status,
                headers=headers,
            )
        except TimeoutError:
            response = JSONResponse(
                {"error": {"code": "upstream_timeout"}}, status_code=504
            )
        except (httpx.HTTPError, AzureError, OSError):
            response = JSONResponse(
                {"error": {"code": "upstream_unavailable"}}, status_code=503
            )
        except ClientDisconnect:
            response = JSONResponse(
                {"error": {"code": "request_disconnected"}}, status_code=400
            )
        response.headers["x-correlation-id"] = correlation
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        LOGGER.info(
            json.dumps(
                {
                    "correlation": correlation,
                    "identity": oid,
                    "model": model,
                    "input_tokens": usage.get("input_tokens"),
                    "output_tokens": usage.get("output_tokens"),
                    "total_tokens": usage.get("total_tokens"),
                    "status": response.status_code,
                },
                separators=(",", ":"),
            )
        )
        return response

    return Starlette(
        debug=False,
        lifespan=lifespan,
        routes=[
            Route("/health", health, methods=["GET"]),
            Route("/ready", ready, methods=["GET"]),
            Route("/infer", infer, methods=["POST"]),
        ],
    )


if __name__ == "__main__":
    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    for noisy in ("azure", "httpx", "httpcore", "uvicorn"):
        logger = logging.getLogger(noisy)
        logger.handlers = [logging.NullHandler()]
        logger.propagate = False
        logger.setLevel(logging.CRITICAL)
    uvicorn.run(
        create_app(),
        host="0.0.0.0",
        port=8080,
        access_log=False,
        log_config=None,
        server_header=False,
    )
