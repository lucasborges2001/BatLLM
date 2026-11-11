# Integración real de OllamaConnector

## Objetivo

Distinguir la validación de contratos del Connector de una ejecución que atraviesa el Connector, el transporte Modelito y un servicio Ollama ya iniciado. El objetivo inicial es comprobar dos mensajes secuenciales y la conservación del historial de conversación.

## Componentes y recorrido

La prueba optativa está en **src/tests/test_ollama_connector_live.py** y el ejecutor de Windows en **scripts/windows/batllm-connector-live.ps1**.

El recorrido probado es:

1. La prueba configura un modelo y endpoint local.
2. Comprueba el inventario de modelos mediante **llm.service.list_local_models**.
3. Crea una instancia real de **game.ollama_connector.OllamaConnector**.
4. Envía dos mensajes secuenciales con el mismo bot mediante **send_prompt_to_llm_sync**.
5. Comprueba que ambas respuestas sean texto no vacío y que el historial interno conserve el orden system/user/assistant/user/assistant.

La prueba configura temporalmente contextos independientes y prompt augmentation desactivado. Usa overrides de configuración de ejecución y el fixture de tests aísla BATLLM_HOME; no necesita guardar preferencias del usuario.

## Diferencia entre los dos runners

### Auditoría de contratos

**scripts/windows/batllm-connector-audit.ps1** ejecuta pruebas de contrato y regresión seleccionadas. El propio runner sustituye **game.ollama_connector.Client** por un cliente simulado, captura las solicitudes y devuelve respuestas controladas.

Cubre contratos del Connector, payload/historial, timeout, cambios de modo, cancelación y generaciones del juego, según los nodos de pytest seleccionados por el script.

Un PASS demuestra el comportamiento de esos casos simulados. No demuestra conectividad real, disponibilidad de un modelo ni inferencia de Ollama.

### Integración real

**scripts/windows/batllm-connector-live.ps1** activa explícitamente la prueba mediante BATLLM_RUN_OLLAMA_CONNECTOR_LIVE=1.

Usa un endpoint Ollama que ya debe estar en ejecución y un modelo que ya debe estar instalado. No inicia ni detiene el servicio, no descarga ni elimina modelos y no ejecuta una instalación.

La prueba verifica que el modelo solicitado aparezca en el inventario local. Se acepta el nombre exacto o, si el nombre solicitado no contiene tag, su variante :latest. Para evitar ambigüedad, conviene pasar el nombre exacto que devuelve ollama list.

El test realiza dos inferencias reales, pero no exige que las respuestas sean exactamente M y S0: solo comprueba que sean strings no vacíos. También inspecciona el historial interno del Connector después de cada solicitud. No captura por separado el cuerpo HTTP recibido por Ollama ni demuestra que el modelo haya recordado semánticamente la primera respuesta.

## Ejecución en Windows

Desde la raíz del checkout:

~~~powershell
git pull --ff-only

# Contratos y regresiones con Client simulado
.\scripts\windows\batllm-connector-audit.ps1

# Consultar los nombres exactos disponibles en el Ollama local
ollama list

# Integración real: sustituir el valor por un nombre confirmado en ollama list
.\scripts\windows\batllm-connector-live.ps1 -Model "nombre-exacto:tag"

git status --short --branch
~~~

También se puede omitir -Model para utilizar llm.model de la configuración efectiva. Si el modelo configurado no coincide con el inventario local, la prueba debe fallar sin intentar descargarlo.

El runner requiere **.venv_BatLLM\Scripts\python.exe**. Sus informes, logs y cachés se generan por defecto bajo **tmp/YYYY-MM-DD/HH/OllamaConnectorLive**. Registra el SHA y el estado Git antes y después de la prueba. Los temporales de Python se redirigen al directorio de salida y se restauran las variables de entorno del proceso al terminar.

## Evidencia local — 10 de noviembre de 2026

**Checkout:**
- Rama: **docs/taller-lucas-borges**.
- SHA probado: **ad06d424ce3175f807d3fceba81819c7c6e0be98**.
- git pull --ff-only avanzó de 0ea90e7 a ad06d42.
- git status --short --branch quedó limpio después de las pruebas.

**Auditoría simulada:**

| Resultado | Tests | Failures | Errors | Skipped |
| --- | ---: | ---: | ---: | ---: |
| PASS | 14 | 0 | 0 | 0 |

Informe JUnit: **tmp/2026-11-10/21/OllamaConnector/connector-audit-20261110-213811-804.junit.xml**.  
Informe JSON: **tmp/2026-11-10/21/OllamaConnector/connector-audit-20261110-213811-804.json**.

**Integración real:**

| Intento | Argumento de modelo | Resultado | Tests | Failures | Errors | Skipped |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| 1 | Configuración efectiva, sin -Model | FAIL | 1 | 1 | 0 | 0 |
| 2 | modelo:tag | FAIL | 1 | 1 | 0 | 0 |

Ambos informes identifican el mismo SHA probado. JUnit, log y JSON se generaron bajo **tmp/2026-11-10/21/OllamaConnectorLive/**, con los prefijos **connector-live-20261110-213823-509** y **connector-live-20261110-213837-918**, respectivamente.

### Diagnóstico pendiente

El resumen de consola no muestra el mensaje de fallo ni la etapa en que ocurrió. Por tanto, todavía no se puede atribuir el resultado a conexión, inventario de modelos, inferencia, transporte o lógica de historial.

El segundo intento utilizó el texto modelo:tag, pero no se aportó evidencia de que fuese un modelo instalado. Tampoco se dispone aquí del contenido de los informes JUnit, log y JSON. La causa debe clasificarse a partir de esos artefactos antes de modificar el producto o la prueba.

## Alcance que todavía no está validado

- Respuesta exacta del modelo a los comandos solicitados.
- Cuerpo HTTP exacto recibido por Ollama.
- Aislamiento real entre dos bots durante inferencias simultáneas.
- Aislamiento del historial entre partidas y rondas usando Ollama real.
- Prompt augmentation activado y sus variantes de contexto compartido.
- Timeouts reales, reintentos, cancelación durante una inferencia y recuperación.
- Flujo completo desde la interfaz Kivy hasta el proveedor.

El resultado de la auditoría simulada no sustituye estos casos. La integración real debe alcanzar PASS antes de considerar validado el recorrido de inferencia de BatLLM.
