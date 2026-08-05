-- =============================================================================
-- Smoke tests: Ingestión de booking vía WhatsApp Flows (Corte 5)
-- Requiere: supabase start + supabase db reset --local
--
-- Uso:
--   psql postgresql://postgres:postgres@localhost:54322/postgres \
--     -f tests/booking-ingestion-smoke.sql
--
-- UUIDs de prueba: prefijo 00000000-0000-0000-bb00-
-- Seed: canal sintético phone_number_id='000000000000002',
--       negocio '00000000-0000-0000-0000-000000000001'
--
-- Todos los DO blocks limpian sus datos al finalizar.
--
-- REGLA DE FECHAS:
--   - Nunca usar CURRENT_DATE en tests que llegan a la validación de fecha.
--   - Usar v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date
--     para que el cálculo sea coherente con la RPC.
--   - Tests que fallan antes de la validación de fecha (T02-T08, T19-T21, T26)
--     pueden mantener CURRENT_DATE + 7 sin riesgo.
-- =============================================================================

-- =============================================================================
-- T01 — Canal válido crea cita (prueba positiva base)
-- =============================================================================
DO $$
DECLARE
  v_result         record;
  v_business_today date;
  v_next_monday    date;
  v_bid            uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  -- Anclar toda la aritmética de fecha al timezone del negocio
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  -- Limpiar residuos de ejecuciones previas fallidas
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T01-basic';

  SET LOCAL ROLE service_role;

  SELECT * INTO v_result FROM public.create_whatsapp_flow_appointment(
    '000000000000002',
    '+5219990000099',
    'Test Customer T01',
    'haircut',
    NULL,
    v_next_monday,
    '10_00',
    'appointment-booking-static-v1',
    'smoke-T01-basic'
  );

  RESET ROLE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'T01 FAIL: RPC retorno 0 filas';
  END IF;
  IF NOT v_result.created_new THEN
    RAISE EXCEPTION 'T01 FAIL: esperado created_new=true';
  END IF;
  IF v_result.status <> 'pending' THEN
    RAISE EXCEPTION 'T01 FAIL: esperado status=pending, obtenido: %', v_result.status;
  END IF;
  IF v_result.appointment_id IS NULL THEN
    RAISE EXCEPTION 'T01 FAIL: appointment_id es NULL';
  END IF;

  RAISE NOTICE 'T01 PASS: canal valido crea cita (created_new=true, status=pending)';

  -- Cleanup
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T01-basic';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000099';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T01-basic';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000099';
  RAISE;
END;
$$;

-- =============================================================================
-- T02 — Canal inexistente → rechazado
--        CURRENT_DATE+7 es seguro: falla antes de la validación de fecha.
-- =============================================================================
DO $$
DECLARE
  v_caught boolean := false;
  v_err    text;
BEGIN
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '999999999999999',
      '+5219990000099',
      NULL, 'haircut', NULL,
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1',
      'smoke-T02-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T02 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'channel_not_found_or_inactive' THEN
    RAISE EXCEPTION 'T02 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T02 PASS: canal inexistente rechazado';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T03 — Canal inactivo → rechazado
-- =============================================================================
DO $$
DECLARE
  v_caught  boolean := false;
  v_err     text;
  v_bid     uuid := '00000000-0000-0000-0000-000000000001';
  v_chan_id uuid := '00000000-0000-0000-bb00-000000000001';
BEGIN
  INSERT INTO public.whatsapp_channels (id, business_id, waba_id, phone_number_id, status)
  VALUES (v_chan_id, v_bid, '000000000999001', '000000000099901', 'inactive');

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000099901',
      '+5219990000099',
      NULL, 'haircut', NULL,
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1',
      'smoke-T03-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  DELETE FROM public.whatsapp_channels WHERE id = v_chan_id;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T03 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'channel_not_found_or_inactive' THEN
    RAISE EXCEPTION 'T03 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T03 PASS: canal inactivo rechazado';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.whatsapp_channels WHERE id = v_chan_id;
  RAISE;
END;
$$;

-- =============================================================================
-- T04 — Negocio inactivo → rechazado
-- =============================================================================
DO $$
DECLARE
  v_caught  boolean := false;
  v_err     text;
  v_bid2    uuid := '00000000-0000-0000-bb00-000000000010';
  v_chan_id uuid := '00000000-0000-0000-bb00-000000000011';
BEGIN
  INSERT INTO public.businesses (id, name, slug, timezone, status)
  VALUES (v_bid2, 'Negocio Inactivo T04', 'negocio-inactivo-t04', 'America/Mexico_City', 'inactive');

  INSERT INTO public.whatsapp_channels (id, business_id, waba_id, phone_number_id, status)
  VALUES (v_chan_id, v_bid2, '000000000999002', '000000000099902', 'active');

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000099902',
      '+5219990000099',
      NULL, 'haircut', NULL,
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1',
      'smoke-T04-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  DELETE FROM public.whatsapp_channels WHERE id = v_chan_id;
  DELETE FROM public.businesses WHERE id = v_bid2;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T04 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'business_inactive' THEN
    RAISE EXCEPTION 'T04 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T04 PASS: negocio inactivo rechazado';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.whatsapp_channels WHERE id = v_chan_id;
  DELETE FROM public.businesses WHERE id = v_bid2;
  RAISE;
END;
$$;

-- =============================================================================
-- T05 — Servicio inexistente → rechazado
-- =============================================================================
DO $$
DECLARE
  v_caught boolean := false;
  v_err    text;
BEGIN
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002',
      '+5219990000099',
      NULL, 'servicio_inexistente_xyz', NULL,
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1',
      'smoke-T05-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T05 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'service_not_found_or_inactive' THEN
    RAISE EXCEPTION 'T05 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T05 PASS: servicio inexistente rechazado';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T06 — Servicio inactivo → rechazado
-- =============================================================================
DO $$
DECLARE
  v_caught  boolean := false;
  v_err     text;
  v_bid     uuid := '00000000-0000-0000-0000-000000000001';
  v_svc_id  uuid := '00000000-0000-0000-bb00-000000000020';
BEGIN
  INSERT INTO public.services (id, business_id, code, name, duration_minutes, active, sort_order)
  VALUES (v_svc_id, v_bid, 'svc_inactivo_t06', 'Servicio Inactivo T06', 30, false, 99);

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002',
      '+5219990000099',
      NULL, 'svc_inactivo_t06', NULL,
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1',
      'smoke-T06-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  DELETE FROM public.services WHERE id = v_svc_id;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T06 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'service_not_found_or_inactive' THEN
    RAISE EXCEPTION 'T06 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T06 PASS: servicio inactivo rechazado';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.services WHERE id = v_svc_id;
  RAISE;
END;
$$;

-- =============================================================================
-- T07 — Extra inexistente → rechazado
-- =============================================================================
DO $$
DECLARE
  v_caught boolean := false;
  v_err    text;
BEGIN
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002',
      '+5219990000099',
      NULL, 'haircut', ARRAY['extra_inexistente_xyz'],
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1',
      'smoke-T07-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T07 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'extra_not_found_or_inactive' THEN
    RAISE EXCEPTION 'T07 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T07 PASS: extra inexistente rechazado';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T08 — Extra no permitido para el servicio → rechazado
--        Se crea un extra sin enlace service_extras al servicio 'haircut'.
-- =============================================================================
DO $$
DECLARE
  v_caught  boolean := false;
  v_err     text;
  v_bid     uuid := '00000000-0000-0000-0000-000000000001';
  v_ext_id  uuid := '00000000-0000-0000-bb00-000000000030';
BEGIN
  INSERT INTO public.extras (id, business_id, code, name, duration_delta_minutes, active, sort_order)
  VALUES (v_ext_id, v_bid, 'extra_sin_enlace_t08', 'Extra Sin Enlace T08', 5, true, 99);
  -- Sin INSERT en service_extras → extra no permitido para 'haircut'

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002',
      '+5219990000099',
      NULL, 'haircut', ARRAY['extra_sin_enlace_t08'],
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1',
      'smoke-T08-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  DELETE FROM public.extras WHERE id = v_ext_id;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T08 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'extra_not_allowed_for_service' THEN
    RAISE EXCEPTION 'T08 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T08 PASS: extra no permitido para el servicio rechazado';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.extras WHERE id = v_ext_id;
  RAISE;
END;
$$;

-- =============================================================================
-- T09 — Fecha pasada → rechazada
--        v_past_date = business_today - 1 para evitar la ventana UTC/CDMX.
-- =============================================================================
DO $$
DECLARE
  v_caught         boolean := false;
  v_err            text;
  v_business_today date;
  v_past_date      date;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_past_date      := v_business_today - 1;

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002',
      '+5219990000099',
      NULL, 'haircut', NULL,
      v_past_date, '10_00',
      'appointment-booking-static-v1',
      'smoke-T09-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T09 FAIL: esperada excepcion P0001 pero no se lanzo (past_date=%)', v_past_date;
  END IF;
  IF v_err <> 'appointment_date_in_the_past' THEN
    RAISE EXCEPTION 'T09 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T09 PASS: fecha pasada (%) rechazada', v_past_date;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T10 — Hora de inicio fuera de horario (07:00, antes de 09:00) → rechazada
-- =============================================================================
DO $$
DECLARE
  v_caught         boolean := false;
  v_err            text;
  v_business_today date;
  v_next_monday    date;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002',
      '+5219990000099',
      NULL, 'haircut', NULL,
      v_next_monday, '07_00',
      'appointment-booking-static-v1',
      'smoke-T10-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T10 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'appointment_outside_business_hours' THEN
    RAISE EXCEPTION 'T10 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T10 PASS: hora fuera de horario rechazada';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T11 — Día cerrado (domingo) → rechazado
-- =============================================================================
DO $$
DECLARE
  v_caught         boolean := false;
  v_err            text;
  v_business_today date;
  v_next_sunday    date;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  -- Próximo domingo siempre en el futuro (mínimo +1 si hoy es sábado)
  v_next_sunday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 7 WHEN 1 THEN 6 WHEN 2 THEN 5
      WHEN 3 THEN 4 WHEN 4 THEN 3 WHEN 5 THEN 2 WHEN 6 THEN 1
    END
  );

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002',
      '+5219990000099',
      NULL, 'haircut', NULL,
      v_next_sunday, '10_00',
      'appointment-booking-static-v1',
      'smoke-T11-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T11 FAIL: esperada excepcion P0001 pero no se lanzo (next_sunday=%)', v_next_sunday;
  END IF;
  IF v_err <> 'business_closed_on_weekday' THEN
    RAISE EXCEPTION 'T11 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T11 PASS: domingo (%) cerrado rechazado', v_next_sunday;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T12-T16 — Verificación detallada del estado de BD tras cita válida
--   T12: customer creado con whatsapp_phone_e164 correcto
--   T13: appointment con status=pending, source=whatsapp_flow
--   T14: appointment_extras (2 extras: wash + mask)
--   T15: starts_at respeta timezone America/Mexico_City
--   T16: ends_at = starts_at + duracion (haircut=30 + wash=10 + mask=15 = 55 min)
-- =============================================================================
DO $$
DECLARE
  v_result          record;
  v_business_today  date;
  v_next_monday     date;
  v_appt            record;
  v_customer        record;
  v_extras_count    integer;
  v_expected_starts timestamptz;
  v_bid             uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T12T16';

  SET LOCAL ROLE service_role;

  SELECT * INTO v_result FROM public.create_whatsapp_flow_appointment(
    '000000000000002',
    '+5219990000098',
    'Customer T12',
    'haircut',
    ARRAY['wash', 'mask'],
    v_next_monday,
    '10_00',
    'appointment-booking-static-v1',
    'smoke-T12T16'
  );

  RESET ROLE;

  -- T12: customer con whatsapp_phone_e164 correcto
  SELECT * INTO v_customer FROM public.customers
   WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000098';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'T12 FAIL: customer no creado con whatsapp_phone_e164 correcto';
  END IF;
  RAISE NOTICE 'T12 PASS: customer creado con whatsapp_phone_e164 correcto';

  -- T13: appointment con status=pending y source=whatsapp_flow
  SELECT * INTO v_appt FROM public.appointments WHERE id = v_result.appointment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'T13 FAIL: appointment no encontrado';
  END IF;
  IF v_appt.status <> 'pending' THEN
    RAISE EXCEPTION 'T13 FAIL: status incorrecto: %', v_appt.status;
  END IF;
  IF v_appt.source <> 'whatsapp_flow' THEN
    RAISE EXCEPTION 'T13 FAIL: source incorrecto: %', v_appt.source;
  END IF;
  RAISE NOTICE 'T13 PASS: appointment con status=pending y source=whatsapp_flow';

  -- T14: 2 appointment_extras
  SELECT count(*)::integer INTO v_extras_count
    FROM public.appointment_extras
   WHERE appointment_id = v_result.appointment_id;
  IF v_extras_count <> 2 THEN
    RAISE EXCEPTION 'T14 FAIL: esperados 2 appointment_extras, obtenidos: %', v_extras_count;
  END IF;
  RAISE NOTICE 'T14 PASS: 2 appointment_extras creados';

  -- T15: starts_at respeta timezone America/Mexico_City
  -- v_next_monday calculado en timezone del negocio — coherente con la RPC
  v_expected_starts := (v_next_monday::timestamp + TIME '10:00') AT TIME ZONE 'America/Mexico_City';
  IF v_appt.starts_at <> v_expected_starts THEN
    RAISE EXCEPTION 'T15 FAIL: starts_at incorrecto. Esperado: %, obtenido: %',
      v_expected_starts, v_appt.starts_at;
  END IF;
  RAISE NOTICE 'T15 PASS: starts_at respeta timezone America/Mexico_City';

  -- T16: ends_at = starts_at + 55 min (haircut=30 + wash=10 + mask=15)
  IF v_appt.ends_at <> v_appt.starts_at + INTERVAL '55 minutes' THEN
    RAISE EXCEPTION 'T16 FAIL: ends_at incorrecto. Esperado: %, obtenido: %',
      v_appt.starts_at + INTERVAL '55 minutes', v_appt.ends_at;
  END IF;
  RAISE NOTICE 'T16 PASS: ends_at = starts_at + 55 minutos';

  -- Cleanup
  DELETE FROM public.appointments WHERE id = v_result.appointment_id;
  DELETE FROM public.customers WHERE id = v_customer.id;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T12T16';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000098';
  RAISE;
END;
$$;

-- =============================================================================
-- T17 — Segundo intento con mismo external_reference → created_new=false, sin duplicado
-- =============================================================================
DO $$
DECLARE
  v_result1        record;
  v_result2        record;
  v_appt_count     integer;
  v_business_today date;
  v_next_monday    date;
  v_bid            uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T17-idem';

  SET LOCAL ROLE service_role;

  SELECT * INTO v_result1 FROM public.create_whatsapp_flow_appointment(
    '000000000000002', '+5219990000097', 'Customer T17',
    'haircut', NULL, v_next_monday, '11_00',
    'appointment-booking-static-v1', 'smoke-T17-idem'
  );

  SELECT * INTO v_result2 FROM public.create_whatsapp_flow_appointment(
    '000000000000002', '+5219990000097', 'Customer T17',
    'haircut', NULL, v_next_monday, '11_00',
    'appointment-booking-static-v1', 'smoke-T17-idem'
  );

  RESET ROLE;

  IF NOT v_result1.created_new THEN
    RAISE EXCEPTION 'T17 FAIL: primer llamado deberia retornar created_new=true';
  END IF;
  IF v_result2.created_new THEN
    RAISE EXCEPTION 'T17 FAIL: segundo llamado deberia retornar created_new=false';
  END IF;
  IF v_result1.appointment_id <> v_result2.appointment_id THEN
    RAISE EXCEPTION 'T17 FAIL: appointment_id diferente en segundo llamado';
  END IF;

  SELECT count(*)::integer INTO v_appt_count
    FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T17-idem';
  IF v_appt_count <> 1 THEN
    RAISE EXCEPTION 'T17 FAIL: esperada 1 cita, encontradas: %', v_appt_count;
  END IF;

  RAISE NOTICE 'T17 PASS: idempotencia — segundo intento retorna created_new=false, 1 sola cita';

  -- Cleanup
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T17-idem';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000097';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T17-idem';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000097';
  RAISE;
END;
$$;

-- =============================================================================
-- T18 — Mismo external_reference en negocios distintos → ambos created_new=true
--        El índice unique es (business_id, external_reference), no solo reference.
-- =============================================================================
DO $$
DECLARE
  v_result1        record;
  v_result2        record;
  v_bid2           uuid := '00000000-0000-0000-bb00-000000000040';
  v_chan2_id       uuid := '00000000-0000-0000-bb00-000000000041';
  v_svc2_id        uuid := '00000000-0000-0000-bb00-000000000042';
  v_bid1           uuid := '00000000-0000-0000-0000-000000000001';
  v_business_today date;
  v_next_monday    date;
  v_total_appts    integer;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  -- Setup: segundo negocio con canal, servicio y horario propios
  INSERT INTO public.businesses (id, name, slug, timezone, status)
  VALUES (v_bid2, 'Negocio T18', 'negocio-t18', 'America/Mexico_City', 'active');

  INSERT INTO public.services (id, business_id, code, name, duration_minutes, active, sort_order)
  VALUES (v_svc2_id, v_bid2, 'haircut', 'Corte T18', 30, true, 1);

  INSERT INTO public.business_hours (business_id, weekday, is_closed, opens_at, closes_at)
  VALUES
    (v_bid2, 0, true,  NULL,    NULL),
    (v_bid2, 1, false, '09:00', '19:00'),
    (v_bid2, 2, false, '09:00', '19:00'),
    (v_bid2, 3, false, '09:00', '19:00'),
    (v_bid2, 4, false, '09:00', '19:00'),
    (v_bid2, 5, false, '09:00', '19:00'),
    (v_bid2, 6, false, '09:00', '19:00');

  INSERT INTO public.whatsapp_channels (id, business_id, waba_id, phone_number_id, status)
  VALUES (v_chan2_id, v_bid2, '000000000999003', '000000000099903', 'active');

  -- Limpiar residuos
  DELETE FROM public.appointments WHERE business_id = v_bid1 AND external_reference = 'smoke-T18-shared-ref';

  SET LOCAL ROLE service_role;

  -- Primer llamado: negocio1
  SELECT * INTO v_result1 FROM public.create_whatsapp_flow_appointment(
    '000000000000002', '+5219990000096', NULL,
    'haircut', NULL, v_next_monday, '10_00',
    'appointment-booking-static-v1', 'smoke-T18-shared-ref'
  );

  -- Segundo llamado: negocio2 (mismo reference, distinto negocio)
  SELECT * INTO v_result2 FROM public.create_whatsapp_flow_appointment(
    '000000000099903', '+5219990000096', NULL,
    'haircut', NULL, v_next_monday, '10_00',
    'appointment-booking-static-v1', 'smoke-T18-shared-ref'
  );

  RESET ROLE;

  IF NOT v_result1.created_new THEN
    RAISE EXCEPTION 'T18 FAIL: resultado1 deberia ser created_new=true';
  END IF;
  IF NOT v_result2.created_new THEN
    RAISE EXCEPTION 'T18 FAIL: resultado2 deberia ser created_new=true';
  END IF;
  IF v_result1.business_id = v_result2.business_id THEN
    RAISE EXCEPTION 'T18 FAIL: business_id debe ser diferente en ambos resultados';
  END IF;

  SELECT count(*)::integer INTO v_total_appts
    FROM public.appointments WHERE external_reference = 'smoke-T18-shared-ref';
  IF v_total_appts <> 2 THEN
    RAISE EXCEPTION 'T18 FAIL: esperadas 2 citas (una por negocio), encontradas: %', v_total_appts;
  END IF;

  RAISE NOTICE 'T18 PASS: mismo external_reference en negocios distintos → ambos created_new=true';

  -- Cleanup
  DELETE FROM public.appointments WHERE external_reference = 'smoke-T18-shared-ref';
  DELETE FROM public.customers WHERE business_id IN (v_bid1, v_bid2) AND whatsapp_phone_e164 = '+5219990000096';
  DELETE FROM public.whatsapp_channels WHERE id = v_chan2_id;
  DELETE FROM public.business_hours WHERE business_id = v_bid2;
  DELETE FROM public.services WHERE id = v_svc2_id;
  DELETE FROM public.businesses WHERE id = v_bid2;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE external_reference = 'smoke-T18-shared-ref';
  DELETE FROM public.customers WHERE business_id IN (v_bid1, v_bid2) AND whatsapp_phone_e164 = '+5219990000096';
  DELETE FROM public.whatsapp_channels WHERE id = v_chan2_id;
  DELETE FROM public.business_hours WHERE business_id = v_bid2;
  DELETE FROM public.services WHERE id = v_svc2_id;
  DELETE FROM public.businesses WHERE id = v_bid2;
  RAISE;
END;
$$;

-- =============================================================================
-- T19 — RPC no ejecutable como anon
--        CURRENT_DATE+7 es seguro: falla antes de la validación de fecha.
-- =============================================================================
DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  SET LOCAL ROLE anon;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002', '+5219990000099', NULL,
      'haircut', NULL, CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1', 'smoke-T19-ref'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T19 FAIL: anon deberia recibir insufficient_privilege';
  END IF;
  RAISE NOTICE 'T19 PASS: anon no puede ejecutar la RPC';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T20 — RPC no ejecutable como authenticated
-- =============================================================================
DO $$
DECLARE
  v_caught boolean := false;
BEGIN
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002', '+5219990000099', NULL,
      'haircut', NULL, CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1', 'smoke-T20-ref'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T20 FAIL: authenticated deberia recibir insufficient_privilege';
  END IF;
  RAISE NOTICE 'T20 PASS: authenticated no puede ejecutar la RPC';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T21 — Dos códigos de extra duplicados → rechazados
--        CURRENT_DATE+7 es seguro: falla en validación de input (antes de fecha).
-- =============================================================================
DO $$
DECLARE
  v_caught boolean := false;
  v_err    text;
BEGIN
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002', '+5219990000099', NULL,
      'haircut', ARRAY['wash', 'wash'],
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1', 'smoke-T21-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T21 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'duplicate_extra_code' THEN
    RAISE EXCEPTION 'T21 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T21 PASS: extras duplicados rechazados';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T22 — extra_codes NULL → tratado como array vacío (cita sin extras)
-- =============================================================================
DO $$
DECLARE
  v_result         record;
  v_extras_count   integer;
  v_business_today date;
  v_next_monday    date;
  v_bid            uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T22-nullextras';

  SET LOCAL ROLE service_role;
  SELECT * INTO v_result FROM public.create_whatsapp_flow_appointment(
    '000000000000002', '+5219990000094', NULL,
    'haircut', NULL,
    v_next_monday, '10_00',
    'appointment-booking-static-v1', 'smoke-T22-nullextras'
  );
  RESET ROLE;

  IF NOT v_result.created_new THEN
    RAISE EXCEPTION 'T22 FAIL: esperado created_new=true';
  END IF;

  SELECT count(*)::integer INTO v_extras_count
    FROM public.appointment_extras WHERE appointment_id = v_result.appointment_id;
  IF v_extras_count <> 0 THEN
    RAISE EXCEPTION 'T22 FAIL: esperados 0 extras, encontrados: %', v_extras_count;
  END IF;

  RAISE NOTICE 'T22 PASS: extra_codes NULL tratado como array vacio, cita sin extras';

  -- Cleanup
  DELETE FROM public.appointments WHERE id = v_result.appointment_id;
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000094';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T22-nullextras';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000094';
  RAISE;
END;
$$;

-- =============================================================================
-- T23 — Cita cuya duración total termina después de closes_at → rechazada
--        haircut (30 min) a las 18:45 → termina 19:15 > 19:00
-- =============================================================================
DO $$
DECLARE
  v_caught         boolean := false;
  v_err            text;
  v_business_today date;
  v_next_monday    date;
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002', '+5219990000099', NULL,
      'haircut', NULL,
      v_next_monday, '18_45',
      'appointment-booking-static-v1', 'smoke-T23-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T23 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'appointment_ends_after_closing' THEN
    RAISE EXCEPTION 'T23 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T23 PASS: duracion que supera closes_at rechazada';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;

-- =============================================================================
-- T24 — Límite futuro de 365 días calculado con timezone del negocio
--
--   Parte A: business_today + 366 → rechazado (appointment_date_too_far)
--   Parte B: último lunes ≤ business_today + 365 → aceptado (boundary exacto)
-- =============================================================================
DO $$
DECLARE
  v_caught         boolean := false;
  v_err            text;
  v_business_today date;
  v_too_far        date;
  v_boundary_ok    date;
  v_result         record;
  v_bid            uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_too_far        := v_business_today + 366;

  -- --------------------------------------------------------------------
  -- Parte A: +366 días → debe ser rechazado
  -- --------------------------------------------------------------------
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002', '+5219990000099', NULL,
      'haircut', NULL,
      v_too_far, '10_00',
      'appointment-booking-static-v1', 'smoke-T24-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T24 FAIL (parte A): business_today+366 deberia ser rechazado pero no lanzo excepcion';
  END IF;
  IF v_err <> 'appointment_date_too_far' THEN
    RAISE EXCEPTION 'T24 FAIL (parte A): error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T24 PASS (parte A): business_today+366 (%) rechazado', v_too_far;

  -- --------------------------------------------------------------------
  -- Parte B: último lunes ≤ business_today + 365 → debe ser aceptado
  --   Fórmula: retroceder al lunes más cercano sin superar +365 días.
  --   (DOW + 6) % 7 = días a retroceder para llegar al lunes anterior o actual.
  --     DOW=0 (Dom) → 6   DOW=1 (Lun) → 0   DOW=2 (Mar) → 1
  --     DOW=3 (Mié) → 2   DOW=4 (Jue) → 3   DOW=5 (Vie) → 4
  --     DOW=6 (Sáb) → 5
  -- --------------------------------------------------------------------
  v_boundary_ok := v_business_today + 365;
  v_boundary_ok := v_boundary_ok
    - ((EXTRACT(DOW FROM v_boundary_ok)::integer + 6) % 7)::integer;
  -- v_boundary_ok es ahora el lunes más cercano ≤ business_today+365

  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T24-boundary';

  v_caught := false;
  v_err    := NULL;

  SET LOCAL ROLE service_role;
  BEGIN
    SELECT * INTO v_result FROM public.create_whatsapp_flow_appointment(
      '000000000000002', '+5219990000099', NULL,
      'haircut', NULL,
      v_boundary_ok, '10_00',
      'appointment-booking-static-v1', 'smoke-T24-boundary'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err    := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  -- Cleanup de la cita del boundary test
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T24-boundary';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000099';

  IF v_caught THEN
    RAISE EXCEPTION 'T24 FAIL (parte B): business_today+365 (lunes %) deberia ser aceptado, rechazado con: %',
      v_boundary_ok, v_err;
  END IF;
  IF NOT v_result.created_new THEN
    RAISE EXCEPTION 'T24 FAIL (parte B): esperado created_new=true para lunes %', v_boundary_ok;
  END IF;
  RAISE NOTICE 'T24 PASS (parte B): ultimo lunes <= business_today+365 (%) aceptado', v_boundary_ok;

EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T24-boundary';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000099';
  RAISE;
END;
$$;

-- =============================================================================
-- T25 — Segundo llamado secuencial con mismo external_reference → created_new=false
--        Prueba de idempotencia secuencial (sin concurrencia).
-- =============================================================================
DO $$
DECLARE
  v_result1        record;
  v_result2        record;
  v_appt_count     integer;
  v_business_today date;
  v_next_monday    date;
  v_bid            uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  v_business_today := (CURRENT_TIMESTAMP AT TIME ZONE 'America/Mexico_City')::date;
  v_next_monday := v_business_today + (
    CASE EXTRACT(DOW FROM v_business_today)::integer
      WHEN 0 THEN 1 WHEN 1 THEN 7 WHEN 2 THEN 6
      WHEN 3 THEN 5 WHEN 4 THEN 4 WHEN 5 THEN 3 WHEN 6 THEN 2
    END
  );

  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T25-sequential';

  SET LOCAL ROLE service_role;

  SELECT * INTO v_result1 FROM public.create_whatsapp_flow_appointment(
    '000000000000002', '+5219990000093', 'Customer T25',
    'haircut', NULL, v_next_monday, '12_00',
    'appointment-booking-static-v1', 'smoke-T25-sequential'
  );

  -- Segundo llamado idéntico en la misma sesión
  SELECT * INTO v_result2 FROM public.create_whatsapp_flow_appointment(
    '000000000000002', '+5219990000093', 'Customer T25',
    'haircut', NULL, v_next_monday, '12_00',
    'appointment-booking-static-v1', 'smoke-T25-sequential'
  );

  RESET ROLE;

  IF NOT v_result1.created_new THEN
    RAISE EXCEPTION 'T25 FAIL: primer llamado deberia ser created_new=true';
  END IF;
  IF v_result2.created_new THEN
    RAISE EXCEPTION 'T25 FAIL: segundo llamado deberia ser created_new=false';
  END IF;

  SELECT count(*)::integer INTO v_appt_count
    FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T25-sequential';
  IF v_appt_count <> 1 THEN
    RAISE EXCEPTION 'T25 FAIL: esperada 1 cita, encontradas: %', v_appt_count;
  END IF;

  RAISE NOTICE 'T25 PASS: idempotencia secuencial — segundo llamado retorna created_new=false, 1 sola cita';

  -- Cleanup
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T25-sequential';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000093';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  DELETE FROM public.appointments WHERE business_id = v_bid AND external_reference = 'smoke-T25-sequential';
  DELETE FROM public.customers WHERE business_id = v_bid AND whatsapp_phone_e164 = '+5219990000093';
  RAISE;
END;
$$;

-- =============================================================================
-- T26 — Código de extra vacío ('') → rechazado
--        CURRENT_DATE+7 es seguro: falla en validación de input (antes de fecha).
-- =============================================================================
DO $$
DECLARE
  v_caught boolean := false;
  v_err    text;
BEGIN
  SET LOCAL ROLE service_role;
  BEGIN
    PERFORM public.create_whatsapp_flow_appointment(
      '000000000000002', '+5219990000099', NULL,
      'haircut', ARRAY['wash', ''],
      CURRENT_DATE + 7, '10_00',
      'appointment-booking-static-v1', 'smoke-T26-ref'
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    v_err := SQLERRM;
    v_caught := true;
  END;
  RESET ROLE;

  IF NOT v_caught THEN
    RAISE EXCEPTION 'T26 FAIL: esperada excepcion P0001 pero no se lanzo';
  END IF;
  IF v_err <> 'empty_extra_code' THEN
    RAISE EXCEPTION 'T26 FAIL: error incorrecto: %', v_err;
  END IF;
  RAISE NOTICE 'T26 PASS: codigo de extra vacio rechazado';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END;
$$;
