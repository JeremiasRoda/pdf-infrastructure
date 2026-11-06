# PDF Infrastructure

Infraestructura compartida para la arquitectura de microservicios de procesamiento de PDFs (`pdf-extractext`).  
**Cátedra:** Desarrollo de Software — UTN Facultad Regional San Rafael.

Este repositorio centraliza y provee:
1. **Red Externa de Docker (`pdf-network`)**: Puente de comunicación compartido entre todos los microservicios y el reverse proxy.
2. **Reverse Proxy, Ingress y Balanceador de Carga (Traefik v3.6)**: Con Docker Provider para descubrimiento dinámico basado en etiquetas (`labels`) y healthchecks activos de balanceador.
3. **Seguridad y Dashboard de Auditoría**: Expuesto de forma segura en `127.0.0.1:8080` para auditoría en tiempo real de routers, middlewares y réplicas vivas.
4. **Patrones de Resiliencia en Ingress**: Implementación y coordinación de **Rate Limiting (HTTP 429)**, **Circuit Breaker (HTTP 503)** y **Retry (Reintentos)**.
5. **Caché Dragonfly (Perfil condicional `cache`)**: Reemplazo multi-threaded de alto rendimiento compatible con Redis (RESP) para optimización post-baseline.
6. **Compose de Integración Completa**: Orquestación local de todos los microservicios (`extractor`, `documents`, `mongodb`, `api`).
7. **Factor IX de Twelve-Factor App (Desechabilidad)**: Inicio rápido (< 5s), apagado elegante (`SIGTERM`), drenado de peticiones en vuelo, y recuperación ante muerte súbita.
8. **Suite Oficial de Benchmarks (k6 Spike Test)**: Prueba de carga con 100 VUs sobre el dataset oficial de 279 páginas.

---

## Convención de Hostnames y Enrutamiento

Todos los servicios responden en el puerto estándar `80` (HTTP) a través de Traefik resolviendo automáticamente los siguientes dominios locales:

| Componente | Dominio Local Traefik | Acceso Directo / Admin | DNS Interno Docker |
| :--- | :--- | :--- | :--- |
| **Traefik Dashboard** | `http://traefik.universidad.localhost` | `http://127.0.0.1:8080` (restringido) | `traefik:8080` |
| **API Orchestrator** | `http://api.universidad.localhost` | Vía Ingress HTTP 80 | `api:8000` |
| **Document Service** | `http://documents.universidad.localhost` | Vía Ingress HTTP 80 | `documents:8000` |
| **Extractor Service** | `http://extractor.universidad.localhost` | Vía Ingress HTTP 80 | `extractor:8000` |
| **MongoDB 7** | *No expuesto públicamente* | Puerto interno `27017` | `mongodb:27017` |
| **Dragonfly** (Caché) | *No expuesto públicamente* | Puerto interno `6379` | `dragonfly:6379` (alias `redis`) |

> [!NOTE]
> Cualquier subdominio de `*.localhost` resuelve automáticamente a `127.0.0.1` de forma nativa en la mayoría de los sistemas operativos modernos sin necesidad de modificar `/etc/hosts`.

---

## 🛡 Patrones de Resiliencia en Traefik v3.6

Los tres patrones exigidos por la cátedra están configurados y activos en Traefik para proteger los servicios de sobrecarga y fallos en cascada:

```
[ Petición HTTP ] ──► [ 1. Rate Limiting ] ──► [ 2. Circuit Breaker ] ──► [ 3. Retry ] ──► [ Microservicio ]
```

### 1. Orden de Ejecución y Justificación Técnica
- **1. Rate Limiting (`rate-limit-extract` / `rate-limit-api`):** Se ejecuta en primer lugar. Descarta ráfagas abusivas con `HTTP 429 Too Many Requests` antes de que consuman recursos del clúster o disparen el Circuit Breaker innecesariamente.
- **2. Circuit Breaker (`circuit-breaker-extractor` / `circuit-breaker-api`):** Evalúa la tasa de errores del backend (`NetworkErrorRatio() > 0.30 || ResponseCodeRatio(500, 600, 0, 600) > 0.25`). Si el microservicio supera el umbral de fallos, abre el circuito e interrumpe el tráfico devolviendo de inmediato `HTTP 503 Service Unavailable`, permitiendo la recuperación del servicio.
- **3. Retry (`retry-on-shutdown`):** El middleware más interno. Reintenta fallos transitorios de red/socket hasta 3 veces cuando una réplica se detiene o reinicia.
  > [!IMPORTANT]
  > Traefik Retry reenvía la solicitud **únicamente si el socket no responde** (falla transitoria). Si el microservicio responde un código HTTP (incluso 5xx o 4xx), Traefik **no** reintenta, garantizando que no existan ejecuciones duplicadas de extracciones POST.

### 2. Exclusión de Sondas de Salud
Para garantizar que los health checks de Docker y de monitoreo no se bloqueen por Rate Limiting, se definen routers de alta prioridad (`priority=100`) para `/health`, `/ready` y `/health/ready` **sin** RateLimit. El limitador aplica exclusivamente a las rutas de procesamiento de negocio (`priority=10`).

### 3. Delimitación de Responsabilidad (Ingress vs. Llamadas Inter-Servicio)
Traefik protege las solicitudes que ingresan por sus routers públicos. Cuando el orquestador `api` llama directamente a `http://extractor:8000` o `http://documents:8000` a través de la red `pdf-network`, esas llamadas **no pasan por Traefik**. Por ello, el cliente HTTP de `pdf-api-service` debe implementar sus propios timeouts, reintentos con backoff exponencial y circuit breaker a nivel de código (especificado en `CONTRACTS.md`).

---

## 🛑 Factor IX: Desechabilidad y Apagado Elegante

El ecosistema cumple rigurosamente con el **Factor IX de Twelve-Factor App**:
- **Arranque Rápido (Fast Startup):** Cada contenedor nuevo alcanza estado `healthy` en menos de **5 segundos**, medido de forma aislada en la instancia creada.
- **Manejo Limpio de Señales Unix (`SIGTERM`):** Contenedores configurados con `init: true` (`tini` como PID 1) para propagar señales sin procesos zombi.
- **Drenado de Solicitudes en Vuelo:** Ventanas de `stop_grace_period: 35s` (extractor) y `30s` (api y documents) permiten finalizar extracciones en curso durante un despliegue.
- **Código de Salida Limpio:** Los procesos capturan `SIGTERM` y finalizan con **`ExitCode = 0`** (nunca `137` en apagado normal).
- **Tolerancia a Muerte Súbita (`SIGKILL`):** Si una instancia se destruye abruptamente, Traefik detecta la caída y reenvía las peticiones a las réplicas sobrevivientes con 0% de errores percibidos.

---

## ⚡ Caché Dragonfly (Drop-in Replacement de Redis)

Siguiendo la recomendación del profesor, se reemplaza Redis por **Dragonfly v1.26.0**:
- Multi-threaded, con altísimo throughput y mínimo consumo de memoria.
- Utiliza la imagen oficial `docker.dragonflydb.io/dragonflydb/dragonfly:v1.26.0`.
- Configurado con alias de red `redis` en `pdf-network` para que los microservicios mantengan compatibilidad sin tocar código.
- **Regla Estricta:** Durante las pruebas de carga baseline con k6, Dragonfly permanece apagado. Se inicia únicamente en la fase de optimización con:
  ```bash
  docker compose --profile cache up -d dragonfly
  ```

---

## Puesta en Marcha Inicial

### 1. Variables de Entorno
Copiar la plantilla `.env.example` a `.env`:
```bash
cp .env.example .env     # Linux / macOS
copy .env.example .env   # Windows CMD
Copy-Item .env.example .env # Windows PowerShell
```

### 2. Inicializar la Red Externa (`pdf-network`)
```bash
# Linux / macOS
chmod +x init-network.sh && ./init-network.sh

# Windows
.\init-network.bat
```

### 3. Iniciar Traefik Ingress Base
```bash
docker compose up -d
```
Verifique el dashboard en `http://127.0.0.1:8080` (restringido a loopback por seguridad).

---

## Integración del Ecosistema Completo

Para levantar todos los microservicios (`extractor`, `documents`, `mongodb` y `api`):

```bash
docker compose -f docker-compose.integration.yml up -d --build
```

Para escalar el extractor a 5 réplicas:
```bash
docker compose -f docker-compose.integration.yml up -d --scale extractor=5
```

---

## Scripts de Validación y Pruebas

Todos los scripts cuentan con versiones equivalentes para **Linux/macOS (Bash)** y **Windows (PowerShell)**:

### 1. Validación de Patrones de Resiliencia (Rate Limit, Circuit Breaker, Retry)
Verifica que las ráfagas reciban HTTP 429, que `/health` permanezca accesible y que los middlewares de Traefik estén activos:
```bash
# Linux / macOS
chmod +x scripts/test-resilience-patterns.sh
./scripts/test-resilience-patterns.sh

# Windows PowerShell
.\scripts\test-resilience-patterns.ps1
```

### 2. Validación de Factor IX (Desechabilidad)
Mide el cold start (< 5s), lanza una extracción real de PDF mientras detiene una réplica y valida `ExitCode = 0`:
```bash
# Linux / macOS
chmod +x scripts/test-disposability.sh
./scripts/test-disposability.sh

# Para incluir prueba de muerte súbita (SIGKILL / 137):
./scripts/test-disposability.sh --allow-destructive

# Windows PowerShell
.\scripts\test-disposability.ps1
.\scripts\test-disposability.ps1 -AllowDestructive
```

### 3. Demostración de Tolerancia a Fallos y Alta Disponibilidad
Envía extracciones continuas de PDF mientras detiene una réplica activa, verificando 0% de errores:
```bash
# Linux / macOS
chmod +x scripts/test-resilience.sh
./scripts/test-resilience.sh

# Windows PowerShell
.\scripts\test-resilience.ps1
```

### 4. Benchmark de Carga Spike con k6 (100 VUs)
Ejecuta la prueba de concurrencia oficial sobre el endpoint `/extract`:
```bash
# Con k6 instalado localmente:
k6 run load-tests/k6-spike.js

# Vía Docker (sin instalar k6):
docker run --rm -i --network pdf-network \
  -v "${PWD}/load-tests:/load-tests" \
  -e TARGET_URL="http://extractor:8000/extract" \
  grafana/k6:latest run /load-tests/k6-spike.js
```
*Consulte [`load-tests/README.md`](load-tests/README.md) para detalles sobre el fixture de 279 páginas y la interacción con Rate Limiting.*

---

## Seguridad y Consideraciones de Docker Socket
- **Restricción de Interfaces:** El dashboard de Traefik (`:8080`) está explícitamente vinculado a `127.0.0.1` en `docker-compose.yml`, impidiendo acceso externo no autorizado.
- **Docker Socket `:ro`:** El socket de Docker se monta en modo de solo lectura (`/var/run/docker.sock:ro`) y Traefik opera con `exposedByDefault: false` para mitigar riesgos de seguridad.
