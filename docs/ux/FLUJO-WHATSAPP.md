# Flujo de WhatsApp — Reservacion de Cita

## Descripcion general

El cliente recibe un mensaje interactivo de WhatsApp con el boton "Agendar cita".
Al presionarlo, se abre el formulario de reservacion directamente dentro de la app.
El formulario es estatico (Corte 3): sin validacion de disponibilidad en tiempo real.

## Pantallas del Flow

### Pantalla 1: SERVICE — Elige tu servicio

El cliente selecciona un servicio de la lista:

| ID interno | Etiqueta visible |
|---|---|
| `haircut` | Corte de cabello |
| `beard` | Barba |
| `haircut_beard` | Corte y barba |
| `hair_dye` | Tinte |

Seleccion unica obligatoria. Boton: **Siguiente**.

---

### Pantalla 2: EXTRAS — Agrega extras

El cliente puede seleccionar cero o varios extras:

| ID interno | Etiqueta visible |
|---|---|
| `wash` | Lavado |
| `mask` | Mascarilla |
| `beard_design` | Diseno de barba |
| `treatment` | Tratamiento |

Seleccion multiple opcional (maximo 4). Boton: **Siguiente**.

---

### Pantalla 3: SCHEDULE — Elige fecha y hora

- **DatePicker:** el cliente elige la fecha de la cita en el calendario nativo de WhatsApp.
- **Horarios estaticos:**

| ID interno | Horario |
|---|---|
| `10_00` | 10:00 |
| `11_30` | 11:30 |
| `13_00` | 13:00 |
| `16_30` | 16:30 |

Seleccion de horario unica obligatoria. Boton: **Revisar reservacion**.

---

### Pantalla 4: CONFIRMATION — Confirmar cita

Muestra un resumen de la seleccion con los campos:
- Servicio
- Extras
- Fecha
- Horario

**Limitacion conocida:** el resumen muestra los IDs internos (ej. `haircut`, `10_00`)
en lugar de las etiquetas legibles. Esto es una restriccion de los Flows estaticos
sin data endpoint. No afecta la funcionalidad: el payload se guarda correctamente.

Boton: **Confirmar cita** — envia la respuesta al webhook.

---

## Flujo de datos

```
Cliente presiona "Agendar cita"
    └─> [SERVICE] selecciona service_id
            └─> [EXTRAS] selecciona extra_ids (array)
                    └─> [SCHEDULE] selecciona appointment_date + appointment_time
                            └─> [CONFIRMATION] revisa y presiona "Confirmar cita"
                                    └─> complete payload → Meta → webhook
```

## Payload de respuesta (nfm_reply)

Cuando el cliente confirma, Meta entrega al webhook un mensaje `interactive` de tipo `nfm_reply`.
El campo `response_json` contiene:

```json
{
  "service_id": "haircut",
  "extra_ids": ["wash", "mask"],
  "appointment_date": "2026-08-15",
  "appointment_time": "10_00",
  "flow_version": "appointment-booking-static-v1"
}
```

El webhook loguea unicamente los campos esperados, enmascarando el numero del remitente.
No se guarda en base de datos en este corte.

## Archivo del Flow

`whatsapp/flows/appointment-booking-static-v1.json`

- Flow JSON version: 7.3
- Categoria: APPOINTMENT_BOOKING (configurada en la API de Meta, no en el JSON)
- Sin `data_api_version`, sin `data_channel_uri`, sin cifrado RSA
- Idioma: espanol
