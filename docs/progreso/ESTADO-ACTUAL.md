# Estado Actual del Proyecto

## Corte Vertical 1 — whatsapp-send

| Campo | Detalle |
|-------|---------|
| Fecha implementación | 2026-07-30 |
| Fecha validación | 2026-07-31 |
| Función | `whatsapp-send` |
| Estado | **Validado** |

### Criterio de finalización

- **Implementado:** código + documentación + script creados. ✅
- **Validado:** script retorna `message_id` y el mensaje `hello_world` llega al teléfono. ✅

---

## Corte Vertical 2 — whatsapp-webhook

| Campo | Detalle |
|-------|---------|
| Fecha implementación | 2026-07-31 |
| Fecha validación | 2026-07-31 |
| Función | `whatsapp-webhook` |
| Estado | **Validado con Meta** |

### Criterio de finalización

- **Implementado:** código + config + script + docs creados. ✅
- **Validado sintéticamente:** los 4 tests del script pasan contra función local o desplegada. ✅
- **Validado con Meta:** Meta acepta Callback URL + Verify Token y entrega POST real. ✅

---

---

## Corte Vertical 3 — WhatsApp Flow estático

| Campo | Detalle |
|-------|---------|
| Fecha implementación | 2026-07-31 |
| Fecha validación | — |
| Función | `whatsapp-flow-send` + webhook extendido |
| Estado | **Implementado** |

### Criterio de finalización

- **Implementado:** Flow JSON + función + scripts + docs creados. ✅
- **Flow validado:** Meta acepta el Flow JSON sin errores. ⬜
- **Flow publicado:** el Flow cambia correctamente a estado publicado. ⬜
- **Validado en WhatsApp:** el formulario abre en el teléfono y puede completarse. ⬜
- **Respuesta validada:** nfm_reply llega al webhook y se registra sanitizado. ⬜

---

## Corte Vertical 4 — Nucleo de datos multiempresa

| Campo | Detalle |
|-------|---------|
| Fecha implementacion | 2026-08-03 |
| Fecha validacion local | 2026-08-03 |
| Estado | **Validado localmente** |

### Criterio de finalizacion

- **Implementado:** migracion + seed + smoke tests + documentacion creados. ✅
- **Validado localmente:** `supabase db reset --local` aplica sin errores y smoke tests pasan. ✅
- **Validado en produccion:** `supabase db push` aplicado con autorizacion del usuario. ⬜

### Archivos creados

| Archivo | Descripcion |
|---------|-------------|
| `supabase/migrations/20260803120000_create_booking_core.sql` | Migracion: 9 tablas, RLS, indices, triggers |
| `supabase/seed.sql` | Seed idempotente con negocio demo |
| `tests/booking-schema-smoke.sql` | 25 smoke tests SQL (T01-T16 constraints + T17-T25 RLS/privilegios) |
| `docs/arquitectura/MODELO-DATOS.md` | Modelo relacional completo |
| `docs/arquitectura/ARQUITECTURA.md` | Arquitectura del sistema |

---

## Corte Vertical 5 — Persistencia de Flow Responses

| Campo | Detalle |
|-------|---------|
| Fecha implementacion | 2026-08-04 |
| Fecha validacion local | pendiente — requiere Docker + supabase start |
| Estado | **Implementado** |

### Criterio de finalizacion

- **Implementado:** migracion + seed + shared client + webhook + smoke tests + scripts creados. ✅
- **Validado localmente:** `supabase db reset --local` + 26 smoke tests PASS + test-whatsapp-booking-webhook.ps1 HTTP 200. ⬜
- **Validado en produccion:** `supabase db push` + despliegue del webhook actualizado. ⬜

### Archivos creados / modificados

| Archivo | Descripcion |
|---------|-------------|
| `supabase/migrations/20260804120000_add_whatsapp_booking_ingestion.sql` | Tabla whatsapp_channels + RPC |
| `supabase/seed.sql` | Canal WhatsApp sintetico agregado |
| `supabase/functions/_shared/supabase-client.ts` | Cliente Supabase service_role (nuevo) |
| `supabase/functions/whatsapp-webhook/index.ts` | Extendido: nfm_reply → RPC → BD |
| `tests/booking-ingestion-smoke.sql` | 26 smoke tests SQL (T01-T26) |
| `tests/test-whatsapp-booking-webhook.ps1` | Test de integracion con webhook local |
| `tests/test-booking-idempotency-concurrency.ps1` | Test de idempotencia bajo concurrencia |

---

## Funciones Edge

| Función | Ruta | Auth | Implementado | Validado |
|---------|------|------|:---:|:---:|
| `whatsapp-send` | `supabase/functions/whatsapp-send/index.ts` | `x-internal-secret` | ✅ | ✅ |
| `whatsapp-webhook` | `supabase/functions/whatsapp-webhook/index.ts` | HMAC-SHA256 / verify_token | ✅ | ✅ |
| `whatsapp-flow-send` | `supabase/functions/whatsapp-flow-send/index.ts` | `x-internal-secret` | ✅ | ⬜ |
| `google-oauth-start` | `supabase/functions/google-oauth-start/index.ts` | `x-internal-secret` | ✅ | ⬜ |
| `google-oauth-callback` | `supabase/functions/google-oauth-callback/index.ts` | HMAC-SHA256 state | ✅ | ⬜ |
| `google-calendar-sync` | `supabase/functions/google-calendar-sync/index.ts` | `x-internal-secret` | ✅ | ⬜ |

---

---

## Corte Vertical 6 — Google Calendar Sync

| Campo | Detalle |
|-------|---------|
| Fecha implementacion | 2026-08-05 |
| Fecha validacion local | pendiente |
| Estado | **Implementado** |

### Criterio de finalizacion

- **Implementado:** migracion + shared module + 3 Edge Functions + smoke tests + scripts. ✅
- **Validado localmente:** `supabase db reset --local` + 27 smoke tests SQL PASS + test-google-calendar-sync.ps1 + test-google-oauth-flow.ps1. ⬜
- **Validado end-to-end:** OAuth con cuenta Google real + booking via WhatsApp + evento en Calendar. ⬜

### Archivos creados / modificados

| Archivo | Descripcion |
|---------|-------------|
| `supabase/migrations/20260805120000_add_google_calendar_sync.sql` | 3 tablas, trigger outbox, 10 RPCs, índices, RLS |
| `supabase/functions/_shared/google-calendar.ts` | Helpers reutilizables: refresh, insert/get event, classify |
| `supabase/functions/google-oauth-start/index.ts` | Genera URL OAuth (requiere x-internal-secret) |
| `supabase/functions/google-oauth-callback/index.ts` | Callback OAuth público, valida HMAC, guarda conexión |
| `supabase/functions/google-calendar-sync/index.ts` | Worker de sync (requiere x-internal-secret) |
| `supabase/functions/whatsapp-webhook/index.ts` | Modificado: fire-and-forget EdgeRuntime.waitUntil |
| `supabase/config.toml` | 3 nuevas entradas [functions.*] verify_jwt=false |
| `.env.example` | Valores vaciados + 4 vars nuevas de Google + nota de rotación |
| `tests/calendar-sync-smoke.sql` | 27 smoke tests SQL (T01-T27) |
| `tests/test-google-calendar-sync.ps1` | TC01-TC21 con verificacion de BD |
| `tests/test-google-oauth-flow.ps1` | TO01-TO09 con verificacion de state HMAC |

---

## Proximos pasos

- [x] Corte 2: Webhook de entrada WhatsApp (verificacion HMAC + recepcion)
- [x] Validacion sintetica Corte 2 (4 tests PowerShell)
- [x] Validacion con Meta (Callback URL + mensaje real)
- [x] Corte 3: WhatsApp Flow estatico de reservacion (implementado)
- [ ] Corte 3: Validar Flow JSON con Meta (flow-get-validation.ps1)
- [ ] Corte 3: Publicar Flow y enviar a telefono
- [ ] Corte 3: Confirmar nfm_reply en webhook
- [x] Corte 4: Nucleo de datos multiempresa (implementado)
- [x] Corte 4: Validado localmente (supabase db reset + 25 smoke tests PASS)
- [x] Corte 5: Webhook → RPC → BD (implementado)
- [ ] Corte 5: Validar localmente (supabase db reset + 26 smoke tests + test-whatsapp-booking-webhook.ps1)
- [ ] Corte 5: Desplegar a produccion (supabase db push + functions deploy)
- [x] Corte 6: Google Calendar + confirmacion al cliente (implementado)
- [ ] Corte 6: Validar localmente (supabase db reset + 27 smoke tests SQL + PowerShell)
- [ ] Corte 6: Validar end-to-end con cuenta Google real
- [ ] Corte 6: Desplegar a produccion
