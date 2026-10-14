@echo off
REM ==============================================================================
REM Script de inicialización de la red externa Docker para 'pdf-infrastructure'
REM UTN FR San Rafael - Arquitectura de Microservicios
REM ==============================================================================

setlocal enabledelayedexpansion
set NETWORK_NAME=pdf-network

echo ==========================================================
echo  Verificando red externa de Docker: '%NETWORK_NAME%'
echo ==========================================================

docker network inspect %NETWORK_NAME% >nul 2>&1
if %errorlevel% equ 0 (
    echo [INFO] La red '%NETWORK_NAME%' ya existe. No se requiere accion.
) else (
    echo [INFO] Creando red tipo bridge '%NETWORK_NAME%'...
    docker network create --driver bridge --attachable %NETWORK_NAME%
    if %errorlevel% equ 0 (
        echo [SUCCESS] Red '%NETWORK_NAME%' creada exitosamente.
    ) else (
        echo [ERROR] No se pudo crear la red '%NETWORK_NAME%'. Verifique que Docker Desktop este corriendo.
        exit /b 1
    )
)

echo ==========================================================
endlocal
