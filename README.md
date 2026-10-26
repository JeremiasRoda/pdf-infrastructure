# PDF Infrastructure

Infraestructura compartida para la arquitectura de microservicios de procesamiento de PDFs (`pdf-extractext`).  
**Cátedra:** Desarrollo de Software — UTN Facultad Regional San Rafael.

Este repositorio centraliza y provee:
1. **Red externa de Docker (`pdf-network`)**: Puente de comunicación compartido entre todos los microservicios y el reverse proxy.
2. **Reverse Proxy y Load Balancer (Traefik v3)**: Con Docker Provider para enrutamiento dinámico basado en etiquetas (`labels`) y healthchecks activos de balanceador.
3. **Dashboard de Monitoreo y Auditoría**: Expuesto en `:8080` para auditoría en tiempo real de routers, middlewares y réplicas vivas.
4. **Convención de Dominios locales**: Espacio de nombres `*.universidad.localhost`.
5. **Caché Redis (Perfil condicional `cache`)**: Para la etapa de optimización post-baseline.
6. **Compose de Integración Completa**: Orquestación local de todos los microservicios (`extractor`, `documents`, `mongodb`, `api`).
7. **Pruebas Automatizadas de Resiliencia y Alta Disponibilidad**: Demostración de tolerancia a fallos ante la cátedra.
8. **Suite de Benchmarks de Rendimiento (k6 Spike y Vegeta)**: Pruebas de carga comparativas (1 réplica Baseline vs 5 réplicas escaladas) y monitor de recursos en vivo.
9. **Factor IX de Twelve-Factor App (Desechabilidad)**: Apagado elegante (`SIGTERM`), drenado de peticiones, `stop_grace_period` y middleware de reintentos en Traefik.

---

## Convención de Hostnames y Enrutamiento

Todos los servicios responden en el puerto estándar `80` (HTTP) a través de Traefik resolviendo automáticamente los siguientes dominios locales:

| Componente | Dominio | Puerto Proxy / Acceso Directo | DNS Interno Docker |
| :--- | :--- | :--- | :--- |
| **Traefik Dashboard** | `http://traefik.universidad.localhost` | `http://localhost:8080` (directo) | `traefik:8080` |
| **API Orchestrator** | `http://api.universidad.localhost` | `http://api.universidad.localhost:80` | `api:8000` |
| **Document Service** | `http://documents.universidad.localhost` | `http://documents.universidad.localhost:80` | `documents:8000` |
| **Extractor Service** | `http://extractor.universidad.localhost` | `http://extractor.universidad.localhost:80` | `extractor:8000` |
| **MongoDB** | *No expuesto públicamente* | Puerto interno `27017` | `mongodb:27017` |
| **Redis** (Caché) | *No expuesto públicamente* | Puerto interno `6379` | `redis:6379` |

> [!NOTE]
> Cualquier subdominio de `*.localhost` resuelve automáticamente a `127.0.0.1` de forma nativa en la mayoría de los sistemas operativos modernos sin necesidad de editar `/etc/hosts`.

---

## Contrato Oficial de Infraestructura (`CONTRACTS.md`)

Para las especificaciones técnicas completas requeridas por cada integrante del equipo (puertos internos, prohibición de `localhost`, snippets exactos de Compose con labels de Traefik v3 y límites de recursos):
**Consulte el archivo [`CONTRACTS.md`](CONTRACTS.md)**.

---

## Puesta en Marcha Inicial

### 1. Variables de Entorno

Copiar el archivo de plantilla `.env.example` a `.env`:

```bash
# Linux / macOS
cp .env.example .env

# Windows PowerShell
Copy-Item .env.example .env
```

### 2. Inicializar la Red Externa (`pdf-network`)

Es indispensable que la red externa `pdf-network` exista antes de desplegar cualquiera de los stacks de Docker:

- **En Linux / macOS / Git Bash:**
  ```bash
  chmod +x init-network.sh
  ./init-network.sh
  ```

- **En Windows (CMD / PowerShell):**
  ```cmd
  init-network.bat
  ```

- **O manualmente vía Docker CLI:**
  ```bash
  docker network create --driver bridge --attachable pdf-network
  ```

### 3. Levantar Traefik Base

```bash
docker compose up -d
```

Verificar su estado:
```bash
docker compose ps
docker compose logs -f traefik
```

---

## Integración del Sistema Completo

El archivo `docker-compose.integration.yml` asume que los repositorios de los microservicios se encuentran clonados en carpetas hermanas:

```
workspace/
├── pdf-infrastructure/       <-- este repositorio
├── pdf-extractor-service/
├── pdf-document-service/
└── pdf-api-service/
```

Para levantar todos los microservicios (`extractor`, `documents`, `mongodb` y `api`):

```bash
docker compose -f docker-compose.integration.yml up -d --build
```

---

## Escalado a 5 Réplicas del Extractor

Dado que el microservicio `extractor` es stateless y CPU-intensivo, la cátedra requiere probar el escalado horizontal:

```bash
docker compose -f docker-compose.integration.yml up -d --scale extractor=5
```

Traefik detectará automáticamente las 5 instancias a través del socket de Docker y distribuirá la carga mediante algoritmo Round-Robin.

Para verificar que las 5 réplicas están registradas en Traefik:
```bash
# Vía API REST de Traefik
curl -s http://localhost:8080/api/http/services | jq

# Vía Docker
docker compose -f docker-compose.integration.yml ps extractor
```

---

## Activación de Caché con Redis (Post-Baseline)

> [!WARNING]
> **Regla de Cátedra:** Durante las pruebas de carga iniciales (Baseline) con k6 y Vegeta, Redis **NO debe estar activo** para medir el rendimiento base del pipeline.

Una vez finalizada la medición baseline, se activa el servicio Redis utilizando el perfil condicional `cache`:

### Opción A: Levantar Redis en el compose principal
```bash
docker compose --profile cache up -d redis
```

### Opción B: Levantar Redis en el compose de integración
```bash
docker compose -f docker-compose.integration.yml --profile cache up -d redis
```

Los microservicios consumirán la caché mediante `REDIS_URL=redis://redis:6379/0`.

---

## Ejecución de Prueba de Resiliencia y Tolerancia a Fallos

Se incluye una suite de prueba automatizada para demostrar ante la cátedra la alta disponibilidad del sistema. El script:
1. Verifica que Traefik esté activo y detecta las réplicas del `extractor`.
2. Detiene intencionalmente una réplica activa (`chaos test`).
3. Lanza una ráfaga de 40 peticiones a `http://extractor.universidad.localhost/health`.
4. Verifica que se mantenga el **0% de error** (100% 200 OK) gracias al healthcheck pasivo y activo del load balancer de Traefik.

### Ejecución en Linux / macOS:
```bash
chmod +x scripts/test-resilience.sh
./scripts/test-resilience.sh
```

### Ejecución en Windows PowerShell:
```powershell
.\scripts\test-resilience.ps1
```

---

## Factor IX: Desechabilidad y Apagado Elegante (Issue #8)

El ecosistema implementa de forma transversal el **Factor IX de Twelve-Factor App (Desechabilidad)**:
- **Arranque Rápido (Fast Startup):** Contenedores livianos que alcanzan estado `healthy` en menos de 5 segundos.
- **Manejo de Señales Unix (`SIGTERM`):** Contenedores configurados con `init: true` (`tini` como PID 1) para propagar señales de apagado sin procesos zombi.
- **Ventana de Drenado (`stop_grace_period`):** Configurado en `30s` - `35s` en Compose para permitir finalizar la extracción y guardado de PDFs en vuelo.
- **Middleware de Reintentos en Traefik (`retry-on-shutdown`):** Si una réplica se apaga mientras una petición está en tránsito, Traefik la reenvía automáticamente a una réplica viva garantizando 0% de errores.
- **Apagado Limpio (Exit Code 0):** Los procesos cierran ordenadamente conexiones de MongoDB, Redis y HTTP saliendo con código `0` (nunca `137`).

### Ejecución de Prueba de Desechabilidad:

- **En Linux / macOS:**
  ```bash
  chmod +x scripts/test-disposability.sh
  ./scripts/test-disposability.sh
  ```

- **En Windows PowerShell:**
  ```powershell
  .\scripts\test-disposability.ps1
  ```

---

## Pruebas de Carga y Rendimiento (Issue #5: k6 y Vegeta)

El repositorio incluye la suite oficial para la evaluación de desempeño y escalabilidad bajo el protocolo de la cátedra:

- **k6 Spike Test (100 VUs)**: Evalúa la absorción de tráfico concurrente abrupto (10s subida a 100 VUs, 20s meseta sostenida, 10s descenso).
- **Vegeta Carga Fija**: Disparo constante de 50 peticiones/segundo durante 30s (1.500 solicitudes) con rotación cíclica de 4 PDFs.
- **Monitor de Recursos en Vivo**: Captura continua de CPU%, RAM% e I/O de red de las réplicas del extractor y Traefik.

### Flujo Rápido de Ejecución:

```bash
# 1. Importar o generar dataset de PDFs de prueba
# Linux / macOS:
./scripts/copy-stress-pdfs.sh
# Windows PowerShell:
.\scripts\copy-stress-pdfs.ps1

# 2. Monitorear recursos en una terminal secundaria
# Linux / macOS:
./scripts/monitor-stats.sh
# Windows PowerShell:
.\scripts\monitor-stats.ps1

# 3. Ejecutar k6 Spike Test (100 VUs)
k6 run load-tests/k6-spike.js

# 4. Ejecutar Vegeta Carga Fija (50 req/s por 30s)
# Linux / macOS:
./load-tests/run-vegeta.sh
# Windows PowerShell:
.\load-tests\run-vegeta.ps1
```

Para la metodología detallada, ejecución vía Docker y la plantilla de tabla comparativa para el informe final, consulte la **[Guía Completa de Pruebas de Carga](load-tests/README.md)**.

---

## Auditoría e Inspección de Traefik

### Vía Dashboard Web:
- Acceder a: [http://localhost:8080](http://localhost:8080) o [http://traefik.universidad.localhost](http://traefik.universidad.localhost)

### Vía API REST:
```bash
# Consultar routers HTTP registrados
curl -s http://localhost:8080/api/http/routers | jq

# Consultar servicios HTTP y estado de balanceo
curl -s http://localhost:8080/api/http/services | jq

# Ping de salud de Traefik
curl -s http://localhost:8080/ping
```
