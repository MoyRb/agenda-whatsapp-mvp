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

## Fuera de alcance (MVP actual)

- Endpoint dinamico de Flow (data endpoint + RSA)
- Conexion Edge Functions → Base de datos
- Disponibilidad real de horarios
- Prevencion de horarios duplicados
- Google Calendar
- Panel administrativo
- Fidelizacion
- Embedded Signup
- Respuestas automaticas
- Pagos
