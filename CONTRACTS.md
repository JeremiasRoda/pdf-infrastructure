# Contrato de Infraestructura, Redes y Resiliencia (`CONTRACTS.md`)
**Proyecto:** `pdf-extractext`  
**Cátedra:** Desarrollo de Software — UTN Facultad Regional San Rafael  
**Repositorio Central:** `pdf-infrastructure`  

Este documento define el **contrato oficial de infraestructura, redes, patrones de resiliencia y ciclo de vida** para todos los microservicios del ecosistema. Todos los integrantes del equipo deben adherirse estrictamente a estas especificaciones en sus respectivos repositorios (`pdf-extractor-service`, `pdf-document-service` y `pdf-api-service`).

---

## 1. Topología de Red y DNS Interno (`pdf-network`)

Todos los contenedores se integran a través de una red puente externa compartida de Docker denominada **`pdf-network`**.

```
                                  [ Clientes Externos / Benchmark k6 ]
                                                   │
                                                   ▼ (HTTP :80)
                                 ┌───────────────────────────────────┐
                                 │   Traefik v3.6 (Ingress Gateway)  │
                                 │   - Rate Limiting (HTTP 429)      │
                                 │   - Circuit Breaker (HTTP 503)    │
                                 │   - Retry on Shutdown (Conexión)  │
                                 │   - Dashboard: 127.0.0.1:8080     │
                                 └─────────────────┬─────────────────┘
                                                   │ red: 'pdf-network'
        ┌──────────────────────────────────────────┼──────────────────────────────────────────┐
        ▼                                          ▼                                          ▼
┌──────────────────────────────┐       ┌──────────────────────────────┐       ┌──────────────────────────────┐
│     extractor (Réplicas)     │       │     documents (Persistencia) │       │      api (Orquestador)       │
│  - Endpoint: POST /extract   │       │  - Endpoint: POST /documents │       │  - Endpoint: POST /process   │
│  - DNS: extractor:8000       │       │  - DNS: documents:8000       │       │  - DNS: api:8000             │
│  - Host: extractor.*.local   │       │  - Host: documents.*.local   │       │  - Host: api.*.local         │
└──────────────────────────────┘       └──────────────┬───────────────┘       └──────────────┬───────────────┘
                                                      │                                      │
                                                      ▼                                      ▼
                                             ┌─────────────────┐                    ┌─────────────────┐
                                             │  mongodb:27017  │                    │ dragonfly:6379  │
                                             │ (Base de Datos) │                    │ (Alias: redis)  │
                                             └─────────────────┘                    └─────────────────┘
```

### Tabla Oficial de Enrutamiento y Direcciones

| Servicio | Repositorio | DNS Interno en Docker | Puerto Interno | URL Interna (Inter-servicio) | Hostname Ingress Traefik (HTTP 80) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Traefik Dashboard** | `pdf-infrastructure` | `traefik` | `8080` | `http://traefik:8080` | `http://traefik.universidad.localhost` (o `127.0.0.1:8080`) |
| **Extractor Service** | `pdf-extractor-service` | `extractor` | `8000` | `http://extractor:8000` | `http://extractor.universidad.localhost` |
| **Document Service** | `pdf-document-service` | `documents` | `8000` | `http://documents:8000` | `http://documents.universidad.localhost` |
| **API Orchestrator** | `pdf-api-service` | `api` | `8000` | `http://api:8000` | `http://api.universidad.localhost` |
| **MongoDB 7** (Datos) | `pdf-document-service` | `mongodb` | `27017` | `mongodb://mongodb:27017` | *No expuesto públicamente* |
| **Dragonfly** (Caché) | `pdf-infrastructure` | `dragonfly` (alias `redis`) | `6379` | `redis://dragonfly:6379/0` (o `redis://redis:6379/0`) | *No expuesto públicamente* |

---

## 2. Regla de Oro: Prohibición de `localhost` entre Contenedores

> [!CAUTION]
> **ESTÁ ESTRICTAMENTE PROHIBIDO USAR `localhost` O `127.0.0.1` PARA COMUNICACIÓN ENTRE MICROSERVICIOS.**

### ¿Por qué falla `localhost`?
En Linux y Docker, cada contenedor tiene su propio **Network Namespace (`netns`)** completamente aislado. La dirección `127.0.0.1` (`localhost`) hace referencia única y exclusivamente al interior del propio contenedor.

Dentro de `pdf-network`, el DNS interno de Docker (`127.0.0.11`) resuelve automáticamente el nombre del servicio al IP balanceado de las instancias activas.

Por lo tanto, las variables de entorno inter-servicio deben configurarse como:
```env
EXTRACTOR_URL=http://extractor:8000
DOCUMENT_SERVICE_URL=http://documents:8000
MONGODB_URI=mongodb://mongodb:27017
REDIS_URL=redis://redis:6379/0
```

---

## 3. Patrones de Resiliencia: Auditoría, Implementación y Fronteras

### A. Frontera Externa (Ingress en Traefik v3.6)
Los clientes externos y las herramientas de prueba (k6) ingresan al sistema a través de Traefik v3.6. En esta frontera se implementan de forma coordinada los tres patrones:

```
[ Solicitud HTTP ] ──► [ 1. RateLimit ] ──► [ 2. CircuitBreaker ] ──► [ 3. Retry ] ──► [ Backend ]
                            │                        │                     │
                       HTTP 429                 HTTP 503              Reintento
                    (Límite Excedido)       (Circuito Abierto)      (Falla de Red)
```

#### Justificación del Orden de Ejecución de Middlewares:
1. **Rate Limiting primero (`rate-limit-extract` / `rate-limit-api`):** Protege la infraestructura descartando inmediatamente el tráfico abusivo o ráfagas que superan el `burst` con `HTTP 429 Too Many Requests`. Al estar al frente, evita que las peticiones abusivas abran indebidamente el Circuit Breaker o consuman reintentos del clúster.
2. **Circuit Breaker segundo (`circuit-breaker-extractor` / `circuit-breaker-api`):** Si el servicio backend presenta una tasa elevada de fallos de red o respuestas 5xx (`NetworkErrorRatio() > 0.30 || ResponseCodeRatio(500, 600, 0, 600) > 0.25`), Traefik interrumpe el paso de solicitudes respondiendo `HTTP 503 Service Unavailable`, permitiendo que el microservicio se estabilice sin seguir recibiendo carga.
3. **Retry tercero (`retry-on-shutdown`):** El middleware más cercano al backend. Si una réplica se apaga (durante despliegues continuos o escala) y se produce un corte transitorio a nivel socket, Traefik reenvía la petición a una réplica sana disponible.

> [!WARNING]
> **Precaución Crítica con Traefik Retry y peticiones POST (`/extract`):**  
> En Traefik v3.6, el middleware Retry reenvía la solicitud **únicamente cuando el backend no responde** (falla a nivel socket / conexión rechazada). Traefik **deja de reintentar si recibe una respuesta HTTP**, independientemente de si el código es 5xx o 4xx. Esto garantiza que Traefik no reintente peticiones de extracción si el microservicio ya respondió formalmente, evitando ejecuciones duplicadas no deseadas.

#### Exclusión Obligatoria de Sondas de Salud:
Para evitar que las comprobaciones de salud queden bloqueadas por el limitador de solicitudes:
- Se configuran routers dedicados de alta prioridad (`priority=100`) para `/health`, `/ready` y `/health/ready` **SIN** el middleware de RateLimit.
- El router de negocio general (`priority=10`) es el único que aplica la cadena de RateLimit, CircuitBreaker y Retry.

---

### B. Frontera Interna (Llamadas Inter-Servicio entre Contenedores)

> [!IMPORTANT]
> **ANÁLISIS ARQUITECTÓNICO CRÍTICO:**  
> Traefik **solo puede aplicar sus middlewares a las solicitudes que atraviesan sus routers**.  
> En la arquitectura de microservicios, el API Orchestrator (`api`) se comunica directamente con `http://extractor:8000` y con `http://documents:8000` a través de la red de Docker `pdf-network`. Estas llamadas **no pasan por Traefik**.  
> Por lo tanto, un Circuit Breaker o Retry configurado únicamente en Traefik **NO protege las comunicaciones internas**.

#### Especificación Técnica Requerida para `pdf-api-service`:
El orquestador de API debe implementar en su cliente HTTP (`app/clients/base.py`, `app/clients/extractor.py`, `app/clients/documents.py`):
1. **Retry con Backoff Exponencial y Jitter:** Reintentar únicamente ante fallos transitorios de red (`httpx.ConnectError`, `httpx.ConnectTimeout`) hasta un máximo de 2 o 3 intentos. **No** reintentar errores 4xx ni 500 definitivos.
2. **Circuit Breaker a nivel aplicación:** Si el Extractor o Documents fallan de forma consecutiva (ej. 5 fallos consecutivos o >50% de error en 10s), abrir el circuito por 10s y responder de inmediato `503 Service Unavailable` sin bloquear hilos.
3. **Timeouts Acotados:**
   - Extractor: Conexión 5s, Lectura 30s (`EXTRACTOR_TIMEOUT_SECONDS`).
   - Documents: Conexión 2s, Lectura 5s (`DOCUMENT_TIMEOUT_SECONDS`).

---

## 4. Reemplazo de Caché: Adopción de Dragonfly

Cumpliendo con la recomendación del profesor, se incorpora **Dragonfly** en sustitución de Redis:
- **Tecnología:** [Dragonfly](https://dragonflydb.io/) v1.26.0 (imagen `docker.dragonflydb.io/dragonflydb/dragonfly:v1.26.0`).
- **Compatibilidad:** Implementa el protocolo RESP2/RESP3. Es un reemplazo transparente (*drop-in replacement*) para Redis.
- **Alias de Red:** En `pdf-network` se asigna el alias `redis` al contenedor `dragonfly`, permitiendo que todos los microservicios mantengan su variable `REDIS_URL=redis://redis:6379/0` sin necesidad de modificar código.
- **Regla Estricta de la Cátedra (Perfil `cache`):** Dragonfly solo se inicia mediante el perfil `cache` (`docker compose --profile cache up -d dragonfly`). **Durante las pruebas de carga baseline con k6, Dragonfly debe permanecer apagado.**

---

## 5. Factor IX: Desechabilidad (Disposability — Twelve-Factor App)

1. **Arranque Rápido (Fast Startup):**
   - El contenedor pasa a estado `healthy` en menos de **5 segundos**.
   - Se valida midiendo directamente el estado del contenedor específico creado (`docker inspect`), evitando falsos positivos del balanceador.
2. **Apagado Elegante (Graceful Shutdown):**
   - Captura limpia de señales `SIGTERM` / `SIGINT` (gracias a `init: true` y forma `exec` en `CMD`).
   - Finalización ordenada con código de salida **`ExitCode = 0`** (nunca `137` en apagado normal).
   - Drenado de peticiones en vuelo: durante el apagado, las extracciones en curso se completan exitosamente (`HTTP 200 OK` con JSON íntegro).
   - Ventana de drenado configurada: `stop_grace_period: 35s` para `extractor` y `30s` para `documents` y `api`.
3. **Resiliencia ante Muerte Súbita (Crash Resilience):**
   - Si una instancia sufre una caída catastrófica (`SIGKILL`, código `137`), Traefik la retira automáticamente en la siguiente sonda y reenvía las solicitudes a las réplicas sobrevivientes con **0% de error**.

---

## 6. Endpoints Mínimos Requeridos y Contrato de Datos

### 1. Extractor Service (`extractor`):
- `POST /extract`: Recibe PDF binario directo (`Content-Type: application/pdf`). Retorna `200 OK`:
  ```json
  {
    "content": "Texto extraído en Markdown...",
    "page_count": 279
  }
  ```
- `GET /health`: Liveness del contenedor (retorna `200 OK {"status": "ok", "service": "extractor"}`).
- `GET /health/ready`: Readiness probe (`200 OK` si listo, o `status: degraded` si no hay caché en baseline).
- `GET /metrics`: Métricas Prometheus (contador de requests, saturación de workers).

### 2. Document Service (`documents`):
- `POST /documents`: Persiste documento en MongoDB. Retorna `201 Created` (o `200 OK` si el checksum ya existía).
- `GET /documents/by-checksum/{checksum}`: Búsqueda por SHA-256.
- `GET /documents/{id}`: Búsqueda por ObjectId.
- `GET /health`: Liveness del proceso.
- `GET /health/ready`: Readiness probe (`200 OK` si MongoDB responde; `503` si Mongo no está disponible).

### 3. API Orchestrator (`api`):
- `POST /process`: Orquestador principal. Acepta binario directo o multipart.
  Retorna `ProcessResponse`:
  ```json
  {
    "document_id": "6724fa...",
    "checksum": "728c8a...",
    "content": "...",
    "page_count": 279,
    "source": "extracted"  // O "existing" en deduplicación
  }
  ```
- `GET /health`: Liveness de la API.
- `GET /ready`: Readiness probe que evalúa en paralelo la disponibilidad de Extractor y Documents.
