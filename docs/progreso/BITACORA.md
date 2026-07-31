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
