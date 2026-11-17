# BatLLM — Bitácora de Lucas Borges

Registro del trabajo del taller. Se conservan horas informadas, resultados comprobados y pendientes. No se agregan horas ni se presentan pruebas parciales como validación completa del producto.

## 18–24 de octubre de 2026 — 11 h reportadas

- **18/10 (3 h):** preparación y exploración inicial del proyecto.
- **19/10:** revisión remota de documentación, arquitectura, Ollama, historial y pruebas. Sin duración registrada; no se suma a las 11 h.
- **20/10 (1 h):** primera reunión del taller.
- **21/10 (3 h), 22/10 (2 h), 23/10 (1 h) y 24/10 (1 h):** horas reportadas; no quedó detalle de tareas por día.

## 26 de octubre de 2026 — aproximadamente 4 h

**Objetivo:** preparar BatLLM en Windows y comprobar el entorno local.

- Preparé el entorno con Python 3.12.6 y desarrollé Windows Doctor (diagnóstico de solo lectura), Windows Apply (acciones optativas) y su lanzador.
- Instalé Ollama 0.40.11 y el modelo **smollm2:360m**. Verifiqué la CLI, la API local y una respuesta de inferencia.
- Configuré **BATLLM_HOME** fuera del repositorio. Doctor informó **Gameplay READY**: 10 PASS, 1 WARN y 0 FAIL.
- Corregí el paso de argumentos de PowerShell en Apply. La aplicación gráfica abrió en Game 1 / Round 0 / Turn 0; todavía no se había verificado un turno real.

**Validación:** smoke tests del lanzador (13), Doctor (14), Gameplay simulado (13), plan de Apply (8) y confirmaciones (20): PASS. Documentación: PASS.

La suite Python registró **193 PASS, 1 FAIL y 2 SKIP**. El fallo correspondía al desacuerdo baseline sobre el modelo inicial (smollm2), asociado al issue [#59](https://github.com/krahd/BatLLM/issues/59). Los runners core y non-live no quedaron validados como PASS.

## 27 de octubre de 2026 — juego y diagnóstico de Windows

- Con Ollama y **smollm2:360m**, ambos jugadores devolvieron el comando M; la interfaz avanzó hasta Game 1 / Round 1 / Turn 1.
- En otra ejecución, los prompts mixtos dejaron la interfaz en Not responding y hubo que cerrarla. La causa no quedó identificada; tampoco apareció un evento de Windows que la explicara.
- Desarrollé **batllm-launch.ps1**, un monitor optativo de procesos, CPU, memoria, respuesta de la interfaz y disponibilidad de la API local. Genera CSV y JSON fuera del checkout y permite perfiles de alerta de RAM.
- En una prueba Gameplay de 28,4 s se obtuvieron 8 muestras: primera respuesta de interfaz a los 3,6 s, RAM mínima disponible de 20,6 %, RSS máximo de BatLLM de 228 MB y latencia de API de 5,4–5,8 ms. No hubo alertas. La latencia de API no mide el tiempo de inferencia.
- Sintaxis PowerShell: PASS. Pruebas offline de alertas: **23 PASS**.
- Publiqué los dos scripts en el fork mediante el commit **5699993**. No hubo push al repositorio del taller ni PR.

**Pendiente de aquella fecha:** no se había confirmado el guardado y replay de una sesión. La revisión del 2/11 aportó evidencia posterior.

**Tiempo:** no informado.

## 2 de noviembre de 2026 — sesión y experimento de contexto

- Encontré la sesión **session-2026-10-27-18-10-18.json** y la abrí con Game Analyzer. La captura mostró Game 1 / Round 1, el inicio de los turnos 1 y 2, prompts y estado.
- No se verificaron el replay completo ni un resultado limpio de State Diff.
- Ejecuté el experimento de contexto con **smollm2:360m**, Python 3.12.6, Ollama 0.40.13 y cliente Python 0.6.3; temperatura 0 y seed 42.
- Se hicieron **3 pares de pruebas (12 requests)**: el identificador apareció en **0/3** casos sin historial y en **3/3** con historial. Los tres pares apoyaron la hipótesis y no hubo errores de ejecución.
- El formato exacto se cumplió en **0/3** respuestas con historial: el modelo agregó texto al identificador.
- Añadí el script y sus pruebas. Compilación, documentación y diff: PASS; pruebas unitarias: **5/5 PASS**.
- Publiqué el experimento en el fork mediante el commit **8181ea2**. No hubo push al repositorio del taller ni PR.

**Conclusión acotada:** en esta configuración, el cliente tuvo que reenviar los mensajes anteriores para que el segundo request recibiera ese contexto. No demuestra memoria persistente ni valida la integración de BatLLM con OllamaConnector/modelito.

**Tiempo reportado:** 3 h.

## 7 de noviembre de 2026 — migración al fork del taller

**Tiempo:** 17:00–21:30 (4 h 30 min).  
**Participante:** Lucas Borges.

**Repositorios y ramas:**
- Fork personal: **lucasborges2001/BatLLM**.
- Repositorio del taller: **Taller-BatLLM/BatLLM**.
- Rama de trabajo: **docs/taller-lucas-borges**.
- Commit de partida: **200a03c**.
- upstream/main integrado desde **5e3ed55**.

**Trabajo realizado:**
- Cloné el fork en un checkout nuevo y conservé el anterior.
- Configuré origin (fork personal) y upstream (repositorio del taller).
- Creé respaldo/bitacora-original desde la rama anterior y derivé de ella la rama de trabajo, conservando los commits personales.
- Integré upstream/main. Resolví conflictos en STATUS.md y tools/check_docs.py, conservando el STATUS del taller y comprobando la sintaxis del checker.
- El merge quedó en **a0caf45**. Verifiqué que **200a03c** sigue siendo ancestro de la rama.
- Moví la bitácora a **docs/taller/lucas-borges/bitacora.md** y el experimento a **docs/taller/lucas-borges/experimentos/ollama-memory-poc.md**. Actualicé docs/README.md.

**Validación y publicación:**
- Ancestro de 200a03c: PASS.
- python -m py_compile tools/check_docs.py: PASS.
- python tools/check_docs.py: PASS.
- git diff --check: PASS.
- Rutas documentales verificadas; git status limpio.
- Repositorios remotos verificados. Publiqué **docs/taller-lucas-borges** en origin; commit de reorganización **5dad718**.

No se creó PR ni se publicó nada en upstream.


## 10 de noviembre de 2026 — auditoría del Connector e integración real

**Tiempo:** no informado.  
**Repositorio:** lucasborges2001/BatLLM.  
**Rama:** docs/taller-lucas-borges.  
**SHA probado localmente:** ad06d424ce3175f807d3fceba81819c7c6e0be98.

**Actualización del checkout:**
- Ejecuté git pull --ff-only. La rama avanzó de 0ea90e7 a ad06d42 mediante dos commits: 385cd37 y ad06d42.
- git status --short --branch quedó limpio después de actualizar y también después de ejecutar las pruebas.
- Los dos commits añadieron la prueba optativa de integración real y su ejecutor PowerShell. No se modificó código de producto.

**Auditoría del Connector:**
- Ejecuté scripts/windows/batllm-connector-audit.ps1.
- Resultado: **PASS**, 14 tests, 0 failures, 0 errors y 0 skipped.
- SHA probado: ad06d424ce3175f807d3fceba81819c7c6e0be98.
- El runner usa un Client simulado para inspeccionar contratos, payloads e historial. Es evidencia de regresión/contrato, no una inferencia real contra Ollama.
- Informe JUnit: tmp/2026-11-10/21/OllamaConnector/connector-audit-20261110-213811-804.junit.xml.
- Informe JSON: tmp/2026-11-10/21/OllamaConnector/connector-audit-20261110-213811-804.json.

**Integración real:**
- Ejecuté scripts/windows/batllm-connector-live.ps1 sin override de modelo: **FAIL**, 1 test, 1 failure, 0 errors y 0 skipped.
- Repetí con el argumento literal -Model "modelo:tag": **FAIL**, 1 test, 1 failure, 0 errors y 0 skipped.
- Ambas ejecuciones informaron el mismo SHA probado: ad06d424ce3175f807d3fceba81819c7c6e0be98.
- Primer informe: tmp/2026-11-10/21/OllamaConnectorLive/connector-live-20261110-213823-509.junit.xml; log y JSON con el mismo prefijo.
- Segundo informe: tmp/2026-11-10/21/OllamaConnectorLive/connector-live-20261110-213837-918.junit.xml; log y JSON con el mismo prefijo.

**Interpretación y límites:**
- La prueba no quedó omitida: pytest informó 1 test ejecutado y 0 skipped.
- El resumen de consola no incluye el mensaje de fallo. Sin el contenido del JUnit, log o JSON no se puede determinar si falló la consulta al endpoint, la comprobación del modelo instalado, una inferencia o una aserción del historial.
- El segundo comando utilizó el texto de ejemplo modelo:tag. No se aportó evidencia de que ese nombre exista en el inventario local de Ollama.
- No se declara la integración real como validada ni se atribuye todavía el fallo al producto.
- La auditoría simulada PASS y la integración real FAIL son resultados de alcances distintos y no se contradicen.

**Siguiente paso:** revisar el JUnit, log y JSON de una ejecución real con el nombre exacto de un modelo que figure en ollama list. Clasificar primero el fallo; corregir código o prueba solo después de localizar la causa.


## 17 de noviembre de 2026 — P0: diagnóstico y validación real de OllamaConnector

**Tiempo informado:** 17:00–20:00 (3 h). La franja se registra como tiempo de trabajo informado; no hubo cronómetro de dedicación efectiva. Los tiempos de inferencia indicados abajo sí proceden de la medición del test.

**Repositorio:** lucasborges2001/BatLLM.  
**Rama:** docs/taller-lucas-borges.  
**SHA final validado:** 56b4e432ea3381bce0ccbe7cff7658092a9fa1e3.

**Diagnóstico del entorno y de los fallos históricos:**
- Incorporé el **OllamaConnector Doctor**, su prueba simulada y la documentación específica mediante el commit **170a9d9**. El cambio añadió **scripts/windows/batllm-connector-doctor.ps1**, **scripts/windows/tests/test-batllm-connector-doctor.ps1** y **docs/taller/lucas-borges/experimentos/ollama-connector-doctor.md**.
- En Windows, las pruebas simuladas del Doctor finalizaron con **18/18 PASS**. El Doctor estático también informó PASS.
- El preflight real detectó Ollama **0.40.16**, endpoint **http://127.0.0.1:11434** y el modelo instalado **smollm2:360m**. Se comprobó que **smollm2** no coincide con el tag instalado; el modelo debía seleccionarse con su nombre exacto.
- Revisé los dos FAIL históricos del 10/11. Ambos se detuvieron en la precondición de modelo no instalado (**smollm2** y el literal **modelo:tag**); no constituyen evidencia de una inferencia fallida ni de un defecto del Connector.

**Localización y corrección del FAIL de integración:**
- La primera ejecución real con **smollm2:360m**, sobre SHA **170a9d91ad20**, devolvió una primera respuesta no vacía, pero falló porque el test exigía un mensaje **system** que no existía en el historial.
- La configuración de la prueba usa contexto independiente y **prompt_augmentation=False**; el archivo de instrucciones correspondiente está vacío. En ese escenario, el historial esperado es **user → assistant**, no **system → user → assistant**.
- La causa estaba en la expectativa del test, no en el comportamiento observado del Connector. Corregí únicamente **src/tests/test_ollama_connector_live.py**, mediante el commit **56b4e43**. El test ahora comprueba el historial real de ambos mensajes y registra el tiempo individual de cada inferencia. No se modificó código de producto ni el contenido de las instrucciones.

**Validación final en Windows:**
- **scripts/windows/batllm-connector-audit.ps1**: **PASS**, 14 tests, 0 failures, 0 errors y 0 skipped; SHA probado **56b4e432ea33**.
- **scripts/windows/batllm-connector-live.ps1 -Model "smollm2:360m"**: **PASS**, 1 test, 0 failures, 0 errors y 0 skipped; se ejecutaron dos inferencias reales y se verificó el historial conversacional.
- Primera inferencia: **8,970 s**, respuesta de 441 caracteres.
- Segunda inferencia: **6,421 s**, respuesta de 464 caracteres.
- Tiempo acumulado medido de inferencia: **15,391 s**. Duración del testcase en JUnit: **17,589 s**. Duración total de pytest: **19,80 s**.
- El JSON del runner informó **repository_status_unchanged=True**, **sha_unchanged=True** y **warnings=[]**. **git status --short --branch** quedó limpio en **docs/taller-lucas-borges**, sincronizada con origin, sobre el SHA probado.

**Evidencia local generada (no incorporada al repositorio):**
- Doctor: **tmp/2026-11-17/19/ConnectorDoctor/connector-doctor-20261117-193155-787.json** y **.txt**.
- Auditoría: **tmp/2026-11-17/19/OllamaConnector/connector-audit-20261117-194159-648.junit.xml** y **.json**.
- Integración real: **tmp/2026-11-17/19/OllamaConnectorLive/connector-live-20261117-194211-674.junit.xml**, **.log** y **.json**.

**Resultado y alcance:** P0 cerrado con PASS para el preflight del entorno, la auditoría de contratos y el recorrido real de dos mensajes consecutivos en un mismo contexto con **smollm2:360m**. Esto no valida concurrencia entre bots, recuperación ante desconexiones ni todos los flujos de partida/UI; quedan fuera del alcance de este P0.

## Pendientes actuales

- Ampliar la validación del Connector a aislamiento entre bots, cambios de modo, límites de partida/ronda, concurrencia y recuperación ante desconexiones. El P0 solo validó dos mensajes consecutivos en un mismo contexto.
- Completar el replay y revisar State Diff de la sesión del 27/10.
- Investigar la causa del bloqueo de interfaz observado el 27/10.

- Diagnosticar el FAIL de la integración real OllamaConnector usando el JUnit, log y JSON generados el 10/11; la causa todavía no está determinada.
- Repetir la integración con un nombre de modelo confirmado en el inventario local de Ollama y conservar el SHA probado en el informe.
- Una vez validado el recorrido real, ampliar las pruebas a aislamiento entre bots, cambios de modo y límites de partida/ronda.
- Completar el replay y revisar State Diff de la sesión del 27/10.
- Investigar la causa del bloqueo de interfaz observado el 27/10.

- Verificar la construcción y el aislamiento del historial en la integración real de **src/game/ollama_connector.py** / modelito.
- Completar el replay y revisar State Diff de la sesión del 27/10.
- Investigar la causa del bloqueo de interfaz observado el 27/10.
