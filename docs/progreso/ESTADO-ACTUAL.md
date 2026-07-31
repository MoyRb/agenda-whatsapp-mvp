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

## Funciones Edge

| Función | Ruta | Auth | Implementado | Validado |
|---------|------|------|:---:|:---:|
| `whatsapp-send` | `supabase/functions/whatsapp-send/index.ts` | `x-internal-secret` | ✅ | ✅ |
| `whatsapp-webhook` | `supabase/functions/whatsapp-webhook/index.ts` | HMAC-SHA256 / verify_token | ✅ | ✅ |

---

## Próximos pasos

- [x] Corte 2: Webhook de entrada WhatsApp (verificación HMAC + recepción)
- [x] Validación sintética Corte 2 (4 tests PowerShell)
- [x] Validación con Meta (Callback URL + mensaje real)
- [ ] Corte 3: Integración Google Calendar
- [ ] Base de datos / migraciones
- [ ] Panel administrativo
