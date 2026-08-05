-- =============================================================================
-- Migración: Ingestión de booking vía WhatsApp Flows (Corte 5)
--
-- Depende de: 20260803120000_create_booking_core.sql
--   Tablas: businesses, services, extras, service_extras, business_hours,
--           customers, appointments, appointment_extras
--   Funciones: set_updated_at, is_business_member, has_business_role
--
-- Orden de secciones:
--   1. CREATE TABLE whatsapp_channels
--   2. Índice y trigger updated_at
--   3. ENABLE RLS + CREATE POLICY
--   4. RPC create_whatsapp_flow_appointment (SECURITY DEFINER)
--   5. REVOKE / GRANT de la RPC
-- =============================================================================

-- =============================================================================
-- 1. CREATE TABLE whatsapp_channels
--    Sin tokens/secrets. Sin DELETE por RLS (canales se desactivan con status).
-- =============================================================================

CREATE TABLE public.whatsapp_channels (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id          uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  waba_id              text        NOT NULL CHECK (waba_id <> ''),
  phone_number_id      text        NOT NULL CHECK (phone_number_id <> ''),
  display_phone_number text,
  status               text        NOT NULL DEFAULT 'active'
                         CHECK (status IN ('active','inactive')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (phone_number_id),
  UNIQUE (business_id, waba_id, phone_number_id)
);

-- =============================================================================
-- 2. Índice y trigger
-- =============================================================================

CREATE INDEX whatsapp_channels_business_id_idx ON public.whatsapp_channels (business_id);

CREATE TRIGGER set_updated_at_whatsapp_channels
  BEFORE UPDATE ON public.whatsapp_channels
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =============================================================================
-- 3. ENABLE RLS + CREATE POLICY
--    SELECT: cualquier miembro del negocio
--    INSERT / UPDATE: solo owner o admin
--    Sin DELETE: canales se desactivan con status='inactive'
-- =============================================================================

ALTER TABLE public.whatsapp_channels ENABLE ROW LEVEL SECURITY;

CREATE POLICY whatsapp_channels_select ON public.whatsapp_channels
  FOR SELECT
  USING (public.is_business_member(business_id));

CREATE POLICY whatsapp_channels_insert ON public.whatsapp_channels
  FOR INSERT
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

CREATE POLICY whatsapp_channels_update ON public.whatsapp_channels
  FOR UPDATE
  USING  (public.has_business_role(business_id, ARRAY['owner','admin']))
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

-- =============================================================================
-- 4. RPC create_whatsapp_flow_appointment
--
--    Crea una cita de forma atómica e idempotente a partir de una respuesta
--    nfm_reply del Flow de reservación. Solo ejecutable por service_role.
--
--    Retorna siempre exactamente una fila:
--      - created_new=true  → cita nueva creada
--      - created_new=false → cita existente (idempotencia)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.create_whatsapp_flow_appointment(
  p_phone_number_id       text,
  p_customer_phone_e164   text,
  p_customer_display_name text,
  p_service_code          text,
  p_extra_codes           text[],
  p_appointment_date      date,
  p_appointment_time      text,
  p_flow_version          text,
  p_external_reference    text
)
RETURNS TABLE (
  appointment_id  uuid,
  business_id     uuid,
  created_new     boolean,
  status          text,
  starts_at       timestamptz,
  ends_at         timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- Canal y negocio
  v_bid              uuid;
  v_timezone         text;
  v_business_status  text;
  -- Tiempo
  v_hh               integer;
  v_mm               integer;
  v_appt_time        time;
  v_local_starts_at  timestamp;
  v_local_ends_at    timestamp;
  v_starts_at        timestamptz;
  v_ends_at          timestamptz;
  v_business_today   date;
  v_weekday          integer;
  -- Servicio y extras
  v_service_id       uuid;
  v_total_mins       integer;
  v_extra_code       text;
  v_extra_id         uuid;
  v_extra_delta      integer;
  v_extra_ids        uuid[] := ARRAY[]::uuid[];
  -- Horario
  bh_is_closed       boolean;
  bh_opens_at        time;
  bh_closes_at       time;
  -- Idempotencia
  v_existing_id      uuid;
  v_existing_status  text;
  v_existing_starts  timestamptz;
  v_existing_ends    timestamptz;
  -- Escritura
  v_customer_id      uuid;
  v_appt_id          uuid;
BEGIN

  -- =========================================================================
  -- Paso 0 — Normalización y validaciones de input
  -- =========================================================================

  p_extra_codes := COALESCE(p_extra_codes, ARRAY[]::text[]);

  IF p_external_reference IS NULL OR p_external_reference = '' THEN
    RAISE EXCEPTION 'external_reference_required' USING ERRCODE = 'P0001';
  END IF;

  IF p_flow_version IS DISTINCT FROM 'appointment-booking-static-v1' THEN
    RAISE EXCEPTION 'invalid_flow_version' USING ERRCODE = 'P0001';
  END IF;

  IF NOT (p_appointment_time ~ '^\d{2}_\d{2}$') THEN
    RAISE EXCEPTION 'invalid_time_format' USING ERRCODE = 'P0001';
  END IF;

  v_hh := substring(p_appointment_time FROM 1 FOR 2)::integer;
  v_mm := substring(p_appointment_time FROM 4 FOR 2)::integer;

  IF v_hh > 23 OR v_mm > 59 THEN
    RAISE EXCEPTION 'invalid_time_value' USING ERRCODE = 'P0001';
  END IF;

  -- Rechazar más de 10 extras
  IF array_length(p_extra_codes, 1) > 10 THEN
    RAISE EXCEPTION 'too_many_extras' USING ERRCODE = 'P0001';
  END IF;

  -- Rechazar códigos de extra vacíos
  FOREACH v_extra_code IN ARRAY p_extra_codes LOOP
    IF v_extra_code = '' THEN
      RAISE EXCEPTION 'empty_extra_code' USING ERRCODE = 'P0001';
    END IF;
  END LOOP;

  -- Rechazar duplicados en p_extra_codes
  IF array_length(p_extra_codes, 1) IS NOT NULL AND
     (SELECT count(DISTINCT x) FROM unnest(p_extra_codes) AS x)
       <> array_length(p_extra_codes, 1)::bigint
  THEN
    RAISE EXCEPTION 'duplicate_extra_code' USING ERRCODE = 'P0001';
  END IF;

  -- =========================================================================
  -- Paso 1 — Resolver canal y negocio
  -- =========================================================================

  SELECT b.id, b.timezone, b.status
    INTO v_bid, v_timezone, v_business_status
    FROM public.whatsapp_channels wc
    JOIN public.businesses b ON b.id = wc.business_id
   WHERE wc.phone_number_id = p_phone_number_id
     AND wc.status = 'active'
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'channel_not_found_or_inactive' USING ERRCODE = 'P0001';
  END IF;

  IF v_business_status <> 'active' THEN
    RAISE EXCEPTION 'business_inactive' USING ERRCODE = 'P0001';
  END IF;

  -- =========================================================================
  -- Paso 2 — Validar timezone antes de usarlo
  --    Evita HTTP 500 repetido de Meta si hay un dato incorrecto en businesses.
  -- =========================================================================

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = v_timezone
  ) THEN
    RAISE EXCEPTION 'invalid_business_timezone' USING ERRCODE = 'P0001';
  END IF;

  -- =========================================================================
  -- Paso 3 — Advisory lock para idempotencia concurrente
  --    La clave combina business_id + external_reference para evitar
  --    colisiones entre negocios distintos con el mismo reference.
  --    El lock se libera automáticamente al terminar la transacción.
  -- =========================================================================

  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_bid::text || ':' || p_external_reference, 0::bigint)
  );

  -- =========================================================================
  -- Paso 4 — Re-check de idempotencia (después del lock)
  -- =========================================================================

  SELECT a.id, a.status, a.starts_at, a.ends_at
    INTO v_existing_id, v_existing_status, v_existing_starts, v_existing_ends
    FROM public.appointments a
   WHERE a.business_id = v_bid
     AND a.external_reference = p_external_reference;

  IF FOUND THEN
    RETURN QUERY
      SELECT v_existing_id, v_bid, false, v_existing_status,
             v_existing_starts, v_existing_ends;
    RETURN;
  END IF;

  -- =========================================================================
  -- Paso 5 — Validaciones de negocio
  -- =========================================================================

  -- Calcular fecha actual en timezone del negocio (una sola vez)
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE v_timezone)::date;

  IF p_appointment_date < v_business_today THEN
    RAISE EXCEPTION 'appointment_date_in_the_past' USING ERRCODE = 'P0001';
  END IF;

  IF p_appointment_date > v_business_today + 365 THEN
    RAISE EXCEPTION 'appointment_date_too_far' USING ERRCODE = 'P0001';
  END IF;

  -- Resolver servicio
  SELECT s.id, s.duration_minutes
    INTO v_service_id, v_total_mins
    FROM public.services s
   WHERE s.business_id = v_bid
     AND s.code = p_service_code
     AND s.active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'service_not_found_or_inactive' USING ERRCODE = 'P0001';
  END IF;

  -- Procesar extras: validar existencia, pertenencia al servicio y acumular duración
  FOREACH v_extra_code IN ARRAY p_extra_codes LOOP

    SELECT e.id, e.duration_delta_minutes
      INTO v_extra_id, v_extra_delta
      FROM public.extras e
     WHERE e.business_id = v_bid
       AND e.code = v_extra_code
       AND e.active = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'extra_not_found_or_inactive' USING ERRCODE = 'P0001';
    END IF;

    PERFORM 1
      FROM public.service_extras se
     WHERE se.business_id = v_bid
       AND se.service_id  = v_service_id
       AND se.extra_id    = v_extra_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'extra_not_allowed_for_service' USING ERRCODE = 'P0001';
    END IF;

    v_total_mins := v_total_mins + v_extra_delta;
    v_extra_ids  := v_extra_ids  || v_extra_id;

  END LOOP;

  -- =========================================================================
  -- Paso 6 — Validación de horario con timestamps locales
  -- =========================================================================

  v_weekday := EXTRACT(DOW FROM p_appointment_date)::integer;

  SELECT bh.is_closed, bh.opens_at, bh.closes_at
    INTO bh_is_closed, bh_opens_at, bh_closes_at
    FROM public.business_hours bh
   WHERE bh.business_id = v_bid
     AND bh.weekday     = v_weekday;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_business_hours_configured' USING ERRCODE = 'P0001';
  END IF;

  IF bh_is_closed THEN
    RAISE EXCEPTION 'business_closed_on_weekday' USING ERRCODE = 'P0001';
  END IF;

  -- Construir timestamps locales sin zona
  v_appt_time      := (lpad(v_hh::text, 2, '0') || ':' || lpad(v_mm::text, 2, '0'))::time;
  v_local_starts_at := p_appointment_date::timestamp + v_appt_time;
  v_local_ends_at   := v_local_starts_at + make_interval(mins => v_total_mins);

  -- Validar inicio dentro de horario
  IF v_local_starts_at::time < bh_opens_at THEN
    RAISE EXCEPTION 'appointment_outside_business_hours' USING ERRCODE = 'P0001';
  END IF;

  -- Validar fin dentro de horario
  IF v_local_ends_at::time > bh_closes_at THEN
    RAISE EXCEPTION 'appointment_ends_after_closing' USING ERRCODE = 'P0001';
  END IF;

  -- Validar que no cruza medianoche local
  IF v_local_ends_at::date <> p_appointment_date THEN
    RAISE EXCEPTION 'appointment_crosses_midnight' USING ERRCODE = 'P0001';
  END IF;

  -- =========================================================================
  -- Paso 7 — Convertir a timestamptz usando timezone del negocio
  -- =========================================================================

  v_starts_at := v_local_starts_at AT TIME ZONE v_timezone;
  v_ends_at   := v_local_ends_at   AT TIME ZONE v_timezone;

  -- =========================================================================
  -- Paso 8 — Escritura atómica
  -- =========================================================================

  -- Upsert customer (idempotente: actualiza display_name solo si se provee uno nuevo)
  -- Alias explícito "c" para evitar ambigüedad con el output param "business_id"
  -- del RETURNS TABLE. ON CONFLICT referencia el constraint por nombre para
  -- evitar que "business_id" en la lista de columnas sea ambiguo.
  INSERT INTO public.customers AS c (business_id, whatsapp_phone_e164, display_name)
  VALUES (v_bid, p_customer_phone_e164, p_customer_display_name)
  ON CONFLICT ON CONSTRAINT customers_business_id_whatsapp_phone_e164_key
    DO UPDATE SET
      display_name = COALESCE(EXCLUDED.display_name, c.display_name),
      updated_at   = now()
  RETURNING c.id INTO v_customer_id;

  -- Insert appointment
  -- Alias "ap" para evitar ambigüedad con output params status/starts_at/ends_at
  INSERT INTO public.appointments AS ap (
    business_id, customer_id, service_id,
    starts_at, ends_at, status, source,
    flow_version, external_reference, created_by
  )
  VALUES (
    v_bid, v_customer_id, v_service_id,
    v_starts_at, v_ends_at, 'pending', 'whatsapp_flow',
    p_flow_version, p_external_reference, NULL
  )
  RETURNING ap.id INTO v_appt_id;

  -- Insert appointment_extras (0 filas si no hay extras)
  INSERT INTO public.appointment_extras AS ae (business_id, appointment_id, extra_id)
  SELECT v_bid, v_appt_id, e
  FROM unnest(v_extra_ids) AS e;

  RETURN QUERY
    SELECT v_appt_id, v_bid, true, 'pending'::text, v_starts_at, v_ends_at;

END;
$$;

-- =============================================================================
-- 5. REVOKE / GRANT de la RPC
--    Solo service_role puede ejecutar esta función (llamada desde Edge Function).
-- =============================================================================

REVOKE EXECUTE ON FUNCTION public.create_whatsapp_flow_appointment(
  text, text, text, text, text[], date, text, text, text
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.create_whatsapp_flow_appointment(
  text, text, text, text, text[], date, text, text, text
) FROM anon;

REVOKE EXECUTE ON FUNCTION public.create_whatsapp_flow_appointment(
  text, text, text, text, text[], date, text, text, text
) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.create_whatsapp_flow_appointment(
  text, text, text, text, text[], date, text, text, text
) TO service_role;
