# CLAUDE.md

## Objetivo del MVP

Agente de WhatsApp para gestión de citas: recibe mensajes de clientes, agenda en Google Calendar y confirma por WhatsApp. Sin panel web en esta fase.

## Stack

- **Edge Functions:** Supabase (Deno / TypeScript)
- **Mensajería:** WhatsApp Business Cloud API (Meta Graph API)
- **Calendario:** Google Calendar API (fuera de alcance — Corte 1)
- **CLI:** Supabase CLI

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

## Próximos módulos (fuera de alcance ahora)

- Corte 3: Integración Google Calendar
- Base de datos / migraciones Supabase
- Panel administrativo
- Lógica de fidelización
- WhatsApp Flows / Embedded Signup
