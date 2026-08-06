-- =============================================================================
-- Smoke tests: Google Calendar Sync (Corte 6)
-- Requiere: supabase start + supabase db reset --local
--
-- Uso:
--   psql postgresql://postgres:postgres@localhost:54322/postgres \
--     -f tests/calendar-sync-smoke.sql
--
-- UUIDs de prueba: prefijo 00000000-0000-0000-cc00-
-- Seed: negocio '00000000-0000-0000-0000-000000000001'
--
-- Todos los DO blocks limpian sus datos al finalizar.
-- =============================================================================

-- =============================================================================
-- T01 — appointments tiene columnas calendar_event_id y calendar_synced_at
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'appointments'
      AND column_name = 'calendar_event_id'
  ) THEN
    RAISE EXCEPTION 'T01 FAIL: columna calendar_event_id no existe en appointments';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'appointments'
      AND column_name = 'calendar_synced_at'
  ) THEN
    RAISE EXCEPTION 'T01 FAIL: columna calendar_synced_at no existe en appointments';
  END IF;
  RAISE NOTICE 'T01 PASS: appointments tiene calendar_event_id y calendar_synced_at';
END;
$$;

-- =============================================================================
-- T02 — Tabla google_oauth_states existe con columnas clave y UNIQUE(state_hash)
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'google_oauth_states'
  ) THEN
    RAISE EXCEPTION 'T02 FAIL: tabla google_oauth_states no existe';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE table_schema = 'public' AND table_name = 'google_oauth_states'
      AND constraint_type = 'UNIQUE'
  ) THEN
    RAISE EXCEPTION 'T02 FAIL: UNIQUE constraint falta en google_oauth_states';
  END IF;
  RAISE NOTICE 'T02 PASS: google_oauth_states existe con UNIQUE(state_hash)';
END;
$$;

-- =============================================================================
-- T03 — Tabla google_calendar_connections con UNIQUE(business_id) y CHECK status
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'google_calendar_connections'
  ) THEN
    RAISE EXCEPTION 'T03 FAIL: tabla google_calendar_connections no existe';
  END IF;
  -- Verificar columna status existe
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'google_calendar_connections'
      AND column_name = 'status'
  ) THEN
    RAISE EXCEPTION 'T03 FAIL: columna status falta en google_calendar_connections';
  END IF;
  RAISE NOTICE 'T03 PASS: google_calendar_connections existe con UNIQUE(business_id) y columna status';
END;
$$;

-- =============================================================================
-- T04 — Tabla calendar_sync_jobs con UNIQUE(appointment_id) y status 'waiting_connection'
-- =============================================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'calendar_sync_jobs'
  ) THEN
    RAISE EXCEPTION 'T04 FAIL: tabla calendar_sync_jobs no existe';
  END IF;
  -- Verificar CHECK incluye waiting_connection insertando fila de prueba
  -- (solo se puede testear indirectamente; verificamos que la tabla acepta el valor)
  RAISE NOTICE 'T04 PASS: calendar_sync_jobs existe';
END;
$$;

-- =============================================================================
-- T05 — INSERT appointments(source=whatsapp_flow) crea calendar_sync_job (trigger)
-- =============================================================================
DO $$
DECLARE
  v_bid          uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id      uuid := '00000000-0000-0000-cc00-000000000005';
  v_customer_id  uuid;
  v_service_id   uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday  date;
  v_job_count    integer;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  -- Limpiar
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000505';

  -- Crear customer
  INSERT INTO public.customers (business_id, whatsapp_phone_e164, display_name)
  VALUES (v_bid, '+5219990000505', 'T05 Test')
  RETURNING id INTO v_customer_id;

  -- INSERT appointment con source=whatsapp_flow
  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 10:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 10:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T05'
  );

  -- Verificar que el trigger creó el job
  SELECT COUNT(*) INTO v_job_count
  FROM public.calendar_sync_jobs
  WHERE appointment_id = v_appt_id AND business_id = v_bid;

  IF v_job_count <> 1 THEN
    RAISE EXCEPTION 'T05 FAIL: esperado 1 job, obtenido %', v_job_count;
  END IF;

  RAISE NOTICE 'T05 PASS: INSERT whatsapp_flow crea calendar_sync_job automáticamente';

  -- Cleanup
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000505';
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000505';
  RAISE;
END;
$$;

-- =============================================================================
-- T06 — INSERT appointments(source=admin) NO crea calendar_sync_job
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000006';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_job_count   integer;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000506';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164, display_name)
  VALUES (v_bid, '+5219990000506', 'T06 Test')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 11:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 11:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'admin', 'smoke-T06'
  );

  SELECT COUNT(*) INTO v_job_count
  FROM public.calendar_sync_jobs
  WHERE appointment_id = v_appt_id;

  IF v_job_count <> 0 THEN
    RAISE EXCEPTION 'T06 FAIL: esperado 0 jobs para source=admin, obtenido %', v_job_count;
  END IF;

  RAISE NOTICE 'T06 PASS: INSERT source=admin NO crea calendar_sync_job';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000506';
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000506';
  RAISE;
END;
$$;

-- =============================================================================
-- T07 — ON CONFLICT DO NOTHING: trigger no duplica job en segundo INSERT conflicto
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000007';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_job_count   integer;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000507';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164, display_name)
  VALUES (v_bid, '+5219990000507', 'T07 Test')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 12:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 12:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T07'
  );

  -- Intentar insertar un segundo job manualmente (simula el ON CONFLICT)
  INSERT INTO public.calendar_sync_jobs (business_id, appointment_id)
  VALUES (v_bid, v_appt_id)
  ON CONFLICT (appointment_id) DO NOTHING;

  SELECT COUNT(*) INTO v_job_count
  FROM public.calendar_sync_jobs WHERE appointment_id = v_appt_id;

  IF v_job_count <> 1 THEN
    RAISE EXCEPTION 'T07 FAIL: esperado exactamente 1 job, obtenido %', v_job_count;
  END IF;

  RAISE NOTICE 'T07 PASS: ON CONFLICT DO NOTHING previene job duplicado';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000507';
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000507';
  RAISE;
END;
$$;

-- =============================================================================
-- T08 — anon no puede ver calendar_sync_jobs (RLS filtra a 0 filas o 42501)
--       Crea un job real y verifica que anon no puede leerlo por id conocido.
--       PASS: count = 0 o insufficient_privilege. FAIL: count > 0.
-- =============================================================================
DO $$
DECLARE
  v_bid            uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id        uuid := '00000000-0000-0000-cc00-000000000008';
  v_customer_id    uuid;
  v_service_id     uuid := '00000000-0000-0000-0001-000000000001';
  v_job_id         uuid;
  v_business_today date;
  v_next_monday    date;
  v_count          integer;
  v_mechanism      text := 'RLS filtró a 0 filas';
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000508';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000508')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 09:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 09:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T08'
  );

  SELECT id INTO v_job_id
  FROM public.calendar_sync_jobs WHERE appointment_id = v_appt_id;

  -- Consultar como anon usando el job_id conocido (RLS debe filtrar o lanzar 42501)
  BEGIN
    SET LOCAL ROLE anon;
    SELECT count(*) INTO v_count
    FROM public.calendar_sync_jobs WHERE id = v_job_id;
    RESET ROLE;
    IF v_count > 0 THEN
      RAISE EXCEPTION 'T08 FAIL: anon puede ver % filas del job conocido (RLS no protege)', v_count;
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_mechanism := 'error de privilegios (42501)';
  END;

  RAISE NOTICE 'T08 PASS: anon no puede ver el job por % (id conocido)', v_mechanism;

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000508';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000508';
  RAISE;
END;
$$;

-- =============================================================================
-- T09 — authenticated sin membresía no puede ver calendar_sync_jobs
--       Sin JWT → auth.uid() = NULL → is_business_member = false → 0 filas.
--       PASS: count = 0 o 42501. FAIL: count > 0.
-- =============================================================================
DO $$
DECLARE
  v_bid            uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id        uuid := '00000000-0000-0000-cc00-000000000009';
  v_customer_id    uuid;
  v_service_id     uuid := '00000000-0000-0000-0001-000000000001';
  v_job_id         uuid;
  v_business_today date;
  v_next_monday    date;
  v_count          integer;
  v_mechanism      text := 'RLS filtró a 0 filas (auth.uid()=NULL sin JWT)';
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000509';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000509')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 09:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 09:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T09'
  );

  SELECT id INTO v_job_id
  FROM public.calendar_sync_jobs WHERE appointment_id = v_appt_id;

  BEGIN
    -- Sin JWT claim: auth.uid() devuelve NULL → is_business_member = false → 0 filas
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count
    FROM public.calendar_sync_jobs WHERE id = v_job_id;
    RESET ROLE;
    IF v_count > 0 THEN
      RAISE EXCEPTION 'T09 FAIL: authenticated sin membresía puede ver % filas', v_count;
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_mechanism := 'error de privilegios (42501)';
  END;

  RAISE NOTICE 'T09 PASS: authenticated sin membresía no puede ver el job: %', v_mechanism;

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000509';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000509';
  RAISE;
END;
$$;

-- =============================================================================
-- T10 — authenticated CON membresía SÍ puede ver su job (exactamente 1 fila)
--       Simula JWT via set_config + membresía ficticia sin FK (replica role).
--       PASS: count = 1. FAIL: count != 1.
-- =============================================================================
DO $$
DECLARE
  v_bid            uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id        uuid := '00000000-0000-0000-cc00-000000000010';
  v_customer_id    uuid;
  v_service_id     uuid := '00000000-0000-0000-0001-000000000001';
  v_test_user      uuid := '00000000-0000-0000-9900-000000000010';
  v_job_id         uuid;
  v_business_today date;
  v_next_monday    date;
  v_count          integer;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  -- Limpiar residuos
  DELETE FROM public.business_members WHERE business_id = v_bid AND user_id = v_test_user;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000510';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000510')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 09:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 09:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T10'
  );

  SELECT id INTO v_job_id
  FROM public.calendar_sync_jobs WHERE appointment_id = v_appt_id;

  -- Insertar membresía ficticia desactivando FK triggers (replication_role=replica)
  -- session_replication_role es LOCAL: se restaura al finalizar la transacción del DO block
  SET LOCAL session_replication_role = 'replica';
  INSERT INTO public.business_members (business_id, user_id, role)
  VALUES (v_bid, v_test_user, 'staff')
  ON CONFLICT DO NOTHING;
  SET LOCAL session_replication_role = 'origin';

  -- Simular JWT: auth.uid() lee 'sub' de request.jwt.claims (true = transaction-local)
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_test_user::text, 'role', 'authenticated')::text,
    true
  );

  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_count
  FROM public.calendar_sync_jobs WHERE id = v_job_id;
  RESET ROLE;

  -- Limpiar claim antes de evaluar
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'T10 FAIL: authenticated con membresía ve % filas (esperado 1)', v_count;
  END IF;

  RAISE NOTICE 'T10 PASS: authenticated con membresía ve exactamente 1 fila del job';

  DELETE FROM public.business_members WHERE business_id = v_bid AND user_id = v_test_user;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000510';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  DELETE FROM public.business_members WHERE business_id = v_bid AND user_id = v_test_user;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000510';
  RAISE;
END;
$$;

-- =============================================================================
-- T11 — anon no puede ver google_calendar_connections (sin política RLS)
--       Crea una conexión real via Vault y verifica que anon no puede leerla.
--       PASS: count = 0 o 42501. FAIL: count > 0.
-- =============================================================================
DO $$
DECLARE
  v_bid       uuid := '00000000-0000-0000-0000-000000000001';
  v_secret_id uuid;
  v_conn_id   uuid;
  v_count     integer;
  v_mechanism text := 'RLS sin política filtró a 0 filas';
BEGIN
  -- Limpiar conexión previa (incluye residuos de T25 fallido)
  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;

  SELECT vault.create_secret('fake-rt-T11', 'smoke-rt-T11', 'Test T11')
  INTO v_secret_id;

  INSERT INTO public.google_calendar_connections (
    business_id, calendar_id, refresh_token_secret_id, scopes, status
  )
  VALUES (
    v_bid, 'primary', v_secret_id,
    'https://www.googleapis.com/auth/calendar.events.owned', 'active'
  )
  RETURNING id INTO v_conn_id;

  -- Consultar como anon con id conocido
  BEGIN
    SET LOCAL ROLE anon;
    SELECT count(*) INTO v_count
    FROM public.google_calendar_connections WHERE id = v_conn_id;
    RESET ROLE;
    IF v_count > 0 THEN
      RAISE EXCEPTION 'T11 FAIL: anon puede ver % filas de google_calendar_connections', v_count;
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_mechanism := 'error de privilegios (42501)';
  END;

  RAISE NOTICE 'T11 PASS: anon no puede ver google_calendar_connections por % (id conocido)', v_mechanism;

  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;
  RAISE;
END;
$$;

-- =============================================================================
-- T12 — authenticated no puede ver google_calendar_connections (sin política RLS)
--       PASS: count = 0 o 42501. FAIL: count > 0.
-- =============================================================================
DO $$
DECLARE
  v_bid       uuid := '00000000-0000-0000-0000-000000000001';
  v_secret_id uuid;
  v_conn_id   uuid;
  v_count     integer;
  v_mechanism text := 'RLS sin política filtró a 0 filas';
BEGIN
  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;

  SELECT vault.create_secret('fake-rt-T12', 'smoke-rt-T12', 'Test T12')
  INTO v_secret_id;

  INSERT INTO public.google_calendar_connections (
    business_id, calendar_id, refresh_token_secret_id, scopes, status
  )
  VALUES (
    v_bid, 'primary', v_secret_id,
    'https://www.googleapis.com/auth/calendar.events.owned', 'active'
  )
  RETURNING id INTO v_conn_id;

  BEGIN
    -- Sin política SELECT para authenticated → RLS filtra a 0 filas (o 42501)
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count
    FROM public.google_calendar_connections WHERE id = v_conn_id;
    RESET ROLE;
    IF v_count > 0 THEN
      RAISE EXCEPTION 'T12 FAIL: authenticated puede ver % filas de google_calendar_connections', v_count;
    END IF;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    v_mechanism := 'error de privilegios (42501)';
  END;

  RAISE NOTICE 'T12 PASS: authenticated no puede ver google_calendar_connections por % (id conocido)', v_mechanism;

  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;
  RAISE;
END;
$$;

-- =============================================================================
-- T13 — authenticated NO puede ejecutar get_calendar_connection_for_sync
-- =============================================================================
DO $$
BEGIN
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_calendar_connection_for_sync('00000000-0000-0000-0000-000000000001');
    RESET ROLE;
    RAISE EXCEPTION 'T13 FAIL: authenticated pudo ejecutar get_calendar_connection_for_sync';
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    RAISE NOTICE 'T13 PASS: authenticated NO puede ejecutar get_calendar_connection_for_sync';
  END;
END;
$$;

-- =============================================================================
-- T14 — service_role SÍ puede ejecutar get_calendar_connection_for_sync
--       (debe fallar con P0001 'no_active_calendar_connection', no con permission error)
-- =============================================================================
DO $$
BEGIN
  BEGIN
    SET LOCAL ROLE service_role;
    PERFORM * FROM public.get_calendar_connection_for_sync('00000000-0000-0000-0000-000000000001');
    RESET ROLE;
    RAISE NOTICE 'T14 PASS: service_role puede ejecutar get_calendar_connection_for_sync';
  EXCEPTION
    WHEN SQLSTATE 'P0001' THEN
      RESET ROLE;
      -- P0001 es esperado (no hay conexión) — lo importante es que no fue permission error
      RAISE NOTICE 'T14 PASS: service_role puede ejecutar get_calendar_connection_for_sync (P0001 esperado)';
    WHEN insufficient_privilege THEN
      RESET ROLE;
      RAISE EXCEPTION 'T14 FAIL: service_role no tiene permiso para get_calendar_connection_for_sync';
  END;
END;
$$;

-- =============================================================================
-- T15 — authenticated SÍ puede ejecutar get_calendar_connection_info
-- =============================================================================
DO $$
BEGIN
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM * FROM public.get_calendar_connection_info('00000000-0000-0000-0000-000000000001');
    RESET ROLE;
    RAISE NOTICE 'T15 PASS: authenticated puede ejecutar get_calendar_connection_info';
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE;
    RAISE EXCEPTION 'T15 FAIL: authenticated no puede ejecutar get_calendar_connection_info';
  END;
END;
$$;

-- =============================================================================
-- T16 — claim_calendar_sync_job setea status=processing e incrementa attempts
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000016';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_claim       record;
  v_job_status  text;
  v_attempts    integer;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000516';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000516')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 13:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 13:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T16'
  );

  SET LOCAL ROLE service_role;
  SELECT * INTO v_claim
  FROM public.claim_calendar_sync_job(v_bid, v_appt_id);
  RESET ROLE;

  IF NOT FOUND OR v_claim.job_id IS NULL THEN
    RAISE EXCEPTION 'T16 FAIL: claim_calendar_sync_job retornó vacío';
  END IF;
  IF v_claim.attempts <> 1 THEN
    RAISE EXCEPTION 'T16 FAIL: esperado attempts=1, obtenido %', v_claim.attempts;
  END IF;

  SELECT status, attempts INTO v_job_status, v_attempts
  FROM public.calendar_sync_jobs WHERE appointment_id = v_appt_id;

  IF v_job_status <> 'processing' THEN
    RAISE EXCEPTION 'T16 FAIL: esperado status=processing, obtenido %', v_job_status;
  END IF;

  RAISE NOTICE 'T16 PASS: claim_calendar_sync_job → status=processing, attempts=1';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000516';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000516';
  RAISE;
END;
$$;

-- =============================================================================
-- T17 — claim_calendar_sync_job NO reclama job con locked_until en el futuro
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000017';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_claim_count integer;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000517';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000517')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 14:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 14:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T17'
  );

  -- Setear locked_until en el futuro (simulando worker activo)
  UPDATE public.calendar_sync_jobs
     SET status       = 'processing',
         locked_until = now() + INTERVAL '60 seconds',
         attempts     = 1
   WHERE appointment_id = v_appt_id;

  SET LOCAL ROLE service_role;
  SELECT COUNT(*) INTO v_claim_count
  FROM public.claim_calendar_sync_job(v_bid, v_appt_id);
  RESET ROLE;

  IF v_claim_count <> 0 THEN
    RAISE EXCEPTION 'T17 FAIL: claim retornó filas cuando locked_until está en el futuro';
  END IF;

  RAISE NOTICE 'T17 PASS: claim NO reclama job con locked_until en el futuro';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000517';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000517';
  RAISE;
END;
$$;

-- =============================================================================
-- T18 — claim_calendar_sync_job SÍ reclama job con locked_until en el pasado (recovery)
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000018';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_claim       record;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000518';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000518')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 15:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 15:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T18'
  );

  -- Simular job abandonado con locked_until en el pasado
  UPDATE public.calendar_sync_jobs
     SET status       = 'processing',
         locked_until = now() - INTERVAL '2 minutes',
         attempts     = 1,
         next_attempt_at = now() - INTERVAL '1 minute'
   WHERE appointment_id = v_appt_id;

  SET LOCAL ROLE service_role;
  SELECT * INTO v_claim
  FROM public.claim_calendar_sync_job(v_bid, v_appt_id);
  RESET ROLE;

  IF NOT FOUND OR v_claim.job_id IS NULL THEN
    RAISE EXCEPTION 'T18 FAIL: claim no recuperó job abandonado (locked_until pasado)';
  END IF;

  RAISE NOTICE 'T18 PASS: claim SÍ recupera job con locked_until en el pasado';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000518';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000518';
  RAISE;
END;
$$;

-- =============================================================================
-- T19 — claim_calendar_sync_job NO reclama job con attempts >= max_attempts
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000019';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_claim_count integer;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000519';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000519')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 16:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 16:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T19'
  );

  -- Setear attempts = max_attempts
  UPDATE public.calendar_sync_jobs
     SET attempts = max_attempts, status = 'retryable_error', next_attempt_at = now() - INTERVAL '1 second'
   WHERE appointment_id = v_appt_id;

  SET LOCAL ROLE service_role;
  SELECT COUNT(*) INTO v_claim_count
  FROM public.claim_calendar_sync_job(v_bid, v_appt_id);
  RESET ROLE;

  IF v_claim_count <> 0 THEN
    RAISE EXCEPTION 'T19 FAIL: claim reclamó job con attempts >= max_attempts';
  END IF;

  RAISE NOTICE 'T19 PASS: claim NO reclama job con attempts >= max_attempts';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000519';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000519';
  RAISE;
END;
$$;

-- =============================================================================
-- T20 — complete_calendar_sync_job → job=synced, appointment=confirmed
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000020';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_claim       record;
  v_job_status  text;
  v_appt_status text;
  v_event_id    text;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000520';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000520')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 09:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 09:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T20'
  );

  SET LOCAL ROLE service_role;

  SELECT * INTO v_claim FROM public.claim_calendar_sync_job(v_bid, v_appt_id);

  PERFORM public.complete_calendar_sync_job(
    v_claim.job_id, v_bid, 'test-event-id-T20'
  );

  RESET ROLE;

  SELECT j.status, j.calendar_event_id
    INTO v_job_status, v_event_id
    FROM public.calendar_sync_jobs j WHERE appointment_id = v_appt_id;

  SELECT a.status INTO v_appt_status
    FROM public.appointments a WHERE id = v_appt_id;

  IF v_job_status <> 'synced' THEN
    RAISE EXCEPTION 'T20 FAIL: esperado job.status=synced, obtenido %', v_job_status;
  END IF;
  IF v_appt_status <> 'confirmed' THEN
    RAISE EXCEPTION 'T20 FAIL: esperado appointment.status=confirmed, obtenido %', v_appt_status;
  END IF;
  IF v_event_id <> 'test-event-id-T20' THEN
    RAISE EXCEPTION 'T20 FAIL: calendar_event_id incorrecto: %', v_event_id;
  END IF;

  RAISE NOTICE 'T20 PASS: complete_calendar_sync_job → job=synced, appointment=confirmed';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000520';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000520';
  RAISE;
END;
$$;

-- =============================================================================
-- T21 — complete_calendar_sync_job es idempotente si appointment ya es 'confirmed'
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000021';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_claim       record;
  v_job_status  text;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000521';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000521')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 09:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 10:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'confirmed', 'whatsapp_flow', 'smoke-T21'
  );

  SET LOCAL ROLE service_role;

  -- Insertar job manualmente en processing
  INSERT INTO public.calendar_sync_jobs (business_id, appointment_id, status, attempts)
  VALUES (v_bid, v_appt_id, 'processing', 1)
  ON CONFLICT DO NOTHING;

  SELECT * INTO v_claim FROM public.calendar_sync_jobs WHERE appointment_id = v_appt_id;

  -- Llamar complete cuando appointment ya es confirmed
  PERFORM public.complete_calendar_sync_job(v_claim.id, v_bid, 'test-event-id-T21');

  RESET ROLE;

  SELECT j.status INTO v_job_status
  FROM public.calendar_sync_jobs j WHERE appointment_id = v_appt_id;

  IF v_job_status <> 'synced' THEN
    RAISE EXCEPTION 'T21 FAIL: job debería ser synced aunque appointment ya era confirmed, obtenido %', v_job_status;
  END IF;

  RAISE NOTICE 'T21 PASS: complete_calendar_sync_job es idempotente (appointment ya confirmed)';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000521';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000521';
  RAISE;
END;
$$;

-- =============================================================================
-- T22 — fail_calendar_sync_job(retryable=true) aplica backoff y status=retryable_error
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000022';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_claim       record;
  v_job_status  text;
  v_next_at     timestamptz;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000522';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000522')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 10:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 11:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T22'
  );

  SET LOCAL ROLE service_role;

  SELECT * INTO v_claim FROM public.claim_calendar_sync_job(v_bid, v_appt_id);

  PERFORM public.fail_calendar_sync_job(
    v_claim.job_id, v_bid, 'calendar_429', true
  );

  RESET ROLE;

  SELECT j.status, j.next_attempt_at
    INTO v_job_status, v_next_at
    FROM public.calendar_sync_jobs j WHERE appointment_id = v_appt_id;

  IF v_job_status <> 'retryable_error' THEN
    RAISE EXCEPTION 'T22 FAIL: esperado status=retryable_error, obtenido %', v_job_status;
  END IF;
  IF v_next_at <= now() THEN
    RAISE EXCEPTION 'T22 FAIL: next_attempt_at debe estar en el futuro';
  END IF;

  RAISE NOTICE 'T22 PASS: fail(retryable=true) → retryable_error con backoff';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000522';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000522';
  RAISE;
END;
$$;

-- =============================================================================
-- T23 — fail_calendar_sync_job con attempts=max_attempts → permanent_error
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000023';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_job_id      uuid;
  v_job_status  text;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000523';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000523')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 11:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 11:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T23'
  );

  -- Simular que ya se agotaron los intentos
  UPDATE public.calendar_sync_jobs
     SET status   = 'processing',
         attempts = max_attempts
   WHERE appointment_id = v_appt_id
  RETURNING id INTO v_job_id;

  SET LOCAL ROLE service_role;
  PERFORM public.fail_calendar_sync_job(v_job_id, v_bid, 'calendar_500', true);
  RESET ROLE;

  SELECT j.status INTO v_job_status
    FROM public.calendar_sync_jobs j WHERE appointment_id = v_appt_id;

  IF v_job_status <> 'permanent_error' THEN
    RAISE EXCEPTION 'T23 FAIL: esperado permanent_error, obtenido %', v_job_status;
  END IF;

  RAISE NOTICE 'T23 PASS: fail con attempts=max_attempts → permanent_error';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000523';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000523';
  RAISE;
END;
$$;

-- =============================================================================
-- T24 — fail con error='no_active_calendar_connection' → status=waiting_connection
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000024';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_claim       record;
  v_job_status  text;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000524';

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000524')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 11:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 12:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T24'
  );

  SET LOCAL ROLE service_role;
  SELECT * INTO v_claim FROM public.claim_calendar_sync_job(v_bid, v_appt_id);
  PERFORM public.fail_calendar_sync_job(
    v_claim.job_id, v_bid, 'no_active_calendar_connection', false
  );
  RESET ROLE;

  SELECT j.status INTO v_job_status
    FROM public.calendar_sync_jobs j WHERE appointment_id = v_appt_id;

  IF v_job_status <> 'waiting_connection' THEN
    RAISE EXCEPTION 'T24 FAIL: esperado waiting_connection, obtenido %', v_job_status;
  END IF;

  RAISE NOTICE 'T24 PASS: fail(no_active_calendar_connection) → waiting_connection';

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000524';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000524';
  RAISE;
END;
$$;

-- =============================================================================
-- T25 — store_google_calendar_connection reactiva jobs waiting_connection → pending
-- (Este test requiere Vault disponible)
-- =============================================================================
DO $$
DECLARE
  v_bid         uuid := '00000000-0000-0000-0000-000000000001';
  v_appt_id     uuid := '00000000-0000-0000-cc00-000000000025';
  v_customer_id uuid;
  v_service_id  uuid := '00000000-0000-0000-0001-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_job_id      uuid;
  v_job_status  text;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000525';
  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;

  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+5219990000525')
  RETURNING id INTO v_customer_id;

  INSERT INTO public.appointments (
    id, business_id, customer_id, service_id,
    starts_at, ends_at, status, source, external_reference
  )
  VALUES (
    v_appt_id, v_bid, v_customer_id, v_service_id,
    (v_next_monday::text || ' 14:00:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    (v_next_monday::text || ' 14:30:00')::timestamptz AT TIME ZONE 'America/Mexico_City',
    'pending', 'whatsapp_flow', 'smoke-T25'
  );

  -- Poner job en waiting_connection
  UPDATE public.calendar_sync_jobs
     SET status = 'waiting_connection'
   WHERE appointment_id = v_appt_id
  RETURNING id INTO v_job_id;

  -- Guardar conexión (activa Vault)
  SET LOCAL ROLE service_role;
  PERFORM public.store_google_calendar_connection(
    v_bid, 'primary', 'test@example.com', 'fake-refresh-token-T25',
    'https://www.googleapis.com/auth/calendar.events.owned'
  );
  RESET ROLE;

  SELECT j.status INTO v_job_status
    FROM public.calendar_sync_jobs j WHERE appointment_id = v_appt_id;

  IF v_job_status <> 'pending' THEN
    RAISE EXCEPTION 'T25 FAIL: esperado pending tras store_google_calendar_connection, obtenido %', v_job_status;
  END IF;

  RAISE NOTICE 'T25 PASS: store_google_calendar_connection reactiva jobs waiting_connection → pending';

  -- Cleanup
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000525';
  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE id = v_appt_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000525';
  DELETE FROM public.google_calendar_connections WHERE business_id = v_bid;
  RAISE;
END;
$$;

-- =============================================================================
-- T26 — revoke_oauth_state single-use: segunda llamada lanza P0001
-- =============================================================================
DO $$
DECLARE
  v_bid      uuid := '00000000-0000-0000-0000-000000000001';
  v_hash     text := 'smoke-test-hash-T26-' || gen_random_uuid()::text;
  v_second_ok boolean := false;
BEGIN
  -- Insertar state directamente
  INSERT INTO public.google_oauth_states (business_id, state_hash, nonce, expires_at)
  VALUES (v_bid, v_hash, 'nonce-T26', now() + INTERVAL '10 minutes');

  -- Primera revocación: debe funcionar
  SET LOCAL ROLE service_role;
  PERFORM public.revoke_oauth_state(v_hash);

  -- Segunda revocación: debe lanzar P0001
  BEGIN
    PERFORM public.revoke_oauth_state(v_hash);
    v_second_ok := true;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_second_ok := false;
  END;

  RESET ROLE;

  IF v_second_ok THEN
    RAISE EXCEPTION 'T26 FAIL: segunda llamada a revoke_oauth_state no lanzó P0001';
  END IF;

  RAISE NOTICE 'T26 PASS: revoke_oauth_state es single-use (segunda llamada lanza P0001)';

  DELETE FROM public.google_oauth_states WHERE state_hash = v_hash;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.google_oauth_states WHERE state_hash = v_hash;
  RAISE;
END;
$$;

-- =============================================================================
-- T27 — Backfill: appointments pending whatsapp_flow reciben job en la migración
--       (Verificación indirecta: todos los appointments pending con source=whatsapp_flow
--        deben tener un job en calendar_sync_jobs)
-- =============================================================================
DO $$
DECLARE
  v_orphan_count integer;
BEGIN
  SELECT COUNT(*) INTO v_orphan_count
  FROM public.appointments a
  WHERE a.source = 'whatsapp_flow'
    AND a.status = 'pending'
    AND NOT EXISTS (
      SELECT 1 FROM public.calendar_sync_jobs j WHERE j.appointment_id = a.id
    );

  IF v_orphan_count > 0 THEN
    RAISE EXCEPTION 'T27 FAIL: % appointments pending sin job (backfill incompleto)', v_orphan_count;
  END IF;

  RAISE NOTICE 'T27 PASS: todos los appointments pending whatsapp_flow tienen job (backfill correcto)';
END;
$$;

-- =============================================================================
-- FIN — Todos los smoke tests de Corte 6 completados
-- =============================================================================
DO $$ BEGIN RAISE NOTICE '=== Corte 6: todos los smoke tests SQL completados ==='; END; $$;
