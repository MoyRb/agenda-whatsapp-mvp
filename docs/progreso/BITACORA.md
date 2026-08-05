# Bitácora de Desarrollo

---

## 2026-07-30 — Corte Vertical 1 (revisión aprobada con condiciones)

### Qué se implementó
- `supabase/functions/whatsapp-send/index.ts` — Edge Function para enviar plantilla `hello_world`
- `supabase/config.toml` — configuración local de Supabase con `verify_jwt = false` para la función
- `tests/invoke-whatsapp-send.ps1` — script PowerShell de prueba
- `CLAUDE.md` — instrucciones base del proyecto

### Decisiones técnicas

**Header `x-internal-secret` en lugar de `Authorization`:**
Se usa un header dedicado para evitar colisión con el flujo JWT de Supabase y hacer explícita la distinción entre autenticación de usuario y autorización interna entre servicios.

**`META_GRAPH_API_VERSION` obligatoria (sin fallback):**
Una versión de API hardcodeada puede quedar desactualizada silenciosamente. Al hacerla obligatoria, cualquier omisión falla ruidosamente en despliegue, no en producción ante el cliente.

**`AbortSignal.timeout(15_000)`:**
Supabase Edge Runtime admite `AbortSignal.timeout` (compatible con Deno). 15 segundos es suficiente para Meta Graph API bajo condiciones normales; evita que la función quede colgada consumiendo recursos.

**`timingSafeEqual` manual:**
Deno no expone `crypto.subtle.timingSafeEqual`. La implementación itera todos los bytes incluyendo el XOR de longitudes, evitando short-circuit tanto en longitud como en contenido.

**Logs sanitizados:**
`console.error` registra únicamente `status`, `code`, `type` y `message` del error de Meta. Nunca el token de acceso, el secret interno, ni headers completos.

**`supabase/config.toml` creado manualmente:**
El archivo no existía. Se creó con configuración mínima funcional más `[functions.whatsapp-send] verify_jwt = false`. Esto hace que el comportamiento sea consistente entre `supabase functions serve` (local) y `supabase functions deploy` (remoto), eliminando la necesidad de `--no-verify-jwt`.

### Estado al cierre de sesión
- Implementado: sí
- Validado con mensaje real: pendiente — requiere prueba del usuario con secrets reales

---

## 2026-07-31 — Corte Vertical 2: whatsapp-webhook

### Qué se implementó

- `supabase/functions/whatsapp-webhook/index.ts` — Edge Function para recibir eventos de Meta
- `supabase/config.toml` — añadido `[functions.whatsapp-webhook] verify_jwt = false`
- `tests/invoke-whatsapp-webhook.ps1` — script PowerShell con 4 casos de prueba
- `docs/progreso/ESTADO-ACTUAL.md` — sección Corte 2
- `CLAUDE.md` — comandos del webhook

### Decisiones técnicas

**Routing GET/POST explícito con 405 para otros métodos:**
Meta solo envía GET (handshake) y POST (eventos). Devolver 405 con header `Allow: GET, POST` es correcto según RFC y evita exponer comportamiento inesperado.

**Verificación HMAC con `crypto.subtle.verify()`:**
Se lee el body como `arrayBuffer()` antes de parsear JSON. La firma se verifica sobre los bytes originales, no sobre JSON re-serializado. `crypto.subtle.verify()` hace la comparación de forma constante en tiempo (sin timing attack).

**Comparación de verify_token sin short-circuit:**
`timingSafeStringEqual` itera todos los bytes con XOR y acumula diferencias, evaluando al final. Evita timing attack tanto en longitud como en contenido.

**Límite de 1 MB antes y después de leer:**
Primero se verifica `Content-Length` header (evita iniciar lectura de payloads gigantes). Luego se verifica `byteLength` de los bytes reales (por si el header fue omitido o mentido).

**Logs sanitizados con lista de campos permitidos:**
Solo se loggea `{ type, wabaId, phoneNumberId, messageId, messageType/status, from/recipient }`. Los números de teléfono se enmascaran con `maskPhone`. Nunca se loggea body, firma, headers, tokens, nombres ni contenido de mensajes.

**Script PS 5.1 con `[System.Net.WebRequest]`:**
`Invoke-RestMethod` recodifica el body, lo que haría que la firma HMAC no coincida. Se usa `WebRequest` para escribir exactamente el mismo `byte[]` que se firmó.

### Estado al cierre
- Implementado: ✅
- Validado sintéticamente: ✅
- Validado con Meta: ✅

---

## 2026-07-31 — Validación real de whatsapp-webhook

### Resultado

Prueba de integración exitosa con Meta:

- Meta aceptó la Callback URL y el Verify Token — handshake GET respondió con el challenge correcto.
- El campo `messages` quedó suscrito en la configuración de la app.
- Se envió un mensaje real desde el teléfono autorizado al número de prueba.
- Supabase recibió el POST firmado de Meta.
- El log confirmó: WABA ID real, Phone Number ID real, `message_id` con prefijo `wamid.`.
- El número de teléfono apareció enmascarado correctamente (`maskPhone`).
- El contenido del mensaje no fue registrado en ningún log.

### Incidencias resueltas

**1. Token temporal de Meta expirado**
El token de acceso había expirado. Se renovó en Meta for Developers y se actualizó en `supabase/.env.local` y en los secrets del proyecto desplegado.

**2. Suscripción a WABA requerida**
La aplicación no estaba suscrita a la cuenta de WhatsApp Business. Fue necesario llamar al endpoint `subscribed_apps` de la Graph API para registrar la app como suscriptora de la WABA. Solo después de ese paso Meta comenzó a entregar eventos POST.

### Estado final del Corte Vertical 2
- Implementado: ✅
- Validado sintéticamente: ✅
- Validado con Meta: ✅

---

## 2026-07-31 — Validación real de whatsapp-send

### Resultado

Prueba de integración exitosa:
- La Edge Function respondió `success: true`
- Meta devolvió un `message_id` válido
- La plantilla `hello_world` llegó al teléfono autorizado

### Incidencias resueltas

**1. Script incompatible con Windows PowerShell 5.1**
El script `tests/invoke-whatsapp-send.ps1` usaba el operador null-conditional `?.` (solo disponible en PS 7+). Se corrigió reemplazando por guards explícitos `if (-ne $null)`. También se sustituyó `[System.IO.StreamReader]::new()` por `New-Object System.IO.StreamReader()`. Validación de sintaxis con el parser de PS 5.1 confirmó 0 errores.

**2. Token temporal de Meta produjo Authentication Error**
El primer token usado había expirado o era de prueba. Se renovó el token en Meta for Developers y se actualizó en `supabase/.env.local` (y en los secrets del proyecto desplegado). La función respondió correctamente con el token actualizado.

### Estado final del Corte Vertical 1
- Implementado: ✅
- Validado: ✅

---

## 2026-07-31 — Corte Vertical 3: WhatsApp Flow estático de reservación

### Qué se implementó

- `whatsapp/flows/appointment-booking-static-v1.json` — Flow JSON v7.3 con 4 pantallas
- `supabase/functions/whatsapp-flow-send/index.ts` — Edge Function para enviar el Flow
- `supabase/config.toml` — añadido `[functions.whatsapp-flow-send] verify_jwt = false`
- `supabase/functions/whatsapp-webhook/index.ts` — extendido para reconocer y loguear nfm_reply
- `.env.example` — agregadas variables `META_GRAPH_API_VERSION` y `WHATSAPP_FLOW_ID`
- `tests/flow-create-draft.ps1` — crear Flow DRAFT en Meta
- `tests/flow-upload-json.ps1` — subir JSON con multipart/form-data
- `tests/flow-get-validation.ps1` — consultar errores de validación
- `tests/flow-publish.ps1` — publicar Flow (con confirmación manual)
- `tests/flow-get-status.ps1` — consultar ID y estado del Flow
- `tests/invoke-whatsapp-flow-send.ps1` — enviar Flow al teléfono
- `tests/test-nfm-reply-parse.ps1` — prueba unitaria sintética de nfm_reply
- `docs/producto/ALCANCE-MVP.md` — documentado Corte 3
- `docs/ux/FLUJO-WHATSAPP.md` — pantallas, transiciones y limitaciones del Flow

### Decisiones técnicas

**Flow JSON v7.3 sin data endpoint:**
Se elige el modo estático (sin `data_api_version` ni `data_channel_uri`) para eliminar
la necesidad de un endpoint HTTPS propio, cifrado RSA y validación de payload cifrado.
El trade-off es que el resumen en CONFIRMATION muestra IDs internos (ej. "haircut")
en lugar de etiquetas legibles. Se documenta como limitación conocida de este corte.

**Función `whatsapp-flow-send` separada de `whatsapp-send`:**
Ambas funciones envían mensajes distintos (template vs. interactive flow) y tienen
parámetros de request diferentes. Mantenerlas separadas respeta el principio de
responsabilidad única y evita acoplar la lógica de autenticación de Flow con la de
plantillas.

**`flow_id` resoluble por request O variable de entorno:**
El `flow_id` no se conoce hasta que Meta crea el Flow DRAFT. Se acepta en el body del
request (prioritario) con fallback a `WHATSAPP_FLOW_ID`. Esto permite pruebas antes de
configurar el env var en producción.

**`mode` como parámetro opcional (default "published"):**
Meta requiere `mode: "published"` para envíos reales pero `mode: "draft"` para probar
el Flow antes de publicarlo. Se expone como parámetro para permitir las dos fases.

**Extensión mínima del webhook:**
Se añade solo la rama `if (msg.type === "interactive")` en el loop existente.
La función `logInteractiveMessage` maneja tanto `nfm_reply` como otros tipos de
interactivos. No se modifica la lógica de verificación HMAC ni de statuses.

**Parseo defensivo de `response_json`:**
`response_json` llega como string JSON-embebido. Se parsea con try/catch y se valida
que sea un objeto (no null, no array). Solo se extraen las 5 claves esperadas; todas
las demás se ignoran silenciosamente. Nunca se loguea el JSON crudo.

**Scripts PS 5.1 para Flow management:**
`flow-upload-json.ps1` usa `[System.Net.Http.HttpClient]` + `MultipartFormDataContent`
(disponible en .NET 4.5+ que viene con PS 5.1) para construir el multipart correcto.
Los demás scripts usan `Invoke-RestMethod` que es más simple y suficiente para
llamadas GET y POST con JSON.

### Estado al cierre
- Implementado: ✅
- Flow validado con Meta: pendiente — requiere ejecutar flow-create-draft + flow-upload-json + flow-get-validation
- Flow publicado: pendiente — requiere aprobacion manual
- Validado en WhatsApp: pendiente — requiere Flow publicado y telefono autorizado
- Respuesta validada: pendiente — requiere completar el Flow en el telefono

---

## 2026-08-03 — Corte Vertical 4: Nucleo de datos multiempresa

### Que se implemento

- `supabase/migrations/20260803120000_create_booking_core.sql` — migracion completa
  - 9 tablas: businesses, business_members, services, extras, service_extras, business_hours, customers, appointments, appointment_extras
  - Funcion `set_updated_at()` con SECURITY INVOKER y search_path vacio
  - Funciones RLS helper `is_business_member` y `has_business_role` con SECURITY DEFINER
  - RLS habilitado en todas las tablas con politicas por rol
  - Triggers de updated_at en 6 tablas
  - 15 indices (incluyendo 2 unicos parciales)
  - CHECKs de consistencia cross-business en service_extras y appointment_extras
- `supabase/seed.sql` — seed idempotente con ON CONFLICT DO NOTHING
  - Negocio demo con UUID fijo `00000000-0000-0000-0000-000000000001`
  - 4 servicios con codigos sincronizados con Flow JSON (haircut, beard, haircut_beard, hair_dye)
  - 4 extras con codigos sincronizados con Flow JSON (wash, mask, beard_design, treatment)
  - 16 relaciones service_extras (todos los extras para todos los servicios)
  - 7 filas de business_hours (dom cerrado, lun-sab 09:00-19:00)
- `tests/booking-schema-smoke.sql` — 14 tests SQL con DO blocks aislados
- `docs/arquitectura/MODELO-DATOS.md` — modelo relacional completo con decisiones
- `docs/arquitectura/ARQUITECTURA.md` — arquitectura general del sistema

### Decisiones tecnicas

**Funciones RLS SECURITY DEFINER:**
Si las politicas de `business_members` llamaran a `is_business_member()`, que consulta `business_members`, habria recursion infinita. SECURITY DEFINER permite que la funcion consulte la tabla con privilegios del rol dueno, ignorando RLS dentro de la funcion.

**`(SELECT auth.uid())` como optimization fence:**
Usar `auth.uid()` directamente en una funcion STABLE puede causar que Postgres la invoque por cada fila. Envolviendo en `(SELECT ...)` se fuerza evaluacion unica por consulta.

**CHECKs en lugar de triggers para cross-business:**
Un CHECK CONSTRAINT que subconsulta la tabla padre es suficiente porque `business_id` no cambia en operaciones normales. Es mas simple que un trigger y se evalua atomicamente con el INSERT/UPDATE.

**Indice parcial para external_reference:**
`WHERE external_reference IS NOT NULL` permite que multiples citas tengan `external_reference = NULL` sin violar el unique. Solo se indexan los valores no nulos, que son los que necesitan ser unicos por negocio (para idempotencia en Corte 5).

**UUIDs fijos en seed:**
Permiten referencias reproducibles en tests y seeds adicionales sin necesidad de buscar IDs con SELECT. Patron nillike: `00000000-0000-0000-XXXX-000000000YYY`.

**ON DELETE RESTRICT como regla general:**
Protege datos historicos (no borrar servicio si tiene citas, no borrar cliente si tiene citas). CASCADE solo en relaciones de configuracion propia (business_hours, service_extras). SET NULL en created_by para preservar citas cuando el admin desaparece.

**Seed sin usuarios ni citas:**
El seed solo incluye catalogo (negocio, servicios, extras, horarios). Usuarios y citas se crean en pruebas o en produccion real. No mezclar datos de catalogo con datos transaccionales en el seed.

### Estado al cierre
- Implementado: ✅
- Validado localmente (supabase db reset + smoke tests): pendiente — requiere Docker y supabase start
- Validado en produccion (supabase db push): pendiente — requiere autorizacion del usuario

---

## 2026-08-04 — Corte Vertical 5: Persistencia de Flow Responses como citas

### Que se implemento

- `supabase/migrations/20260804120000_add_whatsapp_booking_ingestion.sql`
  - Tabla `whatsapp_channels` con RLS (sin DELETE, status='inactive')
  - RPC `create_whatsapp_flow_appointment` (SECURITY DEFINER, solo service_role)
    - 8 pasos: normalización → canal → timezone → advisory lock → idempotencia → negocio → horario → escritura
    - Upsert customer (display_name preserva valor existente si nuevo es NULL)
    - INSERT appointment (status=pending, source=whatsapp_flow) + appointment_extras
    - Retorna created_new: true/false para log en el webhook
- `supabase/seed.sql` — canal sintético `phone_number_id='000000000000002'` agregado
- `supabase/functions/_shared/supabase-client.ts` — cliente service_role con soporte SUPABASE_SECRET_KEYS
- `supabase/functions/whatsapp-webhook/index.ts` — extendido con `processFlowResponse`
  - `normalizeToE164`: acepta números sin '+' (comportamiento de Meta)
  - Timeout de 8s con `Promise.race`; errores P0001 → HTTP 200; timeout → HTTP 500
  - `logInteractiveMessage` preservada para interactivos no-nfm_reply
- `tests/booking-ingestion-smoke.sql` — 26 tests T01-T26
- `tests/test-whatsapp-booking-webhook.ps1` — integración con webhook local
- `tests/test-booking-idempotency-concurrency.ps1` — dos jobs paralelos + verificación BD

### Decisiones tecnicas

**pg_advisory_xact_lock para concurrencia:**
Antes del re-check de idempotencia, se adquiere un lock de transacción cuya clave es un hash de `business_id + external_reference`. Esto garantiza que dos llamadas concurrentes con los mismos parámetros serialicen, evitando que ambas superen el re-check y creen dos citas.

**HTTP 200 para errores de negocio P0001:**
Meta interpreta HTTP 5xx como error transitorio y reintenta. Los errores de negocio (servicio inactivo, horario cerrado, etc.) son permanentes; devolver 200 evita reintentos infinitos. Solo se devuelve 500 ante timeout de BD o error de conexión (verdadero problema transitorio).

**normalizeToE164 en el webhook:**
Meta puede omitir el '+' en `msg.from`. La normalización ocurre antes de llamar la RPC, que recibe siempre un número E.164 válido. El constraint `CHECK (whatsapp_phone_e164 ~ '^\+[1-9]\d{7,14}$')` en `customers` actúa como última línea de defensa.

**Validación de timezone en la RPC:**
Si `businesses.timezone` tiene un valor incorrecto, la conversión AT TIME ZONE fallaría con un error de PostgreSQL (no P0001), que el webhook interpretaría como HTTP 500 y Meta reintentaría indefinidamente. La validación explícita contra `pg_timezone_names` convierte este error en P0001 → HTTP 200 (sin reintentos).

**`_shared/supabase-client.ts`:**
Centraliza la inicialización del cliente service_role. Prioriza `SUPABASE_SECRET_KEYS` (formato JSON, inyectado por Supabase Runtime v2) con fallback a `SUPABASE_SERVICE_ROLE_KEY` (legacy / local). Nunca imprime el contenido de las variables de entorno.

### Decisiones que afectan Corte 6

| Decision | Impacto |
|----------|---------|
| `external_reference = msg.id` | Corte 6 agrega `calendar_event_id` nullable; no reutilizar este campo |
| `status = 'pending'` | Corte 6 hace UPDATE a 'confirmed' tras crear evento en Calendar |
| La RPC no retorna `customer_id` | Corte 6 lo obtiene via JOIN a appointments |
| Sin validacion de solapamiento | Corte 6 verifica disponibilidad con Calendar como fuente de verdad |

### Estado al cierre
- Implementado: ✅
- Validado localmente: pendiente — requiere Docker y supabase start
- Validado en produccion: pendiente — requiere autorizacion del usuario

---

## 2026-08-03 — Corte 4, rev 2: corrección de CHECK con subquery → FK compuestas

### Problema detectado

PostgreSQL no permite subqueries dentro de CHECK constraints definidos en la tabla (`ALTER TABLE ... ADD CONSTRAINT ... CHECK (SELECT ...)`). La migración original usaba ese patron en tres lugares:

- `service_extras_same_business` en `service_extras`
- `appointments_customer_same_business` y `appointments_service_same_business` en `appointments`
- `appointment_extras_same_business` en `appointment_extras`

### Solución: foreign keys compuestas

La consistencia cross-business se garantiza de forma estructural mediante FK compuestas:

1. Se agregaron constraints `UNIQUE (id, business_id)` en las tablas padre:
   - `services_id_business_id_key` en `services`
   - `extras_id_business_id_key` en `extras`
   - `customers_id_business_id_key` en `customers`
   - `appointments_id_business_id_key` en `appointments`

2. `service_extras` recibio columna `business_id NOT NULL` y PK cambiada a `(business_id, service_id, extra_id)`:
   - FK compuesta `(service_id, business_id) → services(id, business_id)` ON DELETE CASCADE
   - FK compuesta `(extra_id, business_id)   → extras(id, business_id)`   ON DELETE CASCADE

3. `appointments` reemplaza FKs simples de `customer_id` y `service_id` por FKs compuestas:
   - FK `(customer_id, business_id) → customers(id, business_id)` ON DELETE RESTRICT
   - FK `(service_id, business_id)  → services(id, business_id)`  ON DELETE RESTRICT
   - Se eliminaron los dos CHECK con subquery

4. `appointment_extras` recibio columna `business_id NOT NULL` y PK cambiada a `(business_id, appointment_id, extra_id)`:
   - FK compuesta `(appointment_id, business_id) → appointments(id, business_id)` ON DELETE CASCADE
   - FK compuesta `(extra_id, business_id)       → extras(id, business_id)`       ON DELETE RESTRICT

### Mejoras adicionales en la misma revision

**REVOKE/GRANT en helpers RLS:**
- `REVOKE EXECUTE FROM PUBLIC` y `FROM anon` en `is_business_member` y `has_business_role`
- `GRANT EXECUTE TO authenticated` solamente
- Impide invocacion directa desde clientes no autenticados

**Politicas business_members endurecidas:**
- INSERT: admin solo puede agregar `staff`; no puede crear owners ni admins
- UPDATE (USING): admin solo puede modificar filas cuyo `role` actual sea `staff`
- UPDATE (WITH CHECK): admin solo puede asignar `role='staff'`; owner no puede degradar si queda como unico owner
- DELETE: admin solo puede eliminar `staff`; no puede eliminar el ultimo owner

**RLS service_extras y appointment_extras simplificado:**
- Antes: subquery para obtener `business_id` desde la tabla padre
- Ahora: uso directo de la columna `business_id` de la misma tabla

**Seed actualizado:**
- `service_extras` ahora incluye `business_id` en el INSERT (parte de la nueva PK)
- `ON CONFLICT (business_id, service_id, extra_id) DO NOTHING`

**Smoke tests actualizados:**
- Test 05: `service_extras` ahora espera `foreign_key_violation` en lugar de `check_violation`
- Test 15 (nuevo): appointment con servicio de negocio distinto → `foreign_key_violation`
- Test 16 (nuevo): verifica que las 4 tablas padre tienen UNIQUE(id, business_id)
- Total: 14 → 16 tests

### Archivos modificados
- `supabase/migrations/20260803120000_create_booking_core.sql` — reescritura completa
- `supabase/seed.sql` — business_id en service_extras
- `tests/booking-schema-smoke.sql` — 16 tests, FK compuesta
- `docs/arquitectura/MODELO-DATOS.md` — tablas, FK compuestas, RLS
- `docs/arquitectura/ARQUITECTURA.md` — decision cross-business
- `CLAUDE.md` — scope Corte 4 actualizado

---

## 2026-08-03 — Corte 4, rev 3: auditoria de seguridad RLS + tests de escalada de privilegios

### Contexto

Tras pasar 16 smoke tests con `supabase db reset --local`, se realizo una auditoria de seguridad enfocada en las politicas RLS de `business_members` antes del despliegue a produccion.

### Problema detectado: funcion creada antes que la tabla referenciada

Al ejecutar `supabase start` se produjo:

```
ERROR: relation "public.business_members" does not exist
```

Causa: `LANGUAGE sql` valida el cuerpo de la funcion en tiempo de creacion. `is_business_member` referenciaba `business_members` antes de que la tabla existiera en el archivo de migracion.

**Solucion**: reestructuracion en 8 secciones estrictas:
1. `set_updated_at` (funcion sin dependencias de tabla)
2. `CREATE TABLE x9` (todas las tablas primero)
3. Constraints, FK compuestas, indices (en ALTER TABLE separados)
4. Funciones helper RLS (despues de que `business_members` existe)
5. REVOKE/GRANT
6. ENABLE ROW LEVEL SECURITY
7. CREATE POLICY
8. CREATE TRIGGER

### Auditoria de seguridad: business_members

| Regla | Mecanismo | Verificado |
|-------|-----------|------------|
| Admin no puede insertar owner/admin | `WITH CHECK (role = 'staff' OR has_business_role([owner]))` | T18, T19 |
| Admin no puede modificar fila de owner/admin | `USING (role = 'staff' OR has_business_role([owner]))` | T20 |
| Admin no puede promover staff → owner/admin | `WITH CHECK (role = 'staff' OR ...)` | T21 |
| Ultimo owner no puede eliminarse | `NOT (role='owner' AND COUNT(owners)<=1)` en USING | T22 |
| Ultimo owner no puede degradarse | `COUNT(owners)>1 OR role='owner'` en WITH CHECK | T23 |
| Owner puede agregar admin (positivo) | politica normal sin restriccion de rol destino | T24 |

### Proteccion del ultimo owner

Implementada en dos politicas:

**DELETE USING:**
```sql
AND NOT (
  role = 'owner'
  AND (SELECT count(*) FROM public.business_members bm2
       WHERE bm2.business_id = business_members.business_id
         AND bm2.role = 'owner') <= 1
)
```

**UPDATE WITH CHECK:**
```sql
AND (
  role = 'owner'
  OR (SELECT count(*) FROM public.business_members bm2
      WHERE bm2.business_id = business_members.business_id
        AND bm2.role = 'owner') > 1
)
```

RLS silencia DML bloqueado (0 filas afectadas, sin error). Los tests verifican con `GET DIAGNOSTICS v_rows = ROW_COUNT` y comparacion de conteo antes/despues.

### Tests agregados: T17-T25

- **T17**: Setup — crea negocio de prueba, 4 auth.users sinteticos, 3 miembros (owner, admin, staff) con UUIDs `cc00`
- **T18**: admin no puede insertar owner → conteo de owners sin cambio
- **T19**: admin no puede insertar admin → conteo de admins sin cambio
- **T20**: admin no puede actualizar fila de owner → `GET DIAGNOSTICS = 0`
- **T21**: admin no puede promover staff → owner → rol sigue siendo 'staff'
- **T22**: ultimo owner no puede eliminarse → fila sigue existiendo
- **T23**: ultimo owner no puede degradarse → rol sigue siendo 'owner'
- **T24**: owner puede agregar admin (positivo) → fila existe luego del INSERT
- **T25**: Teardown — elimina todos los datos `cc00`, verifica 0 filas residuales

### Total final de smoke tests: 16 + 9 = 25

### Validacion local confirmada

`supabase db reset --local` + `psql -f tests/booking-schema-smoke.sql`: **25 PASS, 0 FAIL**

### Archivos modificados
- `supabase/migrations/20260803120000_create_booking_core.sql` — seccion 8 estricta, politicas endurecidas
- `tests/booking-schema-smoke.sql` — 25 tests (T01-T25)
- `docs/progreso/ESTADO-ACTUAL.md` — 25 tests, validacion local ✅
- `docs/progreso/BITACORA.md` — esta entrada
