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
