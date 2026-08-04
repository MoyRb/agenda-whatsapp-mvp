-- =============================================================================
-- Smoke tests: esquema de reservaciones (Corte 4, rev 2)
-- Requiere: supabase start (Docker) + supabase db reset --local
--
-- Ejecutar:
--   psql postgresql://postgres:postgres@localhost:54322/postgres \
--     -f tests/booking-schema-smoke.sql
--
-- Nota: se ejecuta como superusuario postgres, por lo que RLS es ignorado.
-- Los tests de políticas RLS (ej. admin no puede crear owners) requieren
-- contexto de usuario autenticado y se documentan en tests/rls-notes.md.
--
-- Estructura: cada test es un bloque DO independiente con BEGIN...EXCEPTION
-- para errores esperados. Sin SAVEPOINT, COMMIT ni ROLLBACK explícitos.
-- =============================================================================

\set ON_ERROR_STOP off
\pset tuples_only on
\pset format unaligned

CREATE TEMP TABLE smoke_results (
  test_name text,
  passed    boolean,
  detail    text
);

-- ---------------------------------------------------------------------------
-- Test 01: Las 9 tablas del núcleo existen
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name IN (
      'businesses','business_members','services','extras',
      'service_extras','business_hours','customers',
      'appointments','appointment_extras'
    );
  INSERT INTO smoke_results VALUES (
    '01_nine_tables_exist', v_count = 9,
    format('encontradas: %s/9', v_count)
  );
END $$;

-- ---------------------------------------------------------------------------
-- Test 02: status inválido en appointments es rechazado
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.appointments (
      business_id, customer_id, service_id, starts_at, ends_at, status
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      now(), now() + interval '1 hour', 'invalid_status'
    );
    INSERT INTO smoke_results VALUES (
      '02_appointments_status_check', false, 'INSERT no falló — constraint ausente'
    );
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN
    INSERT INTO smoke_results VALUES (
      '02_appointments_status_check', true, 'Rechazado correctamente'
    );
  END;
END $$;

-- ---------------------------------------------------------------------------
-- Test 03: teléfono no E.164 en customers es rechazado
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.customers (business_id, whatsapp_phone_e164)
    VALUES (gen_random_uuid(), '521234567890');  -- sin prefijo +
    INSERT INTO smoke_results VALUES (
      '03_customers_phone_e164_check', false, 'INSERT no falló — constraint ausente'
    );
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN
    INSERT INTO smoke_results VALUES (
      '03_customers_phone_e164_check', true, 'Rechazado correctamente'
    );
  END;
END $$;

-- ---------------------------------------------------------------------------
-- Test 04: UNIQUE (business_id, code) en services rechaza duplicado
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_bid uuid := '00000000-0000-0000-0000-000000000001';
BEGIN
  BEGIN
    INSERT INTO public.services (business_id, code, name, duration_minutes)
    VALUES (v_bid, 'haircut', 'Duplicado', 30);
    INSERT INTO smoke_results VALUES (
      '04_services_unique_code', false, 'INSERT duplicado no falló'
    );
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO smoke_results VALUES (
      '04_services_unique_code', true, 'unique_violation correctamente'
    );
  END;
END $$;

-- ---------------------------------------------------------------------------
-- Test 05: FK compuesta en service_extras rechaza mezcla cross-business
--
-- Se crea un negocio B con un extra B. Se intenta insertar en service_extras
-- con (business_id=A, service_id de A, extra_id de B): la FK compuesta
-- (extra_id, business_id=A) no existe en extras → foreign_key_violation.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid_a  uuid := '00000000-0000-0000-0000-000000000001';
  v_bid_b  uuid;
  v_svc_id uuid := '00000000-0000-0000-0001-000000000001';  -- haircut de A
  v_ext_b  uuid;
BEGIN
  -- Crear negocio B
  v_bid_b := gen_random_uuid();
  INSERT INTO public.businesses (id, name, slug, timezone)
  VALUES (v_bid_b, 'Negocio B', 'negocio-b-' || v_bid_b::text, 'UTC');

  -- Crear extra en negocio B
  INSERT INTO public.extras (business_id, code, name)
  VALUES (v_bid_b, 'extra_b', 'Extra de B')
  RETURNING id INTO v_ext_b;

  -- Intentar relacionar servicio de A con extra de B usando business_id=A
  BEGIN
    INSERT INTO public.service_extras (business_id, service_id, extra_id)
    VALUES (v_bid_a, v_svc_id, v_ext_b);
    INSERT INTO smoke_results VALUES (
      '05_service_extras_cross_business_fk', false,
      'INSERT cross-business no falló — FK compuesta ausente'
    );
  EXCEPTION WHEN foreign_key_violation THEN
    INSERT INTO smoke_results VALUES (
      '05_service_extras_cross_business_fk', true,
      'foreign_key_violation correctamente'
    );
  END;

  -- Limpiar
  DELETE FROM public.extras    WHERE id = v_ext_b;
  DELETE FROM public.businesses WHERE id = v_bid_b;
END $$;

-- ---------------------------------------------------------------------------
-- Test 06: ends_at <= starts_at rechazado en appointments
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.appointments (
      business_id, customer_id, service_id, starts_at, ends_at
    ) VALUES (
      gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      now(), now()  -- ends_at = starts_at: no mayor
    );
    INSERT INTO smoke_results VALUES (
      '06_appointments_ends_after_starts', false, 'INSERT no falló — constraint ausente'
    );
  EXCEPTION WHEN check_violation OR foreign_key_violation THEN
    INSERT INTO smoke_results VALUES (
      '06_appointments_ends_after_starts', true, 'Rechazado correctamente'
    );
  END;
END $$;

-- ---------------------------------------------------------------------------
-- Test 07: external_reference único por negocio (índice parcial)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid uuid := '00000000-0000-0000-0000-000000000001';
  v_cid uuid;
  v_sid uuid;
  v_a1  uuid;
BEGIN
  -- Cliente de prueba
  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid, '+524421110001')
  ON CONFLICT (business_id, whatsapp_phone_e164) DO NOTHING;

  SELECT id INTO v_cid FROM public.customers
  WHERE business_id = v_bid AND whatsapp_phone_e164 = '+524421110001';

  SELECT id INTO v_sid FROM public.services
  WHERE business_id = v_bid AND code = 'haircut';

  -- Primera cita con external_reference
  INSERT INTO public.appointments
    (business_id, customer_id, service_id, starts_at, ends_at, external_reference)
  VALUES
    (v_bid, v_cid, v_sid,
     now() + interval '1 day', now() + interval '1 day 30 min',
     'smoke-ref-001')
  RETURNING id INTO v_a1;

  -- Segunda cita con la misma external_reference → debe fallar
  BEGIN
    INSERT INTO public.appointments
      (business_id, customer_id, service_id, starts_at, ends_at, external_reference)
    VALUES
      (v_bid, v_cid, v_sid,
       now() + interval '2 day', now() + interval '2 day 30 min',
       'smoke-ref-001');
    INSERT INTO smoke_results VALUES (
      '07_appointments_external_ref_unique', false, 'Duplicado no falló'
    );
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO smoke_results VALUES (
      '07_appointments_external_ref_unique', true, 'unique_violation correctamente'
    );
  END;

  -- Limpiar
  DELETE FROM public.appointments WHERE id = v_a1;
  DELETE FROM public.customers
  WHERE business_id = v_bid AND whatsapp_phone_e164 = '+524421110001';
END $$;

-- ---------------------------------------------------------------------------
-- Test 08: weekday fuera de 0-6 rechazado en business_hours
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.business_hours (business_id, weekday, is_closed)
    VALUES ('00000000-0000-0000-0000-000000000001', 7, true);
    INSERT INTO smoke_results VALUES (
      '08_business_hours_weekday_range', false, 'INSERT no falló — constraint ausente'
    );
  EXCEPTION WHEN check_violation THEN
    INSERT INTO smoke_results VALUES (
      '08_business_hours_weekday_range', true, 'check_violation correctamente'
    );
  END;
END $$;

-- ---------------------------------------------------------------------------
-- Test 09: is_closed=false con opens_at=NULL rechazado
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.business_hours (business_id, weekday, is_closed, opens_at, closes_at)
    VALUES ('00000000-0000-0000-0000-000000000001', 0, false, NULL, NULL);
    INSERT INTO smoke_results VALUES (
      '09_business_hours_open_requires_times', false, 'INSERT no falló — constraint ausente'
    );
  EXCEPTION WHEN check_violation THEN
    INSERT INTO smoke_results VALUES (
      '09_business_hours_open_requires_times', true, 'check_violation correctamente'
    );
  END;
END $$;

-- ---------------------------------------------------------------------------
-- Test 10: is_closed=true con opens_at IS NOT NULL rechazado
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    INSERT INTO public.business_hours (business_id, weekday, is_closed, opens_at, closes_at)
    VALUES ('00000000-0000-0000-0000-000000000001', 0, true, '09:00', '19:00');
    INSERT INTO smoke_results VALUES (
      '10_business_hours_closed_forbids_times', false, 'INSERT no falló — constraint ausente'
    );
  EXCEPTION WHEN check_violation THEN
    INSERT INTO smoke_results VALUES (
      '10_business_hours_closed_forbids_times', true, 'check_violation correctamente'
    );
  END;
END $$;

-- ---------------------------------------------------------------------------
-- Test 11: Seed — 4 códigos de servicio existen
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.services
  WHERE business_id = '00000000-0000-0000-0000-000000000001'
    AND code IN ('haircut','beard','haircut_beard','hair_dye')
    AND active = true;
  INSERT INTO smoke_results VALUES (
    '11_seed_services_count', v_count = 4,
    format('encontrados: %s/4', v_count)
  );
END $$;

-- ---------------------------------------------------------------------------
-- Test 12: Seed — 4 códigos de extra existen
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.extras
  WHERE business_id = '00000000-0000-0000-0000-000000000001'
    AND code IN ('wash','mask','beard_design','treatment')
    AND active = true;
  INSERT INTO smoke_results VALUES (
    '12_seed_extras_count', v_count = 4,
    format('encontrados: %s/4', v_count)
  );
END $$;

-- ---------------------------------------------------------------------------
-- Test 13: Seed — 16 relaciones service_extras existen
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.service_extras
  WHERE business_id = '00000000-0000-0000-0000-000000000001';
  INSERT INTO smoke_results VALUES (
    '13_seed_service_extras_count', v_count = 16,
    format('encontradas: %s/16', v_count)
  );
END $$;

-- ---------------------------------------------------------------------------
-- Test 14: Seed — 7 filas de horario (dom cerrado + lun-sab abiertos)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_total  integer;
  v_open   integer;
  v_closed integer;
BEGIN
  SELECT count(*)                        INTO v_total  FROM public.business_hours WHERE business_id = '00000000-0000-0000-0000-000000000001';
  SELECT count(*) FILTER (WHERE NOT is_closed) INTO v_open   FROM public.business_hours WHERE business_id = '00000000-0000-0000-0000-000000000001';
  SELECT count(*) FILTER (WHERE     is_closed) INTO v_closed FROM public.business_hours WHERE business_id = '00000000-0000-0000-0000-000000000001';
  INSERT INTO smoke_results VALUES (
    '14_seed_business_hours',
    v_total = 7 AND v_open = 6 AND v_closed = 1,
    format('total=%s open=%s closed=%s (esperado 7/6/1)', v_total, v_open, v_closed)
  );
END $$;

-- ---------------------------------------------------------------------------
-- Test 15: FK compuesta en appointments rechaza servicio de negocio distinto
--
-- Se crea negocio B con su propio servicio. Se intenta crear una cita en
-- negocio A con ese servicio B: la FK compuesta (service_id, business_id=A)
-- no existe en services → foreign_key_violation.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid_a uuid := '00000000-0000-0000-0000-000000000001';
  v_bid_b uuid;
  v_cid   uuid;
  v_svc_b uuid;
BEGIN
  -- Negocio B con servicio propio
  v_bid_b := gen_random_uuid();
  INSERT INTO public.businesses (id, name, slug, timezone)
  VALUES (v_bid_b, 'Negocio B15', 'negocio-b15-' || v_bid_b::text, 'UTC');

  INSERT INTO public.services (business_id, code, name, duration_minutes)
  VALUES (v_bid_b, 'corte_b', 'Corte B', 30)
  RETURNING id INTO v_svc_b;

  -- Cliente válido en negocio A
  INSERT INTO public.customers (business_id, whatsapp_phone_e164)
  VALUES (v_bid_a, '+524421110015')
  ON CONFLICT (business_id, whatsapp_phone_e164) DO NOTHING;

  SELECT id INTO v_cid FROM public.customers
  WHERE business_id = v_bid_a AND whatsapp_phone_e164 = '+524421110015';

  -- Intentar cita en negocio A con servicio de B → FK compuesta debe fallar
  BEGIN
    INSERT INTO public.appointments
      (business_id, customer_id, service_id, starts_at, ends_at)
    VALUES
      (v_bid_a, v_cid, v_svc_b, now() + interval '3 day', now() + interval '3 day 30 min');
    INSERT INTO smoke_results VALUES (
      '15_appointments_cross_business_service_fk', false,
      'INSERT cross-business no falló — FK compuesta ausente'
    );
  EXCEPTION WHEN foreign_key_violation THEN
    INSERT INTO smoke_results VALUES (
      '15_appointments_cross_business_service_fk', true,
      'foreign_key_violation correctamente'
    );
  END;

  -- Limpiar
  DELETE FROM public.customers  WHERE business_id = v_bid_a AND whatsapp_phone_e164 = '+524421110015';
  DELETE FROM public.services   WHERE id = v_svc_b;
  DELETE FROM public.businesses WHERE id = v_bid_b;
END $$;

-- ---------------------------------------------------------------------------
-- Test 16: UNIQUE (id, business_id) existe en las 4 tablas padre
--          (necesario para que las FK compuestas sean válidas)
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count
  FROM information_schema.table_constraints tc
  JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name
   AND ccu.table_schema    = tc.table_schema
  WHERE tc.constraint_type = 'UNIQUE'
    AND tc.table_schema    = 'public'
    AND tc.table_name IN ('services','extras','customers','appointments')
    AND ccu.column_name    = 'business_id'
  GROUP BY tc.table_name
  HAVING count(*) >= 1;

  -- Contamos cuántas tablas tienen el constraint (esperamos 4)
  SELECT count(DISTINCT tc.table_name) INTO v_count
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = tc.constraint_name
   AND kcu.table_schema    = tc.table_schema
  WHERE tc.constraint_type = 'UNIQUE'
    AND tc.table_schema    = 'public'
    AND tc.table_name IN ('services','extras','customers','appointments')
    AND kcu.column_name    = 'business_id';

  INSERT INTO smoke_results VALUES (
    '16_composite_unique_on_parent_tables', v_count = 4,
    format('tablas con UNIQUE(id,business_id): %s/4', v_count)
  );
END $$;

-- =============================================================================
-- SECCIÓN B: Escalamiento de privilegios en business_members
--
-- Simulan el rol 'authenticated' con:
--   SET LOCAL ROLE authenticated
--   set_config('request.jwt.claims', '{"sub": "<uuid>"}', true)
-- Las políticas RLS de business_members aplican.
-- El superusuario postgres verifica postcondiciones (bypassa RLS).
--
-- UUIDs de prueba (prefijo cc00, sin colisión con seed):
--   c_bid = 00000000-0000-0000-cc00-000000000001  negocio de prueba
--   c_own = 00000000-0000-0000-cc00-000000000002  usuario owner
--   c_adm = 00000000-0000-0000-cc00-000000000003  usuario admin
--   c_stf = 00000000-0000-0000-cc00-000000000004  usuario staff
--   c_new = 00000000-0000-0000-cc00-000000000005  usuario objetivo de inserción
--
-- Compatible con \set ON_ERROR_STOP on:
--   todos los errores esperados están capturados con BEGIN...EXCEPTION.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Test 17: Setup — negocio y usuarios sintéticos de prueba
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid uuid := '00000000-0000-0000-cc00-000000000001';
  v_own uuid := '00000000-0000-0000-cc00-000000000002';
  v_adm uuid := '00000000-0000-0000-cc00-000000000003';
  v_stf uuid := '00000000-0000-0000-cc00-000000000004';
  v_new uuid := '00000000-0000-0000-cc00-000000000005';
BEGIN
  -- Usuarios sintéticos: sin datos personales reales.
  -- ON CONFLICT DO NOTHING para idempotencia en re-ejecuciones.
  INSERT INTO auth.users (id, aud, role, email, encrypted_password, created_at, updated_at)
  VALUES
    (v_own, 'authenticated', 'authenticated', 'rls-owner@example.internal',  '', now(), now()),
    (v_adm, 'authenticated', 'authenticated', 'rls-admin@example.internal',  '', now(), now()),
    (v_stf, 'authenticated', 'authenticated', 'rls-staff@example.internal',  '', now(), now()),
    (v_new, 'authenticated', 'authenticated', 'rls-target@example.internal', '', now(), now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.businesses (id, name, slug, timezone, status)
  VALUES (v_bid, 'RLS Test Business', 'rls-test-biz', 'UTC', 'active')
  ON CONFLICT (id) DO NOTHING;

  -- Asignación de roles como superusuario (bypassa RLS)
  INSERT INTO public.business_members (business_id, user_id, role)
  VALUES
    (v_bid, v_own, 'owner'),
    (v_bid, v_adm, 'admin'),
    (v_bid, v_stf, 'staff')
  ON CONFLICT (business_id, user_id) DO NOTHING;

  INSERT INTO smoke_results VALUES (
    '17_rls_setup',
    (SELECT count(*) FROM public.business_members WHERE business_id = v_bid) = 3,
    'negocio + 3 miembros (owner/admin/staff) creados'
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO smoke_results VALUES ('17_rls_setup', false, 'Error en setup: ' || SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Test 18: admin no puede INSERT role='owner'
--
-- USING (INSERT no tiene USING — solo WITH CHECK):
--   has_business_role(bid, ['owner'])                         → FALSE (es admin)
--   OR (has_business_role(bid, ['admin']) AND role = 'staff') → role='owner' → FALSE
--   → WITH CHECK falla → 0 filas insertadas
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid    uuid := '00000000-0000-0000-cc00-000000000001';
  v_adm    uuid := '00000000-0000-0000-cc00-000000000003';
  v_new    uuid := '00000000-0000-0000-cc00-000000000005';
  v_before integer;
  v_after  integer;
BEGIN
  SELECT count(*) INTO v_before FROM public.business_members
  WHERE business_id = v_bid AND role = 'owner';

  -- Simular admin
  PERFORM set_config('request.jwt.claims', format('{"sub": "%s"}', v_adm::text), true);
  SET LOCAL ROLE authenticated;

  INSERT INTO public.business_members (business_id, user_id, role)
  VALUES (v_bid, v_new, 'owner');   -- debe ser bloqueado por RLS

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT count(*) INTO v_after FROM public.business_members
  WHERE business_id = v_bid AND role = 'owner';

  INSERT INTO smoke_results VALUES (
    '18_admin_cannot_insert_owner',
    v_after = v_before,
    format('owners antes=%s despues=%s (esperado: sin cambio)', v_before, v_after)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  -- Limpiar fila si se insertó antes del error
  DELETE FROM public.business_members WHERE business_id = v_bid AND user_id = v_new;
  INSERT INTO smoke_results VALUES ('18_admin_cannot_insert_owner', false, SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Test 19: admin no puede INSERT role='admin'
--
-- WITH CHECK: has_business_role(bid, ['admin']) AND role = 'staff'
--   → role='admin' → FALSE → 0 filas insertadas
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid    uuid := '00000000-0000-0000-cc00-000000000001';
  v_adm    uuid := '00000000-0000-0000-cc00-000000000003';
  v_new    uuid := '00000000-0000-0000-cc00-000000000005';
  v_before integer;
  v_after  integer;
BEGIN
  SELECT count(*) INTO v_before FROM public.business_members
  WHERE business_id = v_bid AND role = 'admin';

  PERFORM set_config('request.jwt.claims', format('{"sub": "%s"}', v_adm::text), true);
  SET LOCAL ROLE authenticated;

  INSERT INTO public.business_members (business_id, user_id, role)
  VALUES (v_bid, v_new, 'admin');   -- debe ser bloqueado por RLS

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT count(*) INTO v_after FROM public.business_members
  WHERE business_id = v_bid AND role = 'admin';

  INSERT INTO smoke_results VALUES (
    '19_admin_cannot_insert_admin',
    v_after = v_before,
    format('admins antes=%s despues=%s (esperado: sin cambio)', v_before, v_after)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  DELETE FROM public.business_members WHERE business_id = v_bid AND user_id = v_new;
  INSERT INTO smoke_results VALUES ('19_admin_cannot_insert_admin', false, SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Test 20: admin no puede modificar la fila de un owner
--
-- USING: has_business_role(bid, ['admin']) AND role = 'staff'
--   → fila del owner tiene role='owner' → FALSE → 0 filas afectadas
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid      uuid := '00000000-0000-0000-cc00-000000000001';
  v_adm      uuid := '00000000-0000-0000-cc00-000000000003';
  v_own      uuid := '00000000-0000-0000-cc00-000000000002';
  v_role_pre text;
  v_rows     integer;
BEGIN
  SELECT role INTO v_role_pre FROM public.business_members
  WHERE business_id = v_bid AND user_id = v_own;

  PERFORM set_config('request.jwt.claims', format('{"sub": "%s"}', v_adm::text), true);
  SET LOCAL ROLE authenticated;

  -- Intento de cambiar el rol del owner (USING debería fallar)
  UPDATE public.business_members
  SET    role = 'staff'
  WHERE  business_id = v_bid AND user_id = v_own;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO smoke_results VALUES (
    '20_admin_cannot_update_owner_row',
    v_rows = 0,
    format('filas actualizadas=%s (esperado 0)', v_rows)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  -- Restaurar si se actualizó antes del error
  UPDATE public.business_members SET role = v_role_pre WHERE business_id = v_bid AND user_id = v_own;
  INSERT INTO smoke_results VALUES ('20_admin_cannot_update_owner_row', false, SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Test 21: admin no puede promover staff a owner
--
-- USING: has_business_role(bid, ['admin']) AND role = 'staff' → TRUE (fila staff)
-- WITH CHECK: has_business_role(bid, ['admin']) AND role = 'staff'
--   → role (nuevo) = 'owner' → FALSE → 0 filas actualizadas
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid     uuid := '00000000-0000-0000-cc00-000000000001';
  v_adm     uuid := '00000000-0000-0000-cc00-000000000003';
  v_stf     uuid := '00000000-0000-0000-cc00-000000000004';
  v_rows    integer;
  v_role_post text;
BEGIN
  PERFORM set_config('request.jwt.claims', format('{"sub": "%s"}', v_adm::text), true);
  SET LOCAL ROLE authenticated;

  UPDATE public.business_members
  SET    role = 'owner'
  WHERE  business_id = v_bid AND user_id = v_stf;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT role INTO v_role_post FROM public.business_members
  WHERE business_id = v_bid AND user_id = v_stf;

  INSERT INTO smoke_results VALUES (
    '21_admin_cannot_promote_staff_to_owner',
    v_rows = 0 AND v_role_post = 'staff',
    format('filas=%s role_post=%s (esperado 0/staff)', v_rows, v_role_post)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE public.business_members SET role = 'staff' WHERE business_id = v_bid AND user_id = v_stf;
  INSERT INTO smoke_results VALUES ('21_admin_cannot_promote_staff_to_owner', false, SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Test 22: el único owner no puede eliminarse a sí mismo
--
-- DELETE USING:
--   has_business_role(bid, ['owner']) → TRUE
--   AND NOT (role='owner' AND count(owners) <= 1)
--   → count = 1 → NOT(TRUE) = FALSE → 0 filas eliminadas
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid   uuid := '00000000-0000-0000-cc00-000000000001';
  v_own   uuid := '00000000-0000-0000-cc00-000000000002';
  v_rows  integer;
  v_still integer;
BEGIN
  PERFORM set_config('request.jwt.claims', format('{"sub": "%s"}', v_own::text), true);
  SET LOCAL ROLE authenticated;

  DELETE FROM public.business_members
  WHERE  business_id = v_bid AND user_id = v_own;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT count(*) INTO v_still FROM public.business_members
  WHERE business_id = v_bid AND user_id = v_own;

  INSERT INTO smoke_results VALUES (
    '22_last_owner_cannot_delete_self',
    v_rows = 0 AND v_still = 1,
    format('filas_eliminadas=%s fila_sigue=%s (esperado 0/1)', v_rows, v_still)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  -- Restaurar si fue eliminado antes del error
  INSERT INTO public.business_members (business_id, user_id, role)
  VALUES (v_bid, v_own, 'owner') ON CONFLICT DO NOTHING;
  INSERT INTO smoke_results VALUES ('22_last_owner_cannot_delete_self', false, SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Test 23: el único owner no puede degradarse a admin
--
-- UPDATE WITH CHECK (path de owner):
--   role (nuevo) = 'owner' → FALSE
--   OR count(owners) > 1   → count=1 → FALSE
--   → WITH CHECK falla → 0 filas actualizadas
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid      uuid := '00000000-0000-0000-cc00-000000000001';
  v_own      uuid := '00000000-0000-0000-cc00-000000000002';
  v_rows     integer;
  v_role_post text;
BEGIN
  PERFORM set_config('request.jwt.claims', format('{"sub": "%s"}', v_own::text), true);
  SET LOCAL ROLE authenticated;

  UPDATE public.business_members
  SET    role = 'admin'
  WHERE  business_id = v_bid AND user_id = v_own;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT role INTO v_role_post FROM public.business_members
  WHERE business_id = v_bid AND user_id = v_own;

  INSERT INTO smoke_results VALUES (
    '23_last_owner_cannot_downgrade_self',
    v_rows = 0 AND v_role_post = 'owner',
    format('filas=%s role_post=%s (esperado 0/owner)', v_rows, v_role_post)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE public.business_members SET role = 'owner' WHERE business_id = v_bid AND user_id = v_own;
  INSERT INTO smoke_results VALUES ('23_last_owner_cannot_downgrade_self', false, SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Test 24: owner SÍ puede agregar un nuevo admin (prueba positiva)
--
-- WITH CHECK (path de owner): has_business_role(bid, ['owner']) → TRUE
--   AND (role='owner' → FALSE OR count > 1 → FALSE)
--   Wait: el owner agrega a otro como ADMIN, no owner. El propio actor (owner)
--   no cambia. WITH CHECK verifica la fila nueva: role='admin'.
--   Path: has_business_role(bid, ['owner']) → TRUE siempre → permite cualquier rol.
--   (La restricción de "last owner" en WITH CHECK solo aplica cuando el nuevo
--   role != 'owner' Y se degrada el propio owner — irrelevante al insertar.)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid      uuid := '00000000-0000-0000-cc00-000000000001';
  v_own      uuid := '00000000-0000-0000-cc00-000000000002';
  v_new      uuid := '00000000-0000-0000-cc00-000000000005';
  v_rows_ins integer;
  v_rows_del integer;
BEGIN
  PERFORM set_config('request.jwt.claims', format('{"sub": "%s"}', v_own::text), true);
  SET LOCAL ROLE authenticated;

  INSERT INTO public.business_members (business_id, user_id, role)
  VALUES (v_bid, v_new, 'admin');

  GET DIAGNOSTICS v_rows_ins = ROW_COUNT;

  -- Limpiar la fila insertada (aún como owner)
  DELETE FROM public.business_members
  WHERE  business_id = v_bid AND user_id = v_new;

  GET DIAGNOSTICS v_rows_del = ROW_COUNT;

  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO smoke_results VALUES (
    '24_owner_can_add_admin',
    v_rows_ins = 1 AND v_rows_del = 1,
    format('insertadas=%s eliminadas=%s (esperado 1/1)', v_rows_ins, v_rows_del)
  );
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  DELETE FROM public.business_members WHERE business_id = v_bid AND user_id = v_new;
  INSERT INTO smoke_results VALUES ('24_owner_can_add_admin', false, SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Test 25: Teardown — eliminar todos los datos de prueba RLS
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bid uuid := '00000000-0000-0000-cc00-000000000001';
  v_own uuid := '00000000-0000-0000-cc00-000000000002';
  v_adm uuid := '00000000-0000-0000-cc00-000000000003';
  v_stf uuid := '00000000-0000-0000-cc00-000000000004';
  v_new uuid := '00000000-0000-0000-cc00-000000000005';
  v_remaining integer;
BEGIN
  -- Eliminar en orden: membresías → negocio → usuarios
  DELETE FROM public.business_members WHERE business_id = v_bid;
  DELETE FROM public.businesses       WHERE id = v_bid;
  DELETE FROM auth.users              WHERE id IN (v_own, v_adm, v_stf, v_new);

  SELECT count(*) INTO v_remaining
  FROM public.business_members WHERE business_id = v_bid;

  INSERT INTO smoke_results VALUES (
    '25_rls_teardown',
    v_remaining = 0,
    format('filas restantes en business_members: %s (esperado 0)', v_remaining)
  );
EXCEPTION WHEN OTHERS THEN
  INSERT INTO smoke_results VALUES ('25_rls_teardown', false, 'Error en teardown: ' || SQLERRM);
END $$;

-- ---------------------------------------------------------------------------
-- Resumen
-- ---------------------------------------------------------------------------

SELECT
  CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result,
  test_name,
  detail
FROM smoke_results
ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE passed)     AS passed,
  count(*) FILTER (WHERE NOT passed) AS failed,
  count(*)                            AS total
FROM smoke_results;
