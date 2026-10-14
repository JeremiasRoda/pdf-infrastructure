# PDF Infrastructure

Infraestructura compartida para la arquitectura de microservicios de procesamiento de PDFs (Cátedra de Desarrollo de Software - UTN FR San Rafael).

Este repositorio centraliza:
1. **Red externa de Docker (`pdf-network`)**: Permite la intercomunicación entre los diferentes repositorios/microservicios y el reverse proxy.
2. **Reverse Proxy y Load Balancer (Traefik v3)**: Con Docker Provider para enrutamiento dinámico basado en etiquetas (`labels`).
3. **Dashboard de Monitoreo y Auditoría**: Expuesto para inspección visual de routers, middlewares y servicios en tiempo de desarrollo.
4. **Convención de Dominios locales**: Espacio de nombres `*.universidad.localhost`.

---

## Convención de Hostnames y Enrutamiento

Todos los servicios responden en el puerto estándar `80` (HTTP) a través del reverse proxy Traefik resolviendo automáticamente los siguientes dominios locales:

| Componente | Dominio | Puerto Proxy / Acceso Directo |
| :--- | :--- | :--- |
| **Traefik Dashboard** | `http://traefik.universidad.localhost` | `http://localhost:8080` (directo) |
| **API Orchestrator** | `http://api.universidad.localhost` | `http://api.universidad.localhost:80` |
| **Document Service** | `http://documents.universidad.localhost` | `http://documents.universidad.localhost:80` |
| **Extractor Service** | `http://extractor.universidad.localhost` | `http://extractor.universidad.localhost:80` |

> **Nota:** La mayoría de los navegadores y sistemas operativos resuelven cualquier subdominio de `*.localhost` hacia la dirección `127.0.0.1` de manera nativa sin requerir modificar el archivo `hosts`.

---

## Puesta en Marcha

### 1. Variables de Entorno

Copiar el archivo de plantilla `.env.example` a `.env`:

```bash
cp .env.example .env
```

En Windows (PowerShell / CMD):
```powershell
Copy-Item .env.example .env
```

### 2. Inicializar la Red Externa (`pdf-network`)

Es indispensable que la red externa `pdf-network` exista antes de desplegar cualquiera de los stacks de Docker. Se proporcionan scripts reproducibles e idempotentes:

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

### 3. Levantar Traefik

```bash
docker compose up -d
```

Para verificar que Traefik se encuentra corriendo correctamente:
```bash
docker compose ps
docker compose logs -f traefik
```

---

## Auditoría e Inspección de Traefik

Para auditar y monitorear el estado de los routers, servicios y middlewares activos:

### Vía Dashboard Web:
- Acceder a: [http://localhost:8080](http://localhost:8080) o [http://traefik.universidad.localhost](http://traefik.universidad.localhost)

### Vía API REST de Traefik:
```bash
# Consultar routers HTTP registrados
curl -s http://localhost:8080/api/http/routers | jq

# Consultar servicios HTTP y estado de réplicas
curl -s http://localhost:8080/api/http/services | jq

# Verificar el estado de salud de Traefik
curl -s http://localhost:8080/ping
```

---

## Guía de Integración para Microservicios

Para conectar cualquier microservicio (`extractor`, `api-orchestrator`, `document-service`) a esta infraestructura, deben configurarse los siguientes parámetros en sus respectivos archivos `docker-compose.yml`:

```yaml
services:
  mi-servicio:
    image: mi-servicio:latest
    # IMPORTANTE: NO fijar 'container_name' si el servicio se escala con --scale
    networks:
      - pdf-network
    labels:
      - "traefik.enable=true"
      # Configurar la regla de host según la convención
      - "traefik.http.routers.mi-servicio.rule=Host(`servicio.universidad.localhost`)"
      - "traefik.http.routers.mi-servicio.entrypoints=web"
      # Puerto interno en el que escucha la aplicación dentro del contenedor
      - "traefik.http.services.mi-servicio.loadbalancer.server.port=8000"

networks:
  pdf-network:
    external: true
```
