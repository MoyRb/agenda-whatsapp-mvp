# CLAUDE.md

## Objetivo del MVP

Agente de WhatsApp para gestión de citas: recibe mensajes de clientes, agenda en Google Calendar y confirma por WhatsApp. Sin panel web en esta fase.

## Stack

- **Edge Functions:** Supabase (Deno / TypeScript)
- **Mensajería:** WhatsApp Business Cloud API (Meta Graph API)
- **Calendario:** Google Calendar API (fuera de alcance — Corte 1)
- **CLI:** Supabase CLI

## Alcance del Corte Vertical 5

Webhook conectado a BD — sin Google Calendar ni respuesta al cliente.

- Migración `whatsapp_channels` + RPC `create_whatsapp_flow_appointment` (SECURITY DEFINER, solo service_role)
- Idempotencia: `pg_advisory_xact_lock(hashtextextended(bid||':'||ref, 0))` + unique index `(business_id, external_reference)`
- Webhook extendido: nfm_reply → normalizar teléfono → timeout 8s → RPC → log sanitizado
- HTTP 200 para errores de negocio P0001; HTTP 500 solo para timeout / error de conexión BD
- Módulo compartido `_shared/supabase-client.ts` (SUPABASE_SECRET_KEYS → SUPABASE_SERVICE_ROLE_KEY)
- 26 smoke tests SQL T01-T26; test-whatsapp-booking-webhook.ps1; test-booking-idempotency-concurrency.ps1

## Alcance del Corte Vertical 4

Capa de persistencia en Supabase/PostgreSQL — sin conexion a Edge Functions aun.

- Migracion: 9 tablas con RLS multiempresa, indices, FK compuestas para consistencia cross-business
- Funciones helper RLS SECURITY DEFINER (REVOKE PUBLIC/anon, GRANT authenticated)
- business_members: politicas endurecidas — admin no puede escalar privilegios ni afectar owners; proteccion ultimo owner
- Seed idempotente con negocio demo y UUIDs fijos sincronizados con el Flow JSON
- 25 smoke tests SQL: T01-T16 constraints/FK/seed + T17-T25 escalada de privilegios RLS
- Sin panel web, sin Google Calendar, sin conexion BD↔Edge Functions

## Alcance del Corte Vertical 3

Funciones implementadas: `whatsapp-flow-send` + webhook extendido

- Flow JSON v7.3 con 4 pantallas: SERVICE → EXTRAS → SCHEDULE → CONFIRMATION
- Edge Function `whatsapp-flow-send` envía el formulario interactivo (tipo "flow")
- Webhook extendido detecta y loguea respuestas `nfm_reply` de forma sanitizada
- Sin base de datos, sin Google Calendar, sin disponibilidad dinámica, sin data endpoint

## Alcance del Corte Vertical 2

Función implementada: `whatsapp-webhook`

- Verificación del handshake de Meta (GET con `hub.verify_token`)
- Recepción y validación HMAC-SHA256 de eventos POST
- Logs sanitizados de mensajes y estados (sin contenido sensible)
- Sin responder mensajes, sin base de datos, sin llamar a otras funciones

## Alcance del Corte Vertical 1

Única función implementada: `whatsapp-send`

- Envía la plantilla `hello_world` a un número E.164 dado
- Protegida con `x-internal-secret` (no JWT)
- Sin base de datos, sin webhook, sin calendario

## Prohibiciones absolutas

1. **No leer, abrir, imprimir ni modificar** archivos de secretos reales:
   `.env`, `.env.local`, `supabase/.env.local`, o cualquier archivo que contenga valores reales de tokens o claves.
   Los nombres de variables se toman únicamente de `.env.example`.

2. **No hacer commit ni push** sin autorización explícita del usuario en esa sesión.

3. **No declarar una tarea como terminada** solo porque compile.
   - `Implementado` = código + documentación + script creados.
   - `Validado` = script desplegado retorna `message_id` y el mensaje llega al teléfono.

4. **No loguear** tokens, secrets, headers completos ni payloads con secretos.

## Comandos

### Desarrollo local
```bash
supabase functions serve whatsapp-send --env-file ./supabase/.env.local
```
> `verify_jwt = false` está configurado en `supabase/config.toml` — no usar `--no-verify-jwt`.

### Deploy
```bash
supabase functions deploy whatsapp-send --project-ref <PROJECT_REF>
```

### Cargar secrets en producción
```bash
supabase secrets set --env-file ./supabase/.env.local --project-ref <PROJECT_REF>
```

### Prueba — whatsapp-send
```powershell
# Requiere la variable de entorno definida en la sesión
$env:INTERNAL_FUNCTION_SECRET = "tu-secret"
.\tests\invoke-whatsapp-send.ps1 -Phone "+521234567890"
```

### Desarrollo local — webhook
```bash
supabase functions serve whatsapp-webhook --env-file ./supabase/.env.local
```

### Prueba — whatsapp-webhook
```powershell
$env:WHATSAPP_VERIFY_TOKEN = "tu-verify-token"
$env:META_APP_SECRET = "tu-app-secret"
.\tests\invoke-whatsapp-webhook.ps1 -Test get-valid
.\tests\invoke-whatsapp-webhook.ps1 -Test get-invalid
.\tests\invoke-whatsapp-webhook.ps1 -Test post-valid
.\tests\invoke-whatsapp-webhook.ps1 -Test post-invalid
```

### Desarrollo local — whatsapp-flow-send
```bash
supabase functions serve whatsapp-flow-send --env-file ./supabase/.env.local
```

### Prueba — whatsapp-flow-send
```powershell
$env:INTERNAL_FUNCTION_SECRET = "tu-secret"
$env:WHATSAPP_FLOW_ID         = "id-del-flow-creado"
.\tests\invoke-whatsapp-flow-send.ps1 -Phone "+52XXXXXXXXXX"
# Con Flow aun en DRAFT (antes de publicar):
.\tests\invoke-whatsapp-flow-send.ps1 -Phone "+52XXXXXXXXXX" -Mode draft
```

### Gestión del Flow en Meta
```powershell
# 1. Crear Flow DRAFT
$env:WHATSAPP_ACCESS_TOKEN        = "tu-token"
$env:WHATSAPP_BUSINESS_ACCOUNT_ID = "tu-waba-id"
$env:META_GRAPH_API_VERSION       = "v20.0"
.\tests\flow-create-draft.ps1 -Name "Reservacion de cita"

# 2. Subir JSON
.\tests\flow-upload-json.ps1 -FlowId <ID> -FilePath "whatsapp\flows\appointment-booking-static-v1.json"

# 3. Consultar errores de validación
.\tests\flow-get-validation.ps1 -FlowId <ID>

# 4. Publicar (solo después de revisión manual; acción irreversible)
.\tests\flow-publish.ps1 -FlowId <ID>

# 5. Consultar estado
.\tests\flow-get-status.ps1 -FlowId <ID>
```

### Prueba unitaria sintética — nfm_reply
```powershell
# El webhook debe estar corriendo con supabase functions serve
$env:META_APP_SECRET = "tu-app-secret"
.\tests\test-nfm-reply-parse.ps1
# Revisar consola del servidor: debe aparecer type="flow_response"
```

### Migraciones locales (Corte 4+)
```bash
# Requiere Docker corriendo: supabase start
supabase db reset --local          # aplica migraciones + seed desde cero
supabase migration new <nombre>    # crear nueva migración vacía
```

### Smoke tests de esquema (Corte 4)
```bash
# Requiere supabase start + supabase db reset --local previos
psql postgresql://postgres:postgres@localhost:54322/postgres \
  -f tests/booking-schema-smoke.sql
```

### Smoke tests de ingestión (Corte 5)
```bash
# Requiere supabase start + supabase db reset --local previos
psql postgresql://postgres:postgres@localhost:54322/postgres \
  -f tests/booking-ingestion-smoke.sql
```

### Prueba de integración — Corte 5 (webhook → BD)
```powershell
# El webhook debe estar corriendo con supabase functions serve
$env:META_APP_SECRET = "tu-app-secret"
.\tests\test-whatsapp-booking-webhook.ps1
# Con idempotencia (mismo external_reference):
.\tests\test-whatsapp-booking-webhook.ps1 -Duplicate
```

### Prueba de concurrencia — Corte 5
```powershell
$env:META_APP_SECRET = "tu-app-secret"
.\tests\test-booking-idempotency-concurrency.ps1
# Esperado: 2 HTTP 200, exactamente 1 cita, 1 customer, 1 appointment_extra
```

### Deploy de migraciones a producción
```bash
# Requiere autorización explícita del usuario
supabase db push --project-ref <PROJECT_REF>
```

## Variables de entorno requeridas

Definir en `supabase/.env.local` (local) y via `supabase secrets set` (producción):

| Variable | Obligatoria | Descripción |
|----------|-------------|-------------|
| `INTERNAL_FUNCTION_SECRET` | Sí | Min 16 chars. Auth de llamadas internas |
| `WHATSAPP_ACCESS_TOKEN` | Sí | Token de Meta Graph API |
| `WHATSAPP_PHONE_NUMBER_ID` | Sí | ID del número WhatsApp Business |
| `META_GRAPH_API_VERSION` | Sí | Ej. `v19.0`. Sin fallback — obligatorio |
| `WHATSAPP_VERIFY_TOKEN` | No (Corte 2) | Para verificación del webhook |
| `META_APP_SECRET` | No (Corte 2) | Para firma HMAC del webhook |
| `META_GRAPH_API_VERSION` | Sí | Ej. `v20.0`. Sin fallback — obligatorio |
| `WHATSAPP_FLOW_ID` | No (Corte 3) | ID del Flow publicado en Meta. Puede pasarse en el request |
| `SUPABASE_URL` | Sí (Corte 5) | URL del proyecto Supabase (inyectado automáticamente en Runtime) |
| `SUPABASE_SERVICE_ROLE_KEY` | Sí (Corte 5) | Clave service_role — alternativa a SUPABASE_SECRET_KEYS |
| `SUPABASE_SECRET_KEYS` | No (Corte 5) | JSON `{"default":"..."}` inyectado por Supabase Runtime v2 (preferido) |

## Próximos módulos (fuera de alcance ahora)

- Corte 6: Google Calendar + confirmación automática al cliente
- Panel administrativo
- Lógica de fidelización
- WhatsApp Flows con endpoint dinámico / Embedded Signup
- Prevención de horarios duplicados (solapamiento de citas)
