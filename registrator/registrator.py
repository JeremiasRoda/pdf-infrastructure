#!/usr/bin/env python3
"""
Consul Registrator Liviano para Docker y Traefik v3.6

Responsabilidad:
- Sincroniza dinámicamente el ciclo de vida de los contenedores Docker en 'pdf-network'
  con el catálogo de HashiCorp Consul.
- Identifica instancias individuales con su ID único e IP propia en la red de Docker.
- Asigna health checks HTTP individuales de Consul para cada réplica.
- Inyecta tags de Traefik v3 para enrutamiento, middlewares y balanceo de carga.
- Maneja eventos de Docker en tiempo real (start, die, stop, kill) y reconciliación periódica.
"""

import http.client
import json
import logging
import os
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [consul-registrator] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("consul-registrator")

CONSUL_HTTP_ADDR = os.getenv("CONSUL_HTTP_ADDR", "http://consul:8500").rstrip("/")
DOCKER_SOCKET_PATH = os.getenv("DOCKER_SOCKET_PATH", "/var/run/docker.sock")
TARGET_NETWORK = os.getenv("TARGET_NETWORK", "pdf-network")
RECONCILE_INTERVAL = int(os.getenv("RECONCILE_INTERVAL", "10"))

SERVICE_DEFINITIONS = {
    "extractor": {
        "port": 8000,
        "health_path": "/health/ready",
        "tags": [
            "traefik.enable=true",
            "traefik.http.routers.extractor.rule=Host(`extractor.universidad.localhost`)",
            "traefik.http.routers.extractor.entrypoints=web",
            "traefik.http.routers.extractor.priority=10",
            "traefik.http.routers.extractor.middlewares=rate-limit-extract@file,circuit-breaker-extractor@file,retry-on-shutdown@file",
            "traefik.http.routers.extractor-health.rule=Host(`extractor.universidad.localhost`) && (Path(`/health`) || PathPrefix(`/health/`))",
            "traefik.http.routers.extractor-health.entrypoints=web",
            "traefik.http.routers.extractor-health.priority=100",
            "traefik.http.services.extractor.loadbalancer.server.port=8000",
        ],
    },
    "documents": {
        "port": 8000,
        "health_path": "/health/ready",
        "tags": [
            "traefik.enable=true",
            "traefik.http.routers.documents.rule=Host(`documents.universidad.localhost`)",
            "traefik.http.routers.documents.entrypoints=web",
            "traefik.http.routers.documents.priority=10",
            "traefik.http.routers.documents.middlewares=circuit-breaker-documents@file,retry-on-shutdown@file",
            "traefik.http.routers.documents-health.rule=Host(`documents.universidad.localhost`) && (Path(`/health`) || PathPrefix(`/health/`))",
            "traefik.http.routers.documents-health.entrypoints=web",
            "traefik.http.routers.documents-health.priority=100",
            "traefik.http.services.documents.loadbalancer.server.port=8000",
        ],
    },
    "api": {
        "port": 8000,
        "health_path": "/ready",
        "tags": [
            "traefik.enable=true",
            "traefik.http.routers.api.rule=Host(`api.universidad.localhost`)",
            "traefik.http.routers.api.entrypoints=web",
            "traefik.http.routers.api.priority=10",
            "traefik.http.routers.api.middlewares=rate-limit-api@file,circuit-breaker-api@file,retry-on-shutdown@file",
            "traefik.http.routers.api-health.rule=Host(`api.universidad.localhost`) && (Path(`/health`) || Path(`/ready`))",
            "traefik.http.routers.api-health.entrypoints=web",
            "traefik.http.routers.api-health.priority=100",
            "traefik.http.services.api.loadbalancer.server.port=8000",
        ],
    },
}


class UnixSocketHTTPConnection(http.client.HTTPConnection):
    """Adaptador HTTP sobre el socket Unix del daemon de Docker."""

    def __init__(self, socket_path, timeout=10):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock


def docker_request(method, path, timeout=10):
    conn = UnixSocketHTTPConnection(DOCKER_SOCKET_PATH, timeout=timeout)
    conn.request(method, path, headers={"Host": "localhost"})
    res = conn.getresponse()
    data = res.read()
    conn.close()
    if res.status >= 400:
        raise RuntimeError(f"Docker API error {res.status}: {data.decode('utf-8', 'ignore')}")
    return json.loads(data.decode("utf-8"))


def consul_request(method, path, data=None):
    url = f"{CONSUL_HTTP_ADDR}{path}"
    req_data = json.dumps(data).encode("utf-8") if data is not None else None
    headers = {"Content-Type": "application/json"} if req_data else {}
    req = urllib.request.Request(url, data=req_data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            content = resp.read()
            return json.loads(content.decode("utf-8")) if content else None
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "ignore")
        raise RuntimeError(f"Consul API error {e.code}: {body}")


class Registrator:
    def __init__(self):
        self.running = True
        self.registered_instances = set()  # Set de service_id
        self.lock = threading.Lock()

    def identify_service(self, container_info):
        """Identifica si el contenedor corresponde a uno de los servicios a registrar."""
        labels = container_info.get("Config", {}).get("Labels", {}) or {}
        compose_service = labels.get("com.docker.compose.service")
        if compose_service in SERVICE_DEFINITIONS:
            return compose_service

        name = container_info.get("Name", "").lstrip("/")
        for s in SERVICE_DEFINITIONS:
            if s in name:
                return s
        return None

    def register_container(self, container_id):
        try:
            info = docker_request("GET", f"/containers/{container_id}/json")
        except Exception as e:
            logger.debug(f"No se pudo inspeccionar contenedor {container_id[:12]}: {e}")
            return

        state = info.get("State", {})
        if not state.get("Running"):
            return

        service_name = self.identify_service(info)
        if not service_name:
            return

        networks = info.get("NetworkSettings", {}).get("Networks", {})
        net_info = networks.get(TARGET_NETWORK)
        if not net_info:
            logger.debug(f"Contenedor {container_id[:12]} no está conectado a {TARGET_NETWORK}")
            return

        ip_address = net_info.get("IPAddress")
        if not ip_address:
            logger.warning(f"Contenedor {container_id[:12]} sin IP en {TARGET_NETWORK}")
            return

        svc_def = SERVICE_DEFINITIONS[service_name]
        short_id = container_id[:12]
        service_id = f"{service_name}-{short_id}"
        health_url = f"http://{ip_address}:{svc_def['port']}{svc_def['health_path']}"

        payload = {
            "ID": service_id,
            "Name": service_name,
            "Address": ip_address,
            "Port": svc_def["port"],
            "Tags": svc_def["tags"],
            "Check": {
                "HTTP": health_url,
                "Interval": "3s",
                "Timeout": "2s",
                "DeregisterCriticalServiceAfter": "30s",
            },
        }

        try:
            consul_request("PUT", "/v1/agent/service/register", payload)
            with self.lock:
                self.registered_instances.add(service_id)
            logger.info(
                f"✔ Registrado en Consul: [{service_name}] ID={service_id} IP={ip_address}:{svc_def['port']}"
            )
        except Exception as e:
            logger.error(f"✘ Error al registrar {service_id} en Consul: {e}")

    def deregister_container(self, container_id):
        short_id = container_id[:12]
        # Buscar el service_id correspondiente
        with self.lock:
            targets = [s for s in self.registered_instances if s.endswith(f"-{short_id}")]

        if not targets:
            # Si no está en el set, intentar por prefijos estándar
            targets = [f"{s}-{short_id}" for s in SERVICE_DEFINITIONS]

        for s_id in targets:
            try:
                consul_request("PUT", f"/v1/agent/service/deregister/{s_id}")
                with self.lock:
                    self.registered_instances.discard(s_id)
                logger.info(f"✔ Dado de baja de Consul: ID={s_id}")
            except Exception as e:
                logger.debug(f"No se pudo desregistrar {s_id}: {e}")

    def reconcile(self):
        """Reconciliación periódica entre contenedores vivos de Docker y catálogo de Consul."""
        try:
            containers = docker_request("GET", "/containers/json")
        except Exception as e:
            logger.error(f"Error al listar contenedores de Docker: {e}")
            return

        try:
            consul_services = consul_request("GET", "/v1/agent/services") or {}
        except Exception as e:
            logger.error(f"Error al consultar servicios de Consul: {e}")
            return

        active_docker_cids = {c["Id"][:12] for c in containers}

        # 1. Registrar contenedores vivos que falten en Consul
        for c in containers:
            self.register_container(c["Id"])

        # 2. Desregistrar servicios en Consul cuyo contenedor ya no exista
        for s_id, s_data in consul_services.items():
            s_name = s_data.get("Service")
            if s_name in SERVICE_DEFINITIONS:
                # Comprobar si el contenedor sigue vivo
                cid_part = s_id.split("-")[-1]
                if cid_part not in active_docker_cids:
                    logger.warning(f"Reconciliación: eliminando instancia huérfana de Consul {s_id}")
                    try:
                        consul_request("PUT", f"/v1/agent/service/deregister/{s_id}")
                        with self.lock:
                            self.registered_instances.discard(s_id)
                    except Exception as err:
                        logger.debug(f"Error al desregistrar huérfano {s_id}: {err}")

    def listen_docker_events(self):
        """Escucha continua del stream de eventos del daemon de Docker."""
        while self.running:
            conn = None
            try:
                logger.info(f"Conectando al stream de eventos de Docker en {DOCKER_SOCKET_PATH}...")
                conn = UnixSocketHTTPConnection(DOCKER_SOCKET_PATH, timeout=None)
                conn.request("GET", '/events?filters={"type":["container"]}', headers={"Host": "localhost"})
                res = conn.getresponse()
                if res.status >= 400:
                    logger.error(f"Error conectando a eventos de Docker: {res.status}")
                    time.sleep(3)
                    continue

                logger.info("✔ Escuchando eventos de ciclo de vida de Docker...")
                buffer = b""
                while self.running:
                    chunk = res.read(1024)
                    if not chunk:
                        break
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            event = json.loads(line.decode("utf-8"))
                            action = event.get("Action", "")
                            actor = event.get("Actor", {})
                            cid = actor.get("ID")
                            if not cid:
                                continue

                            if action in ("start", "unpause"):
                                self.register_container(cid)
                            elif action in ("die", "stop", "kill", "destroy"):
                                self.deregister_container(cid)
                        except Exception as parse_err:
                            logger.debug(f"Error parseando evento: {parse_err}")

            except Exception as e:
                if self.running:
                    logger.warning(f"Desconexión del stream de eventos de Docker: {e}. Reintentando en 3s...")
                    time.sleep(3)
            finally:
                if conn:
                    try:
                        conn.close()
                    except Exception:
                        pass

    def run(self):
        logger.info("Esperando que Consul esté disponible y saludable...")
        for _ in range(30):
            try:
                status = consul_request("GET", "/v1/status/leader")
                if status:
                    logger.info(f"Consul activo con líder: {status}")
                    break
            except Exception:
                time.sleep(1)
        else:
            logger.warning("Consul aún no respondió, iniciando registrador de todas formas.")

        # Sincronización inicial
        self.reconcile()

        # Iniciar thread de eventos de Docker
        t_events = threading.Thread(target=self.listen_docker_events, daemon=True)
        t_events.start()

        # Bucle principal de reconciliación periódica (Factor IX y Auto-corrección)
        while self.running:
            time.sleep(RECONCILE_INTERVAL)
            if self.running:
                self.reconcile()


def main():
    registrator = Registrator()

    def handle_signal(sig, frame):
        logger.info(f"Capturada señal {sig}. Deteniendo registrador...")
        registrator.running = False
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    registrator.run()


if __name__ == "__main__":
    main()
