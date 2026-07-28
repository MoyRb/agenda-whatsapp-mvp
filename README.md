# Agenda WhatsApp MVP

Sistema de agenda y fidelización para pequeños negocios.

## Objetivo

Permitir que los clientes reserven una cita directamente desde WhatsApp mediante WhatsApp Flows.

La cita deberá:

1. Guardarse en Supabase.
2. Registrarse en Google Calendar.
3. Aparecer en el panel administrativo.
4. Actualizar la fidelización cuando sea completada.

## Estructura

- apps/admin: panel administrativo móvil.
- supabase/migrations: migraciones de base de datos.
- supabase/functions: funciones backend.
- whatsapp/flows: definiciones JSON de WhatsApp Flows.
- whatsapp/templates: plantillas de mensajes.
- docs: documentación del producto.
- tests: pruebas del sistema.

## Stack

- React
- Vite
- TypeScript
- Tailwind CSS
- Supabase
- WhatsApp Cloud API
- WhatsApp Flows
- Google Calendar API
