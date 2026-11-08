# Experimento de contexto de Ollama

## Objetivo

Comprobar si el modelo recupera un identificador de un request anterior cuando el cliente vuelve a enviar el historial en el siguiente request.

## Alcance

Es una prueba directa de la API de Ollama. No valida la integración de BatLLM con **OllamaConnector**, modelito ni la interfaz gráfica.

Windows Doctor sigue siendo un diagnóstico de solo lectura: puede comprobar la API y el modelo instalado, pero no ejecuta inferencias. Este experimento sí realiza inferencias y se ejecuta por separado.

## Diseño

Cada prueba usa un identificador nuevo y compara dos condiciones:

- **Sin historial:** el segundo request contiene solo la segunda pregunta.
- **Con historial:** el segundo request contiene el primer mensaje del usuario, la respuesta del asistente y la segunda pregunta.

Se mantienen el modelo y las opciones. El orden de las condiciones alterna entre pruebas para reducir el efecto del calentamiento del modelo. El script registra los mensajes exactos enviados a cada request.

## Entorno y resultado

- Modelo: **smollm2:360m**.
- Python: **3.12.6**.
- Ollama: **0.40.13**.
- Cliente Python: **0.6.3**.
- Temperatura: **0**. Seed: **42**.
- Ejecución: **3 pares / 12 requests**.

| Resultado | Sin historial | Con historial |
| --- | ---: | ---: |
| Identificador recuperado | 0/3 | 3/3 |

Los **3/3 pares** apoyaron la hipótesis y no hubo errores de ejecución. El formato exacto se cumplió en **0/3** respuestas con historial: el modelo devolvió el identificador acompañado de texto.

**SUPPORTED_ALL_VALID_PAIRS** significa que todos los pares válidos de esta ejecución mostraron ese resultado. No es una afirmación universal sobre otros modelos o configuraciones.

## Ejecución

Desde la raíz del repositorio, en Windows PowerShell:

```powershell
.\scripts\windows\batllm-doctor.ps1 -Target Gameplay -Model smollm2:360m -Json

.\.venv_BatLLM\Scripts\python.exe .\scripts\research\ollama_memory_poc.py `
    --model smollm2:360m `
    --trials 3
```

Para guardar el informe fuera del repositorio:

```powershell
.\.venv_BatLLM\Scripts\python.exe .\scripts\research\ollama_memory_poc.py `
    --model smollm2:360m `
    --trials 3 `
    --output "$env:TEMP\batllm-ollama-memory-poc.json"
```

El script no instala paquetes, inicia o detiene Ollama, descarga modelos, modifica la configuración de BatLLM ni accede a sesiones guardadas.

## Pruebas del script

Las pruebas unitarias usan un cliente simulado y no llaman a Ollama. Resultado registrado: **5/5 PASS**.

```powershell
.\.venv_BatLLM\Scripts\python.exe -m unittest discover `
    -s scripts\research `
    -p "test_*.py" `
    -v
```

## Límites y siguiente paso

El resultado muestra el efecto de reenviar mensajes en requests independientes. No demuestra memoria persistente ni que BatLLM construya correctamente el historial en la aplicación.

El siguiente paso es inspeccionar **src/game/ollama_connector.py** y probar los mensajes reales enviados en los modos de contexto, incluyendo que el historial no se filtre entre partidas.
