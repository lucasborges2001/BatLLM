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

## Pendientes actuales

- Verificar la construcción y el aislamiento del historial en la integración real de **src/game/ollama_connector.py** / modelito.
- Completar el replay y revisar State Diff de la sesión del 27/10.
- Investigar la causa del bloqueo de interfaz observado el 27/10.
