# Relatório de Vulnerabilidades de Segurança

## Resumo Executivo

Foram identificadas **10 vulnerabilidades de segurança** no código analisado, variando de críticas a baixas. Este documento detalha cada vulnerabilidade com localização, descrição, impacto e recomendações de correção.

---

## Vulnerabilidades Críticas e Altas

### 1. Injeção de Comando (Command Injection)

**Arquivos:** `docker-entrypoint.sh`, `convert_to_gguf.sh`  
**Severidade:** 🔴 **CRÍTICA**

#### Descrição
Os scripts shell aceitam parâmetros de entrada (variáveis de ambiente e argumentos de linha de comando) que são utilizados diretamente em comandos sem validação adequada.

#### Localização
- `docker-entrypoint.sh`: Linhas 194-197 (chamada ao `convert_to_gguf.sh`)
- `convert_to_gguf.sh`: Linhas 24-34 (parsing de argumentos)
- `convert_to_gguf.sh`: Linha 146 (execução de script Python com path não validado)

#### Código Vulnerável
```bash
# docker-entrypoint.sh:194-197
/bin/bash "$APP_DIR/convert_to_gguf.sh" \
    --model-dir "$MODEL_OUTPUT_DIR" \
    --out-file "$MODEL_PATH" \
    --llama-cpp-dir /opt/llama.cpp
```

```bash
# convert_to_gguf.sh:24-34
--model-dir)
    MODEL_DIR="${2:?Valor ausente para --model-dir}"
    shift 2
    ;;
```

#### Impacto
Um atacante com controle sobre variáveis de ambiente ou argumentos pode executar comandos arbitrários no sistema, potencialmente comprometendo todo o container/servidor.

#### Recomendação
- Validar e sanitizar todos os inputs antes de usá-los em comandos
- Usar arrays bash para passar argumentos de forma segura
- Implementar whitelist de paths permitidos
- Restringir permissões do processo

---

### 2. Path Traversal

**Arquivo:** `server.py`  
**Severidade:** 🔴 **CRÍTICA**

#### Descrição
A variável de ambiente `MODEL_PATH` é usada para carregar modelos sem validação adequada, permitindo que um atacante acesse arquivos fora do diretório pretendido.

#### Localização
- `server.py`: Linha 45 (`_model_path()`)
- `server.py`: Linhas 88-93 (carregamento do modelo)

#### Código Vulnerável
```python
# server.py:45
def _model_path() -> Path:
    return Path(os.getenv("MODEL_PATH", str(DEFAULT_MODEL_PATH))).expanduser().resolve()
```

```python
# server.py:88-93
model_path = _model_path()
if not model_path.exists():
    raise RuntimeError(...)
```

#### Impacto
Leitura arbitrária de arquivos no sistema, potencial exposição de credenciais, códigos fonte e dados sensíveis.

#### Recomendação
```python
def _model_path() -> Path:
    base_dir = APP_DIR  # ou outro diretório base seguro
    requested = Path(os.getenv("MODEL_PATH", str(DEFAULT_MODEL_PATH)))
    
    # Resolver e validar que está dentro do diretório permitido
    resolved = requested.expanduser().resolve()
    try:
        resolved.relative_to(base_dir.resolve())
    except ValueError:
        raise SecurityError(f"Model path must be within {base_dir}")
    
    return resolved
```

---

### 3. SSRF (Server-Side Request Forgery)

**Arquivo:** `server.py`  
**Severidade:** 🟠 **ALTA**

#### Descrição
O proxy para o llama-server permite requisições a URLs arbitrárias configuradas via `LLAMA_SERVER_URL`, sem validação de allowlist.

#### Localização
- `server.py`: Linhas 58-63 (`_llama_server_url()`)
- `server.py`: Linhas 190-207 (`_generate_code_via_llama_server()`)
- `server.py`: Linhas 304-345 (`_stream_events_via_llama_server()`)

#### Código Vulnerável
```python
# server.py:190-201
def _generate_code_via_llama_server(payload: GenerateRequest) -> str:
    response = requests.post(
        f"{_llama_server_url()}/v1/chat/completions",
        json={...},
        timeout=900,
    )
```

#### Impacto
Atacantes podem fazer o servidor acessar recursos internos da rede, serviços cloud metadata, ou outros sistemas protegidos por firewall.

#### Recomendação
- Implementar validação de URL com allowlist explícita
- Bloquear IPs privados e localhost em produção
- Validar esquema (apenas http/https)
- Usar biblioteca de validação de URL segura

---

### 4. Zip Slip (Path Traversal via ZIP)

**Arquivo:** `kaggle_pipeline.py`  
**Severidade:** 🟠 **ALTA**

#### Descrição
A extração de arquivos ZIP não valida os paths dos arquivos extraídos, permitindo que um arquivo malicioso no ZIP escreva fora do diretório pretendido.

#### Localização
- `kaggle_pipeline.py`: Linhas 227-234 (`extract_model()`)

#### Código Vulnerável
```python
# kaggle_pipeline.py:227-234
with zipfile.ZipFile(zip_path, "r") as archive:
    archive.extractall(MODEL_OUTPUT_DIR.parent)
```

#### Impacto
Escrita de arquivos arbitrários no sistema, possível execução de código remoto, sobrescrita de arquivos críticos.

#### Recomendação
```python
def extract_model(output_dir: Path) -> Path:
    zip_candidates = sorted(output_dir.glob("**/modelo_python_fundido.zip"))
    if not zip_candidates:
        raise FileNotFoundError(...)
    
    zip_path = zip_candidates[0]
    target_dir = MODEL_OUTPUT_DIR
    
    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.parent.mkdir(parents=True, exist_ok=True)
    
    with zipfile.ZipFile(zip_path, "r") as archive:
        # Validar cada membro antes de extrair
        for member in archive.namelist():
            member_path = (target_dir.parent / member).resolve()
            if not str(member_path).startswith(str(target_dir.parent.resolve())):
                raise SecurityError(f"Zip slip detectado: {member}")
        
        archive.extractall(target_dir.parent)
    
    # ... resto do código
```

---

### 5. Execução Insegura de Subprocesso

**Arquivo:** `kaggle_remote_finetune.py`  
**Severidade:** 🟠 **ALTA**

#### Descrição
O script executa `pip install` baseado em variáveis de ambiente sem validação adequada, permitindo instalação de pacotes maliciosos.

#### Localização
- `kaggle_remote_finetune.py`: Linhas 31-40 (`ensure_module()`)

#### Código Vulnerável
```python
# kaggle_remote_finetune.py:31-40
def ensure_module(module_name: str, pip_spec: str) -> None:
    try:
        importlib.import_module(module_name)
    except ImportError as exc:
        if not ALLOW_PIP_INSTALL:
            raise RuntimeError(...)
        run([sys.executable, "-m", "pip", "install", "-q", pip_spec])
```

#### Impacto
Instalação e execução de código arbitrário no ambiente de execução.

#### Recomendação
- Manter `ALLOW_PIP_INSTALL=0` por padrão em produção
- Usar allowlist estrita de pacotes permitidos
- Verificar hashes dos pacotes instalados
- Considerar ambientes isolados/imutáveis

---

### 6. Falta de Autenticação nas APIs

**Arquivo:** `server.py`  
**Severidade:** 🟠 **ALTA**

#### Descrição
Todos os endpoints da API (`/generate`, `/generate/stream`, `/health`, `/ready`) estão acessíveis sem autenticação.

#### Localização
- `server.py`: Linhas 220-235 (`/health`)
- `server.py`: Linhas 238-251 (`/ready`)
- `server.py`: Linhas 254-271 (`/generate`)
- `server.py`: Linhas 348-356 (`/generate/stream`)

#### Código Vulnerável
```python
@app.post("/generate")
async def generate(request: Request) -> dict[str, Any]:
    payload = await _parse_generate_request(request)
    # Sem verificação de autenticação
```

#### Impacto
Uso não autorizado de recursos, possível negação de serviço, acesso a informações internas, abuso computacional.

#### Recomendação
```python
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

security = HTTPBearer()

async def verify_auth(credentials: HTTPAuthorizationCredentials = Depends(security)):
    token = credentials.credentials
    # Validar token contra secret/configuração
    if not validate_token(token):
        raise HTTPException(status_code=401, detail="Não autorizado")
    return credentials

@app.post("/generate")
async def generate(
    request: Request,
    auth: HTTPAuthorizationCredentials = Depends(verify_auth)
) -> dict[str, Any]:
    # ... implementação
```

---

## Vulnerabilidades Médias

### 7. Manipulação Insegura de Arquivo Temporário

**Arquivo:** `kaggle_remote_finetune.py`  
**Severidade:** 🟡 **MÉDIA**

#### Descrição
Arquivos temporários são criados em locais previsíveis sem verificação de permissões ou uso de APIs seguras.

#### Localização
- `kaggle_remote_finetune.py`: Linhas 18-23 (definição de paths)

#### Recomendação
- Usar `tempfile.mkdtemp()` para diretórios temporários
- Definir permissões restritas (0o700)
- Limpar arquivos temporários após uso

---

### 8. Validação Insuficiente de Input na API

**Arquivo:** `server.py`  
**Severidade:** 🟡 **MÉDIA**

#### Descrição
A fusão de query params com body JSON permite possíveis colisões e bypass de validações.

#### Localização
- `server.py`: Linhas 143-175 (`_parse_generate_request()`)

#### Código Vulnerável
```python
async def _parse_generate_request(request: Request) -> GenerateRequest:
    data: dict[str, Any] = dict(request.query_params)
    body = await request.body()
    
    if body:
        # ... parsing JSON
        data.update(parsed)  # Body sobrescreve query params sem validação
```

#### Recomendação
- Priorizar body sobre query params explicitamente
- Validar tipos e ranges de forma consistente
- Rejeitar parâmetros conflitantes

---

### 9. Padrão de Credenciais Hardcoded

**Arquivo:** `kaggle_pipeline.py`  
**Severidade:** 🟡 **MÉDIA**

#### Descrição
Paths padrão para tokens de API e configurações sensíveis estão hardcoded.

#### Localização
- `kaggle_pipeline.py`: Linhas 24-26

#### Recomendação
- Usar secrets management (Vault, AWS Secrets Manager, etc.)
- Nunca commitar tokens em repositórios
- Implementar rotação de credenciais

---

## Vulnerabilidades Baixas

### 10. Divulgação de Informações

**Arquivo:** `server.py`  
**Severidade:** 🟢 **BAIXA**

#### Descrição
O endpoint `/health` expõe informações detalhadas sobre configuração interna, paths de modelo, e estado do backend.

#### Localização
- `server.py`: Linhas 220-235

#### Código Vulnerável
```python
@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "backend": backend,
        "ready": ready,
        "model_path": str(model_path),  # Expõe path interno
        "model_loaded": runtime.loaded,
        "llama_server_url": _llama_server_url() or None,  # Expõe URL interna
        "n_ctx": _env_int("N_CTX", 4096),
        "n_threads": _env_int("N_THREADS", 2),
        "n_batch": _env_int("N_BATCH", 512),
    }
```

#### Impacto
Reconhecimento facilitado para atacantes, exposição de estrutura interna do sistema.

#### Recomendação
```python
@app.get("/health")
def health() -> dict[str, Any]:
    # Retorna apenas informação essencial
    return {
        "status": "ok",
        "ready": _llama_server_health() if _use_llama_server_backend() else _model_path().exists(),
    }
```

---

## Matriz de Priorização

| ID | Vulnerabilidade | Severidade | CVSS Est. | Prioridade |
|----|-----------------|------------|-----------|------------|
| 1 | Injeção de Comando | Crítica | 9.8 | P0 |
| 2 | Path Traversal | Crítica | 9.1 | P0 |
| 3 | SSRF | Alta | 8.6 | P0 |
| 4 | Zip Slip | Alta | 8.1 | P1 |
| 5 | Subprocesso Inseguro | Alta | 7.8 | P1 |
| 6 | Falta de Autenticação | Alta | 7.5 | P1 |
| 7 | Arquivo Temporário | Média | 5.3 | P2 |
| 8 | Validação de Input | Média | 5.0 | P2 |
| 9 | Credenciais Hardcoded | Média | 4.7 | P2 |
| 10 | Info Disclosure | Baixa | 3.1 | P3 |

---

## Recomendações Gerais

1. **Imediato (P0):** Corrigir injeção de comando, path traversal e SSRF
2. **Curto Prazo (P1):** Implementar autenticação, corrigir zip slip e subprocessos
3. **Médio Prazo (P2):** Melhorar manipulação de temporários e validação de inputs
4. **Contínuo (P3):** Revisar informações expostas em endpoints públicos

### Boas Práticas Adicionais

- Implementar logging de segurança e monitoramento
- Realizar testes de penetração regulares
- Usar ferramentas de SAST/DAST no CI/CD
- Manter dependências atualizadas
- Documentar políticas de segurança

---

*Relatório gerado em: $(date)*  
*Escopo: Código-fonte no diretório /workspace*
