# Arquitectura del Sistema

## Vision general

Agente de WhatsApp para gestion de citas: recibe mensajes de clientes via WhatsApp Business API, persiste datos en Supabase/PostgreSQL, agenda en Google Calendar y confirma por WhatsApp. Sin panel web en esta fase.

```
Cliente WhatsApp
      |
      v
Meta Graph API
      |
      v
Supabase Edge Functions (Deno / TypeScript)
  ├─ whatsapp-send          [Corte 1 — validado]
  ├─ whatsapp-webhook       [Corte 2 — validado]
  ├─ whatsapp-flow-send     [Corte 3 — implementado]
  └─ (booking-create)       [Corte 5 — pendiente]
      |
      v
Supabase PostgreSQL (RLS multiempresa)  [Corte 4 — implementado]
      |
      v
Google Calendar API                     [Corte 5+ — pendiente]
```

---

## Edge Functions

| Funcion | Auth | Descripcion |
|---------|------|-------------|
| `whatsapp-send` | `x-internal-secret` | Envia plantilla hello_world |
| `whatsapp-webhook` | HMAC-SHA256 / verify_token | Recibe y valida eventos de Meta |
| `whatsapp-flow-send` | `x-internal-secret` | Envia formulario interactivo (Flow) |

Todas las funciones tienen `verify_jwt = false` en `supabase/config.toml`.

---

## Base de datos

Ver [MODELO-DATOS.md](MODELO-DATOS.md) para el modelo relacional completo.

### Esquema: 9 tablas

```
businesses → business_members, services, extras, business_hours, customers, appointments
services   → service_extras, appointments
extras     → service_extras, appointment_extras
customers  → appointments
appointments → appointment_extras
```

### Estrategia RLS

- Funciones helper `SECURITY DEFINER`: `is_business_member`, `has_business_role`
- Patron: todos los miembros leen; owner/admin modifican catalogo; owner/admin/staff gestionan citas
- `service_role` bypasses RLS — Edge Functions deben validar `business_id` explicitamente

---

## Flujo de mensajes (futuro — Corte 5+)

```
1. Cliente envia mensaje a WhatsApp Business
2. Meta entrega POST al webhook (whatsapp-webhook)
3. Webhook valida HMAC, detecta tipo de mensaje
4. Si es nfm_reply (respuesta de Flow):
   a. Parsea response_json
   b. Llama a booking-create (Edge Function interna)
   c. booking-create inserta en appointments con service_role
   d. Responde al cliente via whatsapp-send
```

---

## Decisiones de arquitectura clave

**Sin JWT en Edge Functions publicas:**
Las funciones que reciben de Meta o son llamadas internamente usan `x-internal-secret` o HMAC-SHA256, no JWT de Supabase. Esto es correcto porque Meta no puede obtener un JWT.

**Multiempresa desde el inicio:**
Todas las tablas tienen `business_id`. El modelo soporta multiples negocios sin cambios de esquema. El seed incluye un negocio demo con UUID fijo para reproducibilidad en tests.

**FK compuestas para consistencia cross-business:**
PostgreSQL no permite subqueries en CHECK constraints de tabla. La consistencia se garantiza con foreign keys compuestas: `service_extras`, `appointments` y `appointment_extras` incluyen `business_id` en sus FK, que referencian constraints UNIQUE(id, business_id) en las tablas padre. Un intento de mezclar entidades de negocios distintos produce `foreign_key_violation`.

**Codigos de Flow sincronizados con BD:**
Los codigos de servicio y extra en el Flow JSON estatico (`haircut`, `beard`, etc.) coinciden exactamente con los codigos del seed. Esto permite mapear respuestas `nfm_reply` a registros de BD en Corte 5 sin transformacion adicional.

---

## Variables de entorno

Ver `CLAUDE.md` o `.env.example` para la lista completa.

Las funciones que accedan a BD en Corte 5+ requeriran:
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
