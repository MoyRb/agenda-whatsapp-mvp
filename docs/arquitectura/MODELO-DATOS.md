# Modelo de Datos — Nucleo Multiempresa (Corte 4)

## Diagrama de dependencias (FK)

```
auth.users
  └─ business_members.user_id
  └─ appointments.created_by (nullable, SET NULL)

businesses
  ├─ business_members.business_id
  ├─ services.business_id
  ├─ extras.business_id
  ├─ business_hours.business_id
  ├─ customers.business_id
  └─ appointments.business_id

services
  ├─ service_extras.service_id
  └─ appointments.service_id

extras
  ├─ service_extras.extra_id
  └─ appointment_extras.extra_id

customers
  └─ appointments.customer_id

appointments
  └─ appointment_extras.appointment_id
```

---

## Tablas

### `businesses`

| Columna | Tipo | Notas |
|---------|------|-------|
| `id` | uuid PK | gen_random_uuid() |
| `name` | text NOT NULL | Nombre del negocio |
| `slug` | text NOT NULL | Indice unico sobre lower(slug) |
| `timezone` | text NOT NULL | Ej. America/Mexico_City |
| `status` | text NOT NULL | 'active' \| 'inactive' |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | trigger set_updated_at |

**RLS:** SELECT para miembros; UPDATE para owner/admin. Sin INSERT/DELETE via RLS (solo service_role).

---

### `business_members`

| Columna | Tipo | Notas |
|---------|------|-------|
| `business_id` | uuid FK | ON DELETE RESTRICT |
| `user_id` | uuid FK → auth.users | ON DELETE CASCADE |
| `role` | text | 'owner' \| 'admin' \| 'staff' |
| `created_at` | timestamptz | |

PK: (business_id, user_id)

**RLS:** SELECT para miembros; INSERT/UPDATE/DELETE para owner/admin.

---

### `services`

| Columna | Tipo | Notas |
|---------|------|-------|
| `id` | uuid PK | |
| `business_id` | uuid FK | ON DELETE RESTRICT |
| `code` | text | UNIQUE con business_id |
| `name` | text | |
| `description` | text | nullable |
| `duration_minutes` | integer | > 0 |
| `price_cents` | integer | nullable (sin precio = consulta presencial) |
| `active` | boolean | default true |
| `sort_order` | integer | default 0 |
| `created_at` / `updated_at` | timestamptz | |

Codigos del seed demo: `haircut`, `beard`, `haircut_beard`, `hair_dye`

---

### `extras`

| Columna | Tipo | Notas |
|---------|------|-------|
| `id` | uuid PK | |
| `business_id` | uuid FK | ON DELETE RESTRICT |
| `code` | text | UNIQUE con business_id |
| `name` | text | |
| `duration_delta_minutes` | integer | default 0 — minutos adicionales al servicio base |
| `price_cents` | integer | nullable |
| `active` | boolean | default true |
| `sort_order` | integer | default 0 |
| `created_at` / `updated_at` | timestamptz | |

Codigos del seed demo: `wash`, `mask`, `beard_design`, `treatment`

---

### `service_extras`

| Columna | Tipo | Notas |
|---------|------|-------|
| `business_id` | uuid NOT NULL | Parte de PK y de las FK compuestas |
| `service_id` | uuid NOT NULL | |
| `extra_id` | uuid NOT NULL | |
| `created_at` | timestamptz | |

PK: (business_id, service_id, extra_id)

**Consistencia cross-business mediante FK compuestas** (no CHECK con subquery):
- `FOREIGN KEY (service_id, business_id) REFERENCES services(id, business_id)` ON DELETE CASCADE
- `FOREIGN KEY (extra_id, business_id)   REFERENCES extras(id, business_id)`   ON DELETE CASCADE

Si se intenta relacionar un servicio de negocio A con un extra de negocio B usando `business_id=A`, la segunda FK falla con `foreign_key_violation` porque el par `(extra_id_B, business_id_A)` no existe en extras.

---

### `business_hours`

| Columna | Tipo | Notas |
|---------|------|-------|
| `business_id` | uuid FK | ON DELETE CASCADE |
| `weekday` | integer | 0=dom ... 6=sab |
| `is_closed` | boolean | default false |
| `opens_at` | time | NULL si is_closed=true |
| `closes_at` | time | NULL si is_closed=true |
| `created_at` / `updated_at` | timestamptz | |

PK: (business_id, weekday)

CHECK CONSTRAINT `business_hours_closed_nulls`:
- Si `is_closed=true` → `opens_at` y `closes_at` deben ser NULL
- Si `is_closed=false` → ambos deben ser NOT NULL y `opens_at < closes_at`

---

### `customers`

| Columna | Tipo | Notas |
|---------|------|-------|
| `id` | uuid PK | |
| `business_id` | uuid FK | ON DELETE RESTRICT |
| `whatsapp_phone_e164` | text | UNIQUE con business_id; regex `^\+[1-9]\d{7,14}$` |
| `display_name` | text | nullable |
| `created_at` / `updated_at` | timestamptz | |

Mismo regex E.164 que usan `whatsapp-send` y `whatsapp-flow-send`.

---

### `appointments`

| Columna | Tipo | Notas |
|---------|------|-------|
| `id` | uuid PK | |
| `business_id` | uuid FK → businesses | ON DELETE RESTRICT |
| `customer_id` | uuid NOT NULL | |
| `service_id` | uuid NOT NULL | |
| `starts_at` | timestamptz | |
| `ends_at` | timestamptz | > starts_at (CHECK) |
| `status` | text | pending/confirmed/completed/cancelled/no_show |
| `source` | text | whatsapp_flow/admin/import |
| `flow_version` | text | nullable — version del Flow que genero la cita |
| `external_reference` | text | nullable — UNIQUE parcial por negocio |
| `created_by` | uuid FK → auth.users | nullable, ON DELETE SET NULL |
| `created_at` / `updated_at` | timestamptz | |

UNIQUE adicional: `(id, business_id)` — permite que `appointment_extras` referencie con FK compuesta.

**Consistencia cross-business mediante FK compuestas** (no CHECK con subquery):
- `FOREIGN KEY (customer_id, business_id) REFERENCES customers(id, business_id)` ON DELETE RESTRICT
- `FOREIGN KEY (service_id, business_id)  REFERENCES services(id, business_id)`  ON DELETE RESTRICT

Indice unico parcial: `(business_id, external_reference) WHERE external_reference IS NOT NULL` — permite idempotencia al insertar desde webhook (Corte 5).

---

### `appointment_extras`

| Columna | Tipo | Notas |
|---------|------|-------|
| `business_id` | uuid NOT NULL | Parte de PK y de las FK compuestas |
| `appointment_id` | uuid NOT NULL | |
| `extra_id` | uuid NOT NULL | |
| `created_at` | timestamptz | |

PK: (business_id, appointment_id, extra_id)

**Consistencia cross-business mediante FK compuestas** (no CHECK con subquery):
- `FOREIGN KEY (appointment_id, business_id) REFERENCES appointments(id, business_id)` ON DELETE CASCADE
- `FOREIGN KEY (extra_id, business_id)       REFERENCES extras(id, business_id)`       ON DELETE RESTRICT

---

### `whatsapp_channels`

| Columna | Tipo | Notas |
|---------|------|-------|
| `id` | uuid PK | gen_random_uuid() |
| `business_id` | uuid FK → businesses | ON DELETE RESTRICT |
| `waba_id` | text NOT NULL | CHECK <> '' |
| `phone_number_id` | text NOT NULL | UNIQUE global |
| `display_phone_number` | text | nullable |
| `status` | text NOT NULL | 'active' \| 'inactive' |
| `created_at` / `updated_at` | timestamptz | trigger set_updated_at |

UNIQUE: `(phone_number_id)` y `(business_id, waba_id, phone_number_id)`

**RLS:** SELECT para miembros; INSERT/UPDATE para owner/admin. Sin DELETE — canales se desactivan con `status='inactive'`.

Indice: `whatsapp_channels_business_id_idx ON (business_id)`

**Canal del seed demo:** `phone_number_id='000000000000002'`, `waba_id='000000000000001'`

---

### RPC `create_whatsapp_flow_appointment`

Funcion SECURITY DEFINER ejecutable solo por `service_role`. Recibe los datos de un `nfm_reply` y persiste la cita de forma atomica e idempotente.

**Firma:**
```sql
public.create_whatsapp_flow_appointment(
  p_phone_number_id, p_customer_phone_e164, p_customer_display_name,
  p_service_code, p_extra_codes text[], p_appointment_date date,
  p_appointment_time text, p_flow_version text, p_external_reference text
) RETURNS TABLE (appointment_id, business_id, created_new, status, starts_at, ends_at)
```

**Mecanismo de idempotencia:** `pg_advisory_xact_lock(hashtextextended(bid||':'||ref, 0))` + unique index `(business_id, external_reference)`.

**Flujo interno:** validaciones de input → resolver canal/negocio → validar timezone → advisory lock → re-check idempotencia → validaciones de negocio (fecha, servicio, extras, horario) → calcular timestamps con timezone → escritura atomica (customer upsert + appointment + appointment_extras).

---

## Estrategia RLS

Dos funciones helper `SECURITY DEFINER` para evitar recursion en `business_members`:

- `public.is_business_member(p_business_id uuid) → boolean`
- `public.has_business_role(p_business_id uuid, p_roles text[]) → boolean`

Propiedades de ambas funciones:
- `SECURITY DEFINER` — evita recursion al consultar business_members
- `SET search_path = ''` — previene search_path injection
- `(SELECT auth.uid())` — optimization fence, evalua una sola vez por query
- `REVOKE EXECUTE FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated` — impide invocacion directa sin sesion autenticada

**Roles en business_members:**
- `owner`: puede gestionar cualquier rol, incluyendo agregar/quitar owners
- `admin`: solo puede crear, modificar y eliminar miembros `staff`; no puede escalar privilegios
- `staff`: sin permisos de gestion de miembros

**Proteccion ultimo owner:** las politicas DELETE y UPDATE impiden degradar o eliminar al ultimo owner de un negocio.

El `service_role` de Supabase omite RLS. Toda Edge Function con `SUPABASE_SERVICE_ROLE_KEY` debe validar `business_id` explicitamente antes de escribir.

---

## Politica de ON DELETE por tabla

| Tabla hija | FK hacia | Columnas referenciadas | ON DELETE |
|------------|----------|----------------------|-----------|
| `business_members` | `businesses` | `(id)` | RESTRICT |
| `business_members` | `auth.users` | `(id)` | CASCADE |
| `services` | `businesses` | `(id)` | RESTRICT |
| `extras` | `businesses` | `(id)` | RESTRICT |
| `service_extras` | `services` | `(id, business_id)` — FK compuesta | CASCADE |
| `service_extras` | `extras` | `(id, business_id)` — FK compuesta | CASCADE |
| `business_hours` | `businesses` | `(id)` | CASCADE |
| `customers` | `businesses` | `(id)` | RESTRICT |
| `appointments` | `businesses` | `(id)` | RESTRICT |
| `appointments` | `customers` | `(id, business_id)` — FK compuesta | RESTRICT |
| `appointments` | `services` | `(id, business_id)` — FK compuesta | RESTRICT |
| `appointments` | `auth.users` (created_by) | `(id)` | SET NULL |
| `appointment_extras` | `appointments` | `(id, business_id)` — FK compuesta | CASCADE |
| `appointment_extras` | `extras` | `(id, business_id)` — FK compuesta | RESTRICT |

Las FK compuestas son el mecanismo de consistencia cross-business. PostgreSQL no permite subqueries en CHECK constraints de tabla.

**Patron general:** RESTRICT protege datos historicos; CASCADE limpia configuracion propia; SET NULL preserva citas cuando el usuario admin desaparece.

---

## Indices

| Indice | Tabla | Columnas | Tipo |
|--------|-------|----------|------|
| `businesses_slug_lower_idx` | businesses | lower(slug) | UNIQUE |
| `business_members_business_id_idx` | business_members | business_id | BTREe |
| `business_members_user_id_idx` | business_members | user_id | BTREE |
| `business_members_user_business_idx` | business_members | user_id, business_id | BTREE (RLS helper) |
| `services_business_id_idx` | services | business_id | BTREE |
| `extras_business_id_idx` | extras | business_id | BTREE |
| `service_extras_extra_id_idx` | service_extras | extra_id | BTREE |
| `business_hours_business_id_idx` | business_hours | business_id | BTREE |
| `customers_business_id_idx` | customers | business_id | BTREE |
| `appointments_business_id_idx` | appointments | business_id | BTREE |
| `appointments_customer_id_idx` | appointments | customer_id | BTREE |
| `appointments_service_id_idx` | appointments | service_id | BTREE |
| `appointments_starts_at_idx` | appointments | starts_at | BTREE |
| `appointments_external_ref_idx` | appointments | business_id, external_reference | UNIQUE parcial |
| `appointment_extras_extra_id_idx` | appointment_extras | extra_id | BTREE |

---

## Seed de desarrollo

UUIDs fijos para referencias reproducibles:

| Entidad | UUID |
|---------|------|
| Negocio demo | `00000000-0000-0000-0000-000000000001` |
| Servicio haircut | `00000000-0000-0000-0001-000000000001` |
| Servicio beard | `00000000-0000-0000-0001-000000000002` |
| Servicio haircut_beard | `00000000-0000-0000-0001-000000000003` |
| Servicio hair_dye | `00000000-0000-0000-0001-000000000004` |
| Extra wash | `00000000-0000-0000-0002-000000000001` |
| Extra mask | `00000000-0000-0000-0002-000000000002` |
| Extra beard_design | `00000000-0000-0000-0002-000000000003` |
| Extra treatment | `00000000-0000-0000-0002-000000000004` |

---

## Decisiones que afectan Cortes 5+

| Decision | Impacto futuro |
|----------|---------------|
| `appointments.external_reference` unico por negocio | Idempotencia al crear citas desde webhook (Corte 5) usando flow_token o message_id |
| `appointments.flow_version` | Rastrear que version del Flow genero la cita |
| `appointments.created_by` nullable | Citas creadas por webhook sin usuario auth |
| `appointments.source` con valores fijos | Analytics y filtros en panel admin (Corte 6) |
| `business_hours` como tabla separada | Agregar excepciones/dias especiales en Corte 5+ sin migracion |
| Sin `staff_id` en appointments | Corte 5 puede agregar columna nullable sin romper esquema |
| `price_cents` nullable en servicios | Negocios sin precio fijo (consulta presencial) |
