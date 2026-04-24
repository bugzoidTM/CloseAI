from __future__ import annotations

import json
import os
import threading
from pathlib import Path
from typing import Any, Generator

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, ValidationError
import requests
from starlette.concurrency import run_in_threadpool

from validate import check_python_syntax

APP_DIR = Path(__file__).resolve().parent
DEFAULT_MODEL_PATH = APP_DIR / "modelo_python.gguf"

SYSTEM_PROMPT = (
    "Voce e um especialista em Python. Gere codigo limpo, comentado e seguindo "
    "PEP 8. Use type hints e docstrings. Responda apenas com o bloco de codigo "
    "markdown."
)


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on", "sim"}


def _model_path() -> Path:
    return Path(os.getenv("MODEL_PATH", str(DEFAULT_MODEL_PATH))).expanduser().resolve()


class GenerateRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    prompt: str = Field(..., min_length=1, max_length=12000)
    max_tokens: int = Field(default=512, ge=1, le=4096)
    validate_syntax: bool = Field(default=True, alias="validate")
    temperature: float = Field(default=0.2, ge=0.0, le=2.0)
    top_p: float = Field(default=0.95, ge=0.0, le=1.0)


def _llama_server_url() -> str:
    return os.getenv("LLAMA_SERVER_URL", "").rstrip("/")


def _use_llama_server_backend() -> bool:
    return bool(_llama_server_url())


def _llama_server_model_alias() -> str:
    alias = os.getenv("LLAMA_SERVER_MODEL", "").strip()
    return alias or _model_path().name


class ModelRuntime:
    def __init__(self) -> None:
        self._llm: Any | None = None
        self._lock = threading.Lock()

    @property
    def loaded(self) -> bool:
        return self._llm is not None

    def get(self) -> Any:
        if self._llm is not None:
            return self._llm

        with self._lock:
            if self._llm is not None:
                return self._llm

            model_path = _model_path()
            if not model_path.exists():
                raise RuntimeError(
                    "Modelo GGUF nao encontrado. Gere ou copie o arquivo "
                    f"para {model_path} ou configure MODEL_PATH."
                )

            try:
                from llama_cpp import Llama
            except ImportError as exc:
                raise RuntimeError(
                    "Pacote llama-cpp-python nao instalado. Execute deploy.ps1 "
                    "ou instale as dependencias de requirements.txt."
                ) from exc

            self._llm = Llama(
                model_path=str(model_path),
                n_ctx=_env_int("N_CTX", 4096),
                n_threads=_env_int("N_THREADS", 2),
                n_batch=_env_int("N_BATCH", 512),
                n_gpu_layers=_env_int("N_GPU_LAYERS", 0),
                flash_attn=False,
                verbose=False,
                logits_all=False,
            )
            return self._llm


runtime = ModelRuntime()
app = FastAPI(title="Python Code LLM API", version="1.0.0")


@app.on_event("startup")
def preload_model_if_enabled() -> None:
    if _env_bool("PRELOAD_MODEL", False):
        runtime.get()


def _messages(prompt: str) -> list[dict[str, str]]:
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]


def _completion_payload(payload: GenerateRequest) -> dict[str, Any]:
    return {
        "messages": _messages(payload.prompt),
        "max_tokens": payload.max_tokens,
        "temperature": payload.temperature,
        "top_p": payload.top_p,
        "stop": ["</s>"],
    }


async def _parse_generate_request(request: Request) -> GenerateRequest:
    data: dict[str, Any] = dict(request.query_params)
    body = await request.body()

    if body:
        content_type = request.headers.get("content-type", "").lower()
        if "application/json" in content_type:
            try:
                parsed = json.loads(body.decode("utf-8"))
            except json.JSONDecodeError as exc:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"JSON invalido: {exc}",
                ) from exc

            if not isinstance(parsed, dict):
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="O corpo JSON deve ser um objeto.",
                )
            data.update(parsed)
        else:
            text_prompt = body.decode("utf-8").strip()
            if text_prompt:
                data.setdefault("prompt", text_prompt)

    try:
        return GenerateRequest(**data)
    except ValidationError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=exc.errors(),
        ) from exc


def _generate_code(payload: GenerateRequest) -> str:
    if _use_llama_server_backend():
        return _generate_code_via_llama_server(payload)

    llm = runtime.get()
    output = llm.create_chat_completion(**_completion_payload(payload))
    try:
        return output["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(f"Resposta inesperada do modelo: {output!r}") from exc


def _generate_code_via_llama_server(payload: GenerateRequest) -> str:
    response = requests.post(
        f"{_llama_server_url()}/v1/chat/completions",
        json={
            "model": _llama_server_model_alias(),
            "messages": _messages(payload.prompt),
            "max_tokens": payload.max_tokens,
            "temperature": payload.temperature,
            "top_p": payload.top_p,
        },
        timeout=900,
    )
    response.raise_for_status()
    data = response.json()
    try:
        return data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(f"Resposta inesperada do llama-server: {data!r}") from exc


def _llama_server_health() -> bool:
    if not _use_llama_server_backend():
        return False
    try:
        response = requests.get(f"{_llama_server_url()}/health", timeout=5)
        return response.status_code == 200
    except requests.RequestException:
        return False


@app.get("/health")
def health() -> dict[str, Any]:
    model_path = _model_path()
    backend = "llama-server" if _use_llama_server_backend() else "llama-cpp-python"
    ready = _llama_server_health() if _use_llama_server_backend() else model_path.exists()
    return {
        "status": "ok",
        "backend": backend,
        "ready": ready,
        "model_path": str(model_path),
        "model_loaded": runtime.loaded,
        "llama_server_url": _llama_server_url() or None,
        "n_ctx": _env_int("N_CTX", 4096),
        "n_threads": _env_int("N_THREADS", 2),
        "n_batch": _env_int("N_BATCH", 512),
    }


@app.get("/ready")
def ready() -> dict[str, Any]:
    model_path = _model_path()
    if not model_path.exists():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Modelo GGUF nao encontrado em {model_path}.",
        )
    if _use_llama_server_backend() and not _llama_server_health():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"llama-server indisponivel em {_llama_server_url()}.",
        )
    return {"ready": True, "model_path": str(model_path)}


@app.post("/generate")
async def generate(request: Request) -> dict[str, Any]:
    payload = await _parse_generate_request(request)

    try:
        code = await run_in_threadpool(_generate_code, payload)
    except RuntimeError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
        ) from exc

    response: dict[str, Any] = {"code": code}
    if payload.validate_syntax:
        is_valid, error = check_python_syntax(code)
        response.update({"syntax_valid": is_valid, "error": error})

    return response


def _stream_events(payload: GenerateRequest) -> Generator[str, None, None]:
    if _use_llama_server_backend():
        yield from _stream_events_via_llama_server(payload)
        return

    try:
        llm = runtime.get()
        stream = llm.create_chat_completion(
            **_completion_payload(payload),
            stream=True,
        )

        for chunk in stream:
            choices = chunk.get("choices") or []
            if not choices:
                continue

            delta = choices[0].get("delta", {}).get("content", "")
            if delta:
                yield f"data: {json.dumps({'token': delta})}\n\n"

            if choices[0].get("finish_reason"):
                yield f"data: {json.dumps({'done': True})}\n\n"
                break
    except RuntimeError as exc:
        yield f"event: error\ndata: {json.dumps({'error': str(exc)})}\n\n"

    yield "data: [DONE]\n\n"


def _stream_events_via_llama_server(payload: GenerateRequest) -> Generator[str, None, None]:
    try:
        with requests.post(
            f"{_llama_server_url()}/v1/chat/completions",
            json={
                "model": _llama_server_model_alias(),
                "messages": _messages(payload.prompt),
                "max_tokens": payload.max_tokens,
                "temperature": payload.temperature,
                "top_p": payload.top_p,
                "stream": True,
            },
            stream=True,
            timeout=900,
        ) as response:
            response.raise_for_status()
            for raw_line in response.iter_lines(decode_unicode=True):
                if not raw_line:
                    continue
                if not raw_line.startswith("data: "):
                    continue

                data = raw_line[6:]
                if data == "[DONE]":
                    break

                chunk = json.loads(data)
                choices = chunk.get("choices") or []
                if not choices:
                    continue

                delta = choices[0].get("delta", {}).get("content", "")
                if delta:
                    yield f"data: {json.dumps({'token': delta})}\n\n"

                if choices[0].get("finish_reason"):
                    yield f"data: {json.dumps({'done': True})}\n\n"
                    break
    except (requests.RequestException, json.JSONDecodeError) as exc:
        yield f"event: error\ndata: {json.dumps({'error': str(exc)})}\n\n"

    yield "data: [DONE]\n\n"


@app.post("/generate/stream")
async def generate_stream(request: Request) -> StreamingResponse:
    payload = await _parse_generate_request(request)
    headers = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no"}
    return StreamingResponse(
        _stream_events(payload),
        media_type="text/event-stream",
        headers=headers,
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "server:app",
        host=os.getenv("HOST", "127.0.0.1"),
        port=_env_int("PORT", 8000),
        log_level="info",
    )
