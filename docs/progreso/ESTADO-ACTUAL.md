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

## Funciones Edge

| Función | Ruta | Auth | Implementado | Validado |
|---------|------|------|:---:|:---:|
| `whatsapp-send` | `supabase/functions/whatsapp-send/index.ts` | `x-internal-secret` | ✅ | ✅ |
| `whatsapp-webhook` | `supabase/functions/whatsapp-webhook/index.ts` | HMAC-SHA256 / verify_token | ✅ | ✅ |
| `whatsapp-flow-send` | `supabase/functions/whatsapp-flow-send/index.ts` | `x-internal-secret` | ✅ | ⬜ |

---

## Próximos pasos

- [x] Corte 2: Webhook de entrada WhatsApp (verificación HMAC + recepción)
- [x] Validación sintética Corte 2 (4 tests PowerShell)
- [x] Validación con Meta (Callback URL + mensaje real)
- [x] Corte 3: WhatsApp Flow estático de reservación (implementado)
- [ ] Corte 3: Validar Flow JSON con Meta (flow-get-validation.ps1)
- [ ] Corte 3: Publicar Flow y enviar a teléfono
- [ ] Corte 3: Confirmar nfm_reply en webhook
- [ ] Base de datos / migraciones
- [ ] Panel administrativo
