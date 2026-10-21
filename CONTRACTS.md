# Contrato de Infraestructura y Enrutamiento (`CONTRACTS.md`)
**Proyecto:** `pdf-extractext`  
**Cátedra:** Desarrollo de Software — UTN Facultad Regional San Rafael  
**Repositorio Central:** `pdf-infrastructure`  

Este documento define el **contrato oficial de infraestructura, redes y enrutamiento** para todos los microservicios del ecosistema. Todos los integrantes del equipo deben adherirse estrictamente a estas especificaciones en sus respectivos repositorios (`pdf-extractor-service`, `pdf-document-service` y `pdf-api-service`).

---

## 1. Topología de Red y DNS Interno (`pdf-network`)

Todos los contenedores se integran a través de una red puente externa compartida de Docker denominada **`pdf-network`**.

```
                           [ Cliente / Navegador / k6 / Vegeta ]
                                            │
                                            ▼
                          ┌───────────────────────────────────┐
                          │   Traefik v3 (Reverse Proxy & LB) │
                          │       Puerto 80 / 8080 (Admin)    │
                          └─────────────────┬─────────────────┘
                                            │ red: 'pdf-network'
       ┌────────────────────────────────────┼────────────────────────────────────┐
       ▼                                    ▼                                    ▼
┌──────────────┐                 ┌────────────────────┐               ┌────────────────────┐
│  extractor   │                 │     documents      │               │        api         │
│ (Escalable)  │                 │  (Dueño de MongoDB)│               │   (Orquestador)    │
│  Puerto 8000 │                 │    Puerto 8000     │               │    Puerto 8000     │
└──────────────┘                 └──────────┬─────────┘               └──────────┬─────────┘
                                            │                                    │
                                            ▼                                    ▼
                                   ┌─────────────────┐                  ┌─────────────────┐
                                   │  mongodb:27017  │                  │  redis:6379     │
                                   │ (Almacenamiento)│                  │(Caché Post-Base)│
                                   └─────────────────┘                  └─────────────────┘
```

### Tabla Oficial de Enrutamiento y Direcciones

| Servicio | Repositorio | DNS Interno en Docker | Puerto Interno | URL Interna (Inter-servicio) | Hostname Público Traefik (HTTP 80) |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Traefik Dashboard** | `pdf-infrastructure` | `traefik` | `8080` | `http://traefik:8080` | `http://traefik.universidad.localhost` (o `http://localhost:8080`) |
| **Extractor Service** | `pdf-extractor-service` | `extractor` | `8000` | `http://extractor:8000` | `http://extractor.universidad.localhost` |
| **Document Service** | `pdf-document-service` | `documents` | `8000` | `http://documents:8000` | `http://documents.universidad.localhost` |
| **API Orchestrator** | `pdf-api-service` | `api` | `8000` | `http://api:8000` | `http://api.universidad.localhost` |
| **MongoDB** (Datos) | `pdf-document-service` | `mongodb` | `27017` | `mongodb://mongodb:27017` | *No expuesto públicamente* |
| **Redis** (Caché) | `pdf-infrastructure` | `redis` | `6379` | `redis://redis:6379/0` | *No expuesto públicamente* |

---

## 2. Regla de Oro: Prohibición de `localhost` entre Contenedores

> [!CAUTION]
> **ESTÁ ESTRICTAMENTE PROHIBIDO USAR `localhost` O `127.0.0.1` PARA COMUNICACIÓN ENTRE MICROSERVICIOS.**

### ¿Por qué falla `localhost`?
En Linux y Docker, cada contenedor tiene su propio **Network Namespace (`netns`)** completamente aislado. La dirección de loopback `127.0.0.1` (`localhost`) hace referencia **única y exclusivamente al interior del propio contenedor**:
- Si el servicio `api` intenta conectar a `http://localhost:8000/extract`, buscará el puerto 8000 dentro del contenedor de `api`, donde no existe ningún extractor, generando un error `ECONNREFUSED`.
- Si `documents` intenta conectar a `mongodb://localhost:27017`, buscará el proceso de Mongo dentro de su propio contenedor en lugar del contenedor `mongodb`.

### Solución Arquitectónica
Dentro de la red `pdf-network`, el daemon de Docker ejecuta un servidor DNS interno (`127.0.0.11`) que resuelve automáticamente el nombre del servicio al IP virtual o balanceado de las instancias activas.

Por lo tanto, la configuración en archivos `.env` y variables de entorno debe ser:
```env
# Comunicación dentro de 'pdf-network'
EXTRACTOR_URL=http://extractor:8000
DOCUMENT_SERVICE_URL=http://documents:8000
MONGODB_URI=mongodb://mongodb:27017/pdf_documents
REDIS_URL=redis://redis:6379/0
```

---

## 3. Snippets de `docker-compose.yml` para cada Repositorio

A continuación se detallan los fragmentos de configuración listos para copiar y pegar en cada repositorio del equipo.

### A. Repositorio `pdf-extractor-service`

> [!IMPORTANT]
> **REGLA CRÍTICA:** **NO** definir `container_name`. Si se define `container_name`, Docker impedirá escalar el servicio con `--scale extractor=5` por colisión de nombres.
> **NO** publicar puertos en el host (ej. `ports: "8000:8000"`), ya que colisionarían al haber más de una réplica. Traefik se encarga de enrutar el tráfico hacia los puertos internos.

```yaml
version: '3.8'

services:
  extractor:
    build:
      context: .
      dockerfile: Dockerfile
    # Sin container_name para permitir escalabilidad horizontal
    restart: unless-stopped
    networks:
      - pdf-network
    environment:
      - PORT=8000
      - PYTHONUNBUFFERED=1
    # Límites de hardware exigidos por la cátedra
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
    # Healthcheck nativo de Docker
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8000/health || curl -sf http://127.0.0.1:8000/health || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    # Configuración de Traefik v3
    labels:
      - "traefik.enable=true"
      # Enrutador HTTP
      - "traefik.http.routers.extractor.rule=Host(`extractor.universidad.localhost`)"
      - "traefik.http.routers.extractor.entrypoints=web"
      - "traefik.http.routers.extractor.service=extractor"
      # Balanceador de carga y puerto interno de la app
      - "traefik.http.services.extractor.loadbalancer.server.port=8000"
      # Healthcheck de Traefik: descarta automáticamente réplicas que no respondan
      - "traefik.http.services.extractor.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.extractor.loadbalancer.healthcheck.interval=3s"
      - "traefik.http.services.extractor.loadbalancer.healthcheck.timeout=1s"

networks:
  pdf-network:
    external: true
```

---

### B. Repositorio `pdf-document-service`

El microservicio de documentos es el **único dueño de la persistencia en MongoDB**. Ningún otro microservicio debe conectarse a Mongo directamente.

```yaml
version: '3.8'

services:
  mongodb:
    image: mongo:7.0
    restart: unless-stopped
    networks:
      - pdf-network
    volumes:
      - mongodb_data:/data/db
    healthcheck:
      test: ["CMD-SHELL", "mongosh --eval 'db.runCommand({ ping: 1 })' || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G

  documents:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    networks:
      - pdf-network
    environment:
      - PORT=8000
      - MONGODB_URI=mongodb://mongodb:27017/pdf_documents
    depends_on:
      mongodb:
        condition: service_healthy
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8000/health || curl -sf http://127.0.0.1:8000/health || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.documents.rule=Host(`documents.universidad.localhost`)"
      - "traefik.http.routers.documents.entrypoints=web"
      - "traefik.http.routers.documents.service=documents"
      - "traefik.http.services.documents.loadbalancer.server.port=8000"
      - "traefik.http.services.documents.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.documents.loadbalancer.healthcheck.interval=3s"
      - "traefik.http.services.documents.loadbalancer.healthcheck.timeout=1s"

volumes:
  mongodb_data:

networks:
  pdf-network:
    external: true
```

---

### C. Repositorio `pdf-api-service` (API Orchestrator)

El API Orchestrator coordina el flujo entre el cliente, el extractor y el gestor de documentos.

```yaml
version: '3.8'

services:
  api:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    networks:
      - pdf-network
    environment:
      - PORT=8000
      - EXTRACTOR_URL=http://extractor:8000
      - DOCUMENT_SERVICE_URL=http://documents:8000
      # Redis se activa condicionalmente luego de la prueba de carga baseline
      - REDIS_URL=redis://redis:6379/0
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8000/health || curl -sf http://127.0.0.1:8000/health || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(`api.universidad.localhost`)"
      - "traefik.http.routers.api.entrypoints=web"
      - "traefik.http.routers.api.service=api"
      - "traefik.http.services.api.loadbalancer.server.port=8000"
      - "traefik.http.services.api.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.api.loadbalancer.healthcheck.interval=3s"
      - "traefik.http.services.api.loadbalancer.healthcheck.timeout=1s"

networks:
  pdf-network:
    external: true
```

---

## 4. Convención de Endpoints Mínimos Requeridos

Para que el orquestador y los healthchecks de Traefik y Docker funcionen de manera uniforme:

1. **Health Check (`GET /health`):**
   - Todos los servicios deben implementar `GET /health` respondiendo `200 OK` con formato JSON:
     ```json
     {
       "status": "ok",
       "service": "extractor"  // o "documents", o "api"
     }
     ```
2. **Extractor Service:**
   - `POST /extract`: recibe un archivo binario o multipart PDF y retorna:
     ```json
     {
       "content": "Texto extraído...",
       "page_count": 5
     }
     ```
3. **Document Service:**
   - `POST /documents`: persiste metadatos y texto extraído en MongoDB.
   - `GET /documents/{id}`: recupera el documento almacenado.

---

## 5. Regla de Pruebas de Carga (Baseline vs. Post-Baseline con Redis)

1. **Fase 1 (Pruebas Baseline k6 y Vegeta):**
   - Redis **debe permanecer apagado**.
   - Se mide la capacidad cruda del pipeline de extracción y almacenamiento.
2. **Fase 2 (Optimización con Caché Redis):**
   - Se levanta Redis en `pdf-infrastructure` mediante `docker compose --profile cache up -d redis`.
   - El orquestador (`api`) o los servicios consultan `REDIS_URL` para almacenar en caché resultados frecuentes por hash de PDF.
