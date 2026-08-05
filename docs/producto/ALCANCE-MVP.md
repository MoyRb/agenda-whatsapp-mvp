# Alcance del MVP

## Corte Vertical 1 — whatsapp-send

**Estado: Validado**

- Envia la plantilla `hello_world` a un numero E.164 dado
- Protegida con `x-internal-secret`
- Sin base de datos, sin webhook, sin calendario

## Corte Vertical 2 — whatsapp-webhook

**Estado: Validado con Meta**

- Verificacion del handshake de Meta (GET con `hub.verify_token`)
- Recepcion y validacion HMAC-SHA256 de eventos POST
- Logs sanitizados de mensajes y estados
- Sin responder mensajes, sin base de datos, sin llamar a otras funciones

## Corte Vertical 3 — WhatsApp Flow estatico de reservacion

**Estado: Implementado**

- Flow JSON v7.3 con 4 pantallas de reservacion (SERVICE, EXTRAS, SCHEDULE, CONFIRMATION)
- Edge Function `whatsapp-flow-send` que envia el formulario interactivo al cliente
- Webhook extendido para reconocer y loguear respuestas `nfm_reply` de forma sanitizada
- Scripts PowerShell para crear, subir, validar y publicar el Flow en Meta
- Sin base de datos, sin Google Calendar, sin disponibilidad dinamica

## Corte Vertical 4 — Nucleo de datos multiempresa

**Estado: Implementado**

- Migracion reproducible: 9 tablas con RLS, indices y triggers
- Esquema multiempresa desde el inicio (`business_id` en todas las tablas)
- Funciones helper RLS `SECURITY DEFINER` para evitar recursion
- CHECKs de consistencia cross-business en `service_extras` y `appointment_extras`
- Seed idempotente con negocio demo y UUIDs fijos
- Codigos de servicio/extra sincronizados con el Flow JSON estatico (Corte 3)
- 14 smoke tests SQL para validar constraints, seed y RLS
- Sin conexion a Edge Functions (eso es Corte 5+)

## Corte Vertical 5 — Persistencia de Flow Responses como citas

**Estado: Implementado**

- Webhook extendido: detecta `nfm_reply`, normaliza teléfono E.164, llama RPC Supabase
- Migración `whatsapp_channels`: tabla con RLS multiempresa (sin DELETE, status='inactive')
- RPC `create_whatsapp_flow_appointment`: SECURITY DEFINER, solo service_role
  - Idempotencia con `pg_advisory_xact_lock` + unique index `(business_id, external_reference)`
  - Valida canal, negocio, timezone, servicio, extras, horario antes de escribir
  - Upsert customer + INSERT appointment (status=pending) + appointment_extras
  - Retorna `created_new`: true (nueva cita) o false (idempotente)
- Módulo compartido `_shared/supabase-client.ts` con soporte para `SUPABASE_SECRET_KEYS`
- Seed actualizado: canal WhatsApp sintético `phone_number_id='000000000000002'`
- 26 smoke tests SQL: T01-T26 (validaciones, idempotencia secuencial y permisos)
- Script de integración `test-whatsapp-booking-webhook.ps1`
- Script de concurrencia `test-booking-idempotency-concurrency.ps1`
- Sin Google Calendar, sin respuesta automática al cliente (Corte 6)

## Fuera de alcance (MVP actual)

- Endpoint dinamico de Flow (data endpoint + RSA)
- Disponibilidad real de horarios (solapamiento de citas)
- Google Calendar
- Respuesta automatica de confirmacion al cliente
- Panel administrativo
- Fidelizacion
- Embedded Signup
- Pagos
