# Suite de Pruebas de Carga y Rendimiento con k6

**Proyecto:** `pdf-extractext`  
**Cátedra:** Desarrollo de Software — UTN Facultad Regional San Rafael  
**Módulo:** `pdf-infrastructure / load-tests`

La herramienta oficial y exclusiva adoptada para evaluar el rendimiento, resiliencia y escalabilidad del ecosistema es **k6**.

---

## Estructura de la Suite

```
load-tests/
├── k6-spike.js             # Script de prueba Spike con k6 (100 VUs, 40s)
├── README.md               # Metodología y protocolo de ejecución
└── pdfs/                   # Directorio de fixtures PDF
    ├── .gitkeep
    ├── doc1.pdf            # Fixture auxiliar de desarrollo
    └── doc279.pdf          # Fixture oficial de 279 páginas (no versionado en git)
```

---

## Protocolo de Evaluación Oficial (k6 Spike Test - 100 VUs)

El perfil de prueba de k6 simula una avalancha repentina de tráfico (Spike):
- **0 a 10s:** Subida abrupta de 0 a 100 Usuarios Virtuales (VUs).
- **10s a 30s:** Meseta sostenida con 100 VUs concurrentes extrayendo texto.
- **30s a 40s:** Rampa descendente de 100 a 0 VUs para verificar la recuperación de los workers.

### Manejo Eficiente de Memoria en k6
El script `k6-spike.js` utiliza el modo binario en el *init context* (`open(FIXTURE_PATH, 'b')`).
Esto garantiza que el archivo PDF se lea y mantenga en memoria compartida una sola vez para todos los VUs, eliminando accesos repetitivos a disco y evitando duplicaciones innecesarias de memoria.

---

## Requisito del Fixture: PDF Oficial de 279 Páginas

El benchmark oficial para la cátedra exige procesar el documento extenso de **279 páginas** (~17.7 MB, SHA-256 `728c8a52...`):

1. **Cómo suministrar el archivo oficial:**
   Copie el archivo con el nombre `doc279.pdf` dentro de `load-tests/pdfs/doc279.pdf`.
   
   O bien, especifique una ruta externa mediante la variable de entorno `PDF_FIXTURE_PATH`:
   ```bash
   PDF_FIXTURE_PATH=/ruta/al/documento_279_paginas.pdf k6 run load-tests/k6-spike.js
   ```

2. **Detección y Validación:**
   `k6-spike.js` verifica la cabecera `%PDF` al inicio. Si el archivo no existe o no es un PDF válido, arrojará un error descriptivo impidiendo reportar benchmarks ficticios. Si no se cuenta con el PDF oficial en local, k6 utilizará el archivo auxiliar `doc1.pdf` indicando explícitamente en el reporte que se trata de un *fallback local de desarrollo*.

---

## Interacción con Rate Limiting en Traefik

Traefik v3.6 incorpora en la frontera el middleware `rate-limit-extract`.
- Durante operación normal, Traefik protege a los microservicios limitando ráfagas abusivas (`HTTP 429 Too Many Requests`).
- **Para ejecutar la prueba de carga de capacidad cruda del backend (Spike de 100 VUs):**
  Es necesario elevar temporalmente los límites en el archivo `.env`:
  ```env
  RATE_LIMIT_EXTRACT_AVERAGE=500
  RATE_LIMIT_EXTRACT_BURST=1000
  ```
  y reiniciar la infraestructura con `docker compose up -d`.
- El reporte de k6 desglosa de forma independiente:
  - Respuestas exitosas (`200 OK`)
  - Respuestas limitadas por Traefik (`429 Too Many Requests`)
  - Respuestas cortadas por Circuit Breaker (`503 Service Unavailable`)

---

## Ejecución del Benchmark

### 1. Preparar el Escenario Deseado:

- **Escenario Baseline (1 réplica):**
  ```bash
  docker compose -f docker-compose.integration.yml up -d --scale extractor=1
  ```
- **Escenario Escalado (5 réplicas):**
  ```bash
  docker compose -f docker-compose.integration.yml up -d --scale extractor=5
  ```

### 2. Ejecutar k6:

- **Con k6 instalado localmente:**
  ```bash
  k6 run load-tests/k6-spike.js
  ```

- **Vía Docker (sin instalar k6 en el host):**
  ```bash
  docker run --rm -i \
    --network pdf-network \
    -v "${PWD}/load-tests:/load-tests" \
    -e TARGET_URL="http://extractor:8000/extract" \
    grafana/k6:latest run /load-tests/k6-spike.js
  ```
