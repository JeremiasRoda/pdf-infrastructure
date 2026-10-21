# Suite de Pruebas de Carga y Rendimiento

**Proyecto:** `pdf-extractext`  
**Cátedra:** Desarrollo de Software — UTN Facultad Regional San Rafael  
**Módulo:** `pdf-infrastructure / load-tests` (Issue #5)

Esta suite implementa los protocolos formales de evaluación de rendimiento y escalabilidad exigidos por la cátedra, permitiendo comparar el comportamiento del sistema con **1 réplica (Baseline)** frente a **5 réplicas (Escalado Horizontal)** bajo dos herramientas complementarias:
1. **k6 (Spike Test)**: Prueba de concurrencia abrupta con 100 Usuarios Virtuales (VUs).
2. **Vegeta (Carga Fija Sostenida)**: Inyección constante de 50 peticiones por segundo durante 30 segundos (1.500 solicitudes totales).

---

## 📋 Estructura de la Suite

```
load-tests/
├── k6-spike.js             # Script de prueba Spike (100 VUs, 40s total)
├── run-vegeta.sh           # Script ejecutor de Vegeta para Linux / macOS
├── run-vegeta.ps1          # Script ejecutor de Vegeta para Windows PowerShell
├── vegeta-targets.txt      # Definición de objetivos de rotación (autogenerado)
├── README.md               # Esta guía metodológica y protocolo de cátedra
└── pdfs/                   # Dataset oficial de 4 PDFs (ignorado en git)
    ├── .gitkeep
    ├── doc1.pdf
    ├── doc2.pdf
    ├── doc3.pdf
    └── doc4.pdf
```

---

## 🛠️ Requisitos Previos y Herramientas

Para ejecutar las pruebas en tu máquina, puedes usar los binarios locales o las imágenes oficiales de Docker:

- **Docker y Compose**: Motor activo y red `pdf-network` inicializada.
- **k6**: [Descargar k6](https://k6.io/docs/get-started/installation/) o ejecutar mediante `grafana/k6:latest`.
- **Vegeta**: [Descargar Vegeta](https://github.com/tsenart/vegeta/releases) o ejecutar mediante `ghcr.io/tsenart/vegeta:latest`.

> [!TIP]
> Los scripts `run-vegeta.sh` y `run-vegeta.ps1` detectan automáticamente si Vegeta está instalado; si no lo está, **lo ejecutan dentro de un contenedor Docker sin requerir instalación manual**.

---

## 📥 Paso 1: Preparación del Dataset de PDFs

Antes de lanzar los benchmarks, debemos contar con los 4 archivos PDF de prueba en `load-tests/pdfs/`.

Ejecuta el script de importación según tu sistema operativo:

- **En Windows (PowerShell):**
  ```powershell
  .\scripts\copy-stress-pdfs.ps1
  ```
- **En Linux / macOS / Git Bash:**
  ```bash
  chmod +x ./scripts/copy-stress-pdfs.sh
  ./scripts/copy-stress-pdfs.sh
  ```

*Si el repositorio monolito `../pdf-extractext/tests/stress/pdfs` existe, copiará los PDFs oficiales. Si aún no está clonado, generará 4 PDFs sintéticos válidos para permitir ejecutar las pruebas de inmediato.*

---

## 🔬 Protocolo de Evaluación: Baseline vs. 5 Réplicas

Para el informe de la cátedra, cada prueba debe ejecutarse en **dos escenarios**:

1. **Escenario A (Baseline):** 1 sola réplica de `extractor`.
2. **Escenario B (Escalado Horizontal):** 5 réplicas de `extractor` balanceadas por Traefik.

### Preparación del Escenario A (1 Réplica):
```bash
docker compose -f docker-compose.integration.yml up -d --build --scale extractor=1
```

### Preparación del Escenario B (5 Réplicas):
```bash
docker compose -f docker-compose.integration.yml up -d --scale extractor=5
```

---

## 📊 Monitoreo de Recursos en Tiempo Real

Durante la ejecución de cualquier benchmark, abre una terminal secundaria y ejecuta el monitor en vivo para observar la saturación de CPU y consumo de memoria por réplica:

- **En Windows:**
  ```powershell
  .\scripts\monitor-stats.ps1
  ```
- **En Linux / macOS:**
  ```bash
  ./scripts/monitor-stats.sh
  ```

---

## 🚀 Prueba 1: k6 Spike Test (100 VUs)

### Perfil de Carga:
- **0 a 10s:** Subida abrupta de 0 a 100 usuarios virtuales (Spike).
- **10s a 30s:** Meseta sostenida de 100 usuarios virtuales continuos.
- **30s a 40s:** Rampa descendente de 100 a 0 usuarios (Recuperación).
- **Target:** `POST http://extractor.universidad.localhost/extract`
- **Payload:** Rotación cíclica entre `doc1.pdf`, `doc2.pdf`, `doc3.pdf` y `doc4.pdf`.
- **Validación:** Status `200 OK`, JSON con campos `content` y `page_count`.

### Ejecución:

#### Con binario local de k6:
```bash
k6 run load-tests/k6-spike.js
```

#### Con Docker (si no tienes k6 instalado):
```bash
docker run --rm -i \
  --network=pdf-network \
  -v "${PWD}/load-tests:/load-tests" \
  -w /load-tests \
  -e TARGET_URL="http://extractor:8000/extract" \
  grafana/k6:latest run k6-spike.js
```

---

## ⚡ Prueba 2: Vegeta Carga Fija Sostenida (50 req/s)

### Perfil de Carga:
- **Tasa:** 50 peticiones/segundo constantes.
- **Duración:** 30 segundos (Total exacto: 1.500 solicitudes).
- **Timeout del cliente:** 30 segundos.
- **Target:** Rotación de los 4 PDFs oficiales hacia `POST http://extractor.universidad.localhost/extract`.

### Ejecución:

- **En Windows (PowerShell):**
  ```powershell
  .\load-tests\run-vegeta.ps1
  ```
- **En Linux / macOS:**
  ```bash
  chmod +x ./load-tests/run-vegeta.sh
  ./load-tests/run-vegeta.sh
  ```

El resultado se mostrará en pantalla y se guardará automáticamente en `load-tests/report.txt`.

---

## 📈 Plantilla de Tabla Comparativa para el Informe Final

Completa esta tabla comparativa con los resultados obtenidos en tus corridas para presentar ante la cátedra:

| Métrica de Evaluación | 1 Réplica (Baseline) | 5 Réplicas (Escalado) | Factor de Mejora / Variación |
| :--- | :--- | :--- | :--- |
| **Herramienta k6 — Throughput (req/s)** | *ej. 12.4 req/s* | *ej. 48.7 req/s* | *+292% (3.9x)* |
| **Herramienta k6 — Latencia Mediana p(50)** | *ej. 1.850 ms* | *ej. 320 ms* | *-82% de latencia* |
| **Herramienta k6 — Latencia Percentil 95** | *ej. 4.200 ms* | *ej. 890 ms* | *-78% de latencia* |
| **Herramienta k6 — Tasa de Errores (%)** | *ej. 4.8%* | *0.0%* | *Tolerancia total* |
| **Vegeta — Solicitudes Exitosas / 1500** | *ej. 1.150 / 1.500* | *1.500 / 1.500* | *100% de éxito* |
| **Vegeta — Throughput Efectivo (req/s)** | *ej. 38.3 req/s* | *50.0 req/s* | *100% de la tasa solicitada* |
| **Vegeta — Latencia p(99)** | *ej. 6.800 ms* | *ej. 1.100 ms* | *-83%* |
| **Consumo Máximo de CPU por Contenedor** | *100% (1 CPU)* | *~85% en cada una* | *Carga balanceada* |
| **Consumo de Memoria RAM por Contenedor** | *~280 MB* | *~250 MB por réplica* | *Estable dentro del límite* |

---

## 🛑 Regla de Oro sobre Redis y Pruebas Baseline

> [!WARNING]
> Según las reglas de la cátedra UTN FRSR:
> - Durante la obtención de las métricas **Baseline** con k6 y Vegeta, el servicio **Redis DEBE permanecer inactivo**.
> - La activación de Redis (`docker compose --profile cache up -d redis`) corresponde a la fase posterior de **Optimización con Caché**, donde se repetirán estas mismas pruebas para documentar la ganancia de rendimiento por retención de respuestas previas.
