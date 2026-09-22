FROM python:3.13.15-slim-bookworm@sha256:ed86c82274b3c69b52fb5820f358f0bd7df0b603332063cb5c6e32bd220c3e6e

ARG SOURCE_COMMIT
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements.lock /app/requirements.lock
RUN python -m pip install --no-cache-dir --require-hashes --only-binary=:all: -r requirements.lock
COPY smoke_service.py /app/smoke_service.py
RUN python -c "import pathlib,re,sys; sha=sys.argv[1]; assert re.fullmatch('[0-9a-f]{40}',sha), 'SOURCE_COMMIT must be the immutable release SHA'; pathlib.Path('BUILD_VERSION').write_text(sha+'\n',encoding='ascii')" "$SOURCE_COMMIT" \
    && chmod -R a=rX /app
LABEL org.opencontainers.image.title="developer-smoke" \
    org.opencontainers.image.revision=$SOURCE_COMMIT
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import json,urllib.request; r=json.load(urllib.request.urlopen('http://127.0.0.1:8080/health',timeout=3)); assert r['service']=='developer-smoke' and r['status']=='ok'"]
CMD ["python", "smoke_service.py"]
