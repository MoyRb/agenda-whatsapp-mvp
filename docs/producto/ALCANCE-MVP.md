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

## Fuera de alcance (MVP actual)

- Endpoint dinamico de Flow (data endpoint + RSA)
- Supabase Database / migraciones
- Disponibilidad real de horarios
- Prevencion de horarios duplicados
- Google Calendar
- Panel administrativo
- Fidelizacion
- Multiples negocios
- Embedded Signup
- Respuestas automaticas
- Pagos
