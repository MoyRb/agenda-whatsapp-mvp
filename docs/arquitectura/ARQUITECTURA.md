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
  ├─ whatsapp-webhook       [Corte 2 — validado / Corte 5 — implementado]
  └─ whatsapp-flow-send     [Corte 3 — implementado]
      |
      v
Supabase PostgreSQL (RLS multiempresa)  [Corte 4+5 — implementado]
  ├─ whatsapp_channels
  └─ RPC create_whatsapp_flow_appointment
      |
      v
Google Calendar API                     [Corte 6 — pendiente]
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

## Flujo de mensajes (Corte 5 — implementado)

```
1. Cliente envia mensaje a WhatsApp Business
2. Meta entrega POST al webhook (whatsapp-webhook)
3. Webhook valida HMAC-SHA256
4. Si es nfm_reply (respuesta de Flow):
   a. Normaliza telefono a E.164 (Meta puede omitir '+')
   b. Parsea response_json (solo claves conocidas)
   c. Valida flow_version y formato de fecha
   d. Llama a create_whatsapp_flow_appointment via Supabase service_role
      - pg_advisory_xact_lock para idempotencia concurrente
      - Valida canal, negocio, timezone, servicio, extras, horario
      - Upsert customer + INSERT appointment + appointment_extras
   e. Log sanitizado: appointmentIdSuffix, createdNew, status
5. Errores de negocio (P0001) → HTTP 200 (no reintentar)
6. Timeout BD (>8s) / error conexion → HTTP 500 (Meta reintenta)
```

## Flujo de mensajes (futuro — Corte 6+)

```
Tras crear cita (status=pending):
1. Verificar disponibilidad en Google Calendar
2. Crear evento en Google Calendar
3. UPDATE appointments SET status='confirmed'
4. Enviar confirmacion al cliente via whatsapp-send
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

Las funciones que accedan a BD requieren:
- `SUPABASE_URL` — inyectado automáticamente por Supabase Runtime
- `SUPABASE_SECRET_KEYS` — inyectado automáticamente (preferido, Runtime v2)
- `SUPABASE_SERVICE_ROLE_KEY` — alternativa legacy / desarrollo local
