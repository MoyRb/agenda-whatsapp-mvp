-- =============================================================================
-- Migración: Google Calendar Sync (Corte 6)
--
-- Depende de: 20260803120000_create_booking_core.sql
--             20260804120000_add_whatsapp_booking_ingestion.sql
--
-- Orden de secciones:
--   1.  Extensión vault
--   2.  ALTER TABLE appointments (calendar_event_id, calendar_synced_at)
--   3.  CREATE TABLE google_oauth_states
--   4.  CREATE TABLE google_calendar_connections
--   5.  CREATE TABLE calendar_sync_jobs
--   6.  Constraints, FK compuesta e índices
--   7.  Triggers updated_at
--   8.  Trigger AFTER INSERT on appointments (outbox atómico)
--   9.  ENABLE RLS + políticas
--   10. Backfill appointments pending sin job
--   11. 10 RPCs SECURITY DEFINER
--   12. REVOKE / GRANT
-- =============================================================================

-- =============================================================================
-- 1. Extensión vault
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS supabase_vault SCHEMA vault;

-- =============================================================================
-- 2. ALTER TABLE appointments
-- =============================================================================

ALTER TABLE public.appointments
  ADD COLUMN calendar_event_id  text,
  ADD COLUMN calendar_synced_at timestamptz;

-- Índice parcial único: un calendar_event_id por negocio (cuando no sea NULL)
CREATE UNIQUE INDEX appointments_calendar_event_id_idx
  ON public.appointments (business_id, calendar_event_id)
  WHERE calendar_event_id IS NOT NULL;

-- =============================================================================
-- 3. CREATE TABLE google_oauth_states
--    Almacena state tokens de OAuth para validar callbacks (single-use).
--    Sin política RLS para anon/authenticated: solo service_role vía RPC.
-- =============================================================================

CREATE TABLE public.google_oauth_states (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  state_hash  text        NOT NULL,
  nonce       text        NOT NULL,
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (state_hash)
);

-- =============================================================================
-- 4. CREATE TABLE google_calendar_connections
--    Sin política SELECT para authenticated: expone refresh_token_secret_id.
--    Acceso seguro solo vía RPC get_calendar_connection_info.
-- =============================================================================

CREATE TABLE public.google_calendar_connections (
  id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id             uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  calendar_id             text        NOT NULL DEFAULT 'primary' CHECK (calendar_id <> ''),
  google_account_email    text,
  refresh_token_secret_id uuid        NOT NULL,
  scopes                  text        NOT NULL
    DEFAULT 'https://www.googleapis.com/auth/calendar.events.owned',
  status                  text        NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','revoked','error')),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id)
);

-- =============================================================================
-- 5. CREATE TABLE calendar_sync_jobs
--    UNIQUE(appointment_id): un solo job por cita, durante toda su vida.
-- =============================================================================

CREATE TABLE public.calendar_sync_jobs (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  appointment_id    uuid        NOT NULL,
  status            text        NOT NULL DEFAULT 'pending'
    CHECK (status IN (
      'pending','processing','synced',
      'retryable_error','permanent_error','waiting_connection'
    )),
  calendar_event_id text,
  attempts          integer     NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts      integer     NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
  next_attempt_at   timestamptz NOT NULL DEFAULT now(),
  locked_until      timestamptz,
  last_error_code   text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (appointment_id)
);

-- =============================================================================
-- 6. Constraints, FK compuesta e índices
-- =============================================================================

-- FK compuesta: appointment debe pertenecer al mismo business
ALTER TABLE public.calendar_sync_jobs
  ADD CONSTRAINT calendar_sync_jobs_appointment_fk
    FOREIGN KEY (appointment_id, business_id)
    REFERENCES public.appointments (id, business_id) ON DELETE CASCADE;

-- Índices operacionales
CREATE INDEX calendar_sync_jobs_business_id_idx ON public.calendar_sync_jobs (business_id);

CREATE INDEX calendar_sync_jobs_claim_idx ON public.calendar_sync_jobs
  (status, next_attempt_at, locked_until)
  WHERE status IN ('pending','retryable_error','waiting_connection','processing');

CREATE INDEX calendar_sync_jobs_appointment_idx ON public.calendar_sync_jobs (appointment_id);

CREATE INDEX google_calendar_connections_business_id_idx
  ON public.google_calendar_connections (business_id);

CREATE INDEX google_oauth_states_business_id_idx ON public.google_oauth_states (business_id);

CREATE INDEX google_oauth_states_expires_idx
  ON public.google_oauth_states (expires_at)
  WHERE used_at IS NULL;

-- =============================================================================
-- 7. Triggers updated_at
-- =============================================================================

CREATE TRIGGER set_updated_at_google_calendar_connections
  BEFORE UPDATE ON public.google_calendar_connections
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER set_updated_at_calendar_sync_jobs
  BEFORE UPDATE ON public.calendar_sync_jobs
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- =============================================================================
-- 8. Trigger AFTER INSERT on appointments — outbox atómico
--    Solo encola citas de origen whatsapp_flow.
--    ON CONFLICT DO NOTHING garantiza idempotencia.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.enqueue_calendar_sync_on_appointment_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.source = 'whatsapp_flow' THEN
    INSERT INTO public.calendar_sync_jobs (business_id, appointment_id)
    VALUES (NEW.business_id, NEW.id)
    ON CONFLICT (appointment_id) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER appointments_enqueue_calendar_sync
  AFTER INSERT ON public.appointments
  FOR EACH ROW
  EXECUTE FUNCTION public.enqueue_calendar_sync_on_appointment_insert();

-- =============================================================================
-- 9. ENABLE RLS + políticas
-- =============================================================================

ALTER TABLE public.google_oauth_states          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.google_calendar_connections  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.calendar_sync_jobs           ENABLE ROW LEVEL SECURITY;

-- calendar_sync_jobs: miembros pueden ver sus jobs; modificación solo por service_role vía RPC
CREATE POLICY sync_jobs_select ON public.calendar_sync_jobs
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

-- google_oauth_states: sin política → solo service_role accede
-- google_calendar_connections: sin política → solo service_role accede

-- =============================================================================
-- 10. Backfill seguro: appointments pending de whatsapp_flow sin job existente
-- =============================================================================

INSERT INTO public.calendar_sync_jobs (business_id, appointment_id)
SELECT a.business_id, a.id
FROM   public.appointments a
WHERE  a.source = 'whatsapp_flow'
  AND  a.status = 'pending'
  AND  NOT EXISTS (
         SELECT 1 FROM public.calendar_sync_jobs j WHERE j.appointment_id = a.id
       )
ON CONFLICT (appointment_id) DO NOTHING;

-- =============================================================================
-- 11. RPCs SECURITY DEFINER (10 funciones, solo service_role salvo get_calendar_connection_info)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 11.1  store_oauth_state
--       Persiste el hash del state para validar callbacks OAuth.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.store_oauth_state(
  p_business_id uuid,
  p_state_hash  text,
  p_nonce       text,
  p_expires_at  timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_state_hash IS NULL OR p_state_hash = '' THEN
    RAISE EXCEPTION 'state_hash_required' USING ERRCODE = 'P0001';
  END IF;
  IF p_nonce IS NULL OR p_nonce = '' THEN
    RAISE EXCEPTION 'nonce_required' USING ERRCODE = 'P0001';
  END IF;

  -- Verificar que el business existe y está activo
  IF NOT EXISTS (
    SELECT 1 FROM public.businesses WHERE id = p_business_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'business_not_found_or_inactive' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.google_oauth_states (business_id, state_hash, nonce, expires_at)
  VALUES (p_business_id, p_state_hash, p_nonce, p_expires_at);
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.2  revoke_oauth_state
--       Valida y consume el state (single-use). Lanza P0001 si inválido.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.revoke_oauth_state(
  p_state_hash text
)
RETURNS TABLE (business_id uuid, nonce text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id          uuid;
  v_business_id uuid;
  v_nonce       text;
  v_expires_at  timestamptz;
  v_used_at     timestamptz;
BEGIN
  SELECT s.id, s.business_id, s.nonce, s.expires_at, s.used_at
    INTO v_id, v_business_id, v_nonce, v_expires_at, v_used_at
    FROM public.google_oauth_states s
   WHERE s.state_hash = p_state_hash
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'oauth_state_not_found' USING ERRCODE = 'P0001';
  END IF;
  IF v_used_at IS NOT NULL THEN
    RAISE EXCEPTION 'oauth_state_already_used' USING ERRCODE = 'P0001';
  END IF;
  IF v_expires_at < now() THEN
    RAISE EXCEPTION 'oauth_state_expired' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.google_oauth_states SET used_at = now() WHERE id = v_id;

  RETURN QUERY SELECT v_business_id, v_nonce, v_expires_at;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.3  store_google_calendar_connection
--       Guarda o actualiza la conexión con Google Calendar via Vault.
--       Reactiva jobs en waiting_connection → pending.
--       NUNCA loguea p_refresh_token.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.store_google_calendar_connection(
  p_business_id          uuid,
  p_calendar_id          text,
  p_google_account_email text,
  p_refresh_token        text,
  p_scopes               text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_connection_id uuid;
  v_old_secret_id uuid;
  v_secret_id     uuid;
BEGIN
  -- Verificar si ya existe conexión para este business
  SELECT gcc.id, gcc.refresh_token_secret_id
    INTO v_connection_id, v_old_secret_id
    FROM public.google_calendar_connections gcc
   WHERE gcc.business_id = p_business_id;

  IF FOUND THEN
    -- Actualizar: reutilizar el mismo UUID de secreto, actualizar valor en Vault.
    -- vault.update_secret evita DELETE+CREATE y no genera secretos huérfanos.
    PERFORM vault.update_secret(v_old_secret_id, p_refresh_token);
    v_secret_id := v_old_secret_id;

    UPDATE public.google_calendar_connections
       SET calendar_id             = p_calendar_id,
           google_account_email    = p_google_account_email,
           refresh_token_secret_id = v_secret_id,
           scopes                  = p_scopes,
           status                  = 'active',
           updated_at              = now()
     WHERE business_id = p_business_id
    RETURNING id INTO v_connection_id;
  ELSE
    -- Crear nuevo secret y conexión.
    -- Buscar primero por nombre determinístico: puede existir un secreto
    -- huérfano si se borró google_calendar_connections sin limpiar Vault.
    SELECT id INTO v_secret_id
      FROM vault.secrets
     WHERE name = 'google_rt_' || p_business_id::text;

    IF v_secret_id IS NOT NULL THEN
      -- Secreto huérfano encontrado: actualizar valor sin cambiar UUID
      PERFORM vault.update_secret(v_secret_id, p_refresh_token);
    ELSE
      -- No existe: crear nuevo secreto
      SELECT vault.create_secret(
        p_refresh_token,
        'google_rt_' || p_business_id::text,
        'Google Calendar refresh token'
      ) INTO v_secret_id;
    END IF;

    INSERT INTO public.google_calendar_connections (
      business_id, calendar_id, google_account_email,
      refresh_token_secret_id, scopes, status
    )
    VALUES (
      p_business_id, p_calendar_id, p_google_account_email,
      v_secret_id, p_scopes, 'active'
    )
    RETURNING id INTO v_connection_id;
  END IF;

  -- Reactivar jobs en espera de conexión
  UPDATE public.calendar_sync_jobs
     SET status          = 'pending',
         next_attempt_at = now(),
         updated_at      = now()
   WHERE business_id = p_business_id
     AND status      = 'waiting_connection';

  RETURN v_connection_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.4  get_calendar_connection_for_sync
--       Lee la conexión activa y descifra el refresh_token del Vault.
--       Solo service_role puede ejecutar.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_calendar_connection_for_sync(
  p_business_id uuid
)
RETURNS TABLE (
  connection_id        uuid,
  calendar_id          text,
  google_account_email text,
  refresh_token        text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_connection_id uuid;
  v_calendar_id   text;
  v_email         text;
  v_secret_id     uuid;
  v_token         text;
BEGIN
  SELECT gcc.id, gcc.calendar_id, gcc.google_account_email, gcc.refresh_token_secret_id
    INTO v_connection_id, v_calendar_id, v_email, v_secret_id
    FROM public.google_calendar_connections gcc
   WHERE gcc.business_id = p_business_id
     AND gcc.status      = 'active';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no_active_calendar_connection' USING ERRCODE = 'P0001';
  END IF;

  SELECT ds.decrypted_secret
    INTO v_token
    FROM vault.decrypted_secrets ds
   WHERE ds.id = v_secret_id;

  IF v_token IS NULL THEN
    RAISE EXCEPTION 'vault_secret_not_found' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY SELECT v_connection_id, v_calendar_id, v_email, v_token;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.5  update_calendar_connection_status
--       Actualiza status de conexión; reactiva jobs si status=active.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.update_calendar_connection_status(
  p_business_id uuid,
  p_status      text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_status NOT IN ('active','revoked','error') THEN
    RAISE EXCEPTION 'invalid_connection_status' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.google_calendar_connections
     SET status     = p_status,
         updated_at = now()
   WHERE business_id = p_business_id;

  IF p_status = 'active' THEN
    UPDATE public.calendar_sync_jobs
       SET status          = 'pending',
           next_attempt_at = now(),
           updated_at      = now()
     WHERE business_id = p_business_id
       AND status      = 'waiting_connection';
  END IF;

  IF p_status = 'revoked' THEN
    -- Liberar jobs processing para que otro worker no quede bloqueado
    UPDATE public.calendar_sync_jobs
       SET locked_until = NULL,
           updated_at   = now()
     WHERE business_id  = p_business_id
       AND status       = 'processing';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.6  get_calendar_connection_info
--       Devuelve solo campos seguros (sin refresh_token_secret_id).
--       Accesible por authenticated (única RPC del grupo con ese GRANT).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_calendar_connection_info(
  p_business_id uuid
)
RETURNS TABLE (
  calendar_id          text,
  google_account_email text,
  scopes               text,
  status               text,
  updated_at           timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
    SELECT gcc.calendar_id, gcc.google_account_email, gcc.scopes,
           gcc.status, gcc.updated_at
      FROM public.google_calendar_connections gcc
     WHERE gcc.business_id = p_business_id
       AND public.is_business_member(p_business_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.7  claim_calendar_sync_job
--       SELECT FOR UPDATE SKIP LOCKED: garantiza exclusión mutua entre workers.
--       Incrementa attempts y setea locked_until=now()+60s.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.claim_calendar_sync_job(
  p_business_id    uuid,
  p_appointment_id uuid
)
RETURNS TABLE (job_id uuid, appointment_id uuid, attempts integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_job_id   uuid;
  v_attempts integer;
BEGIN
  SELECT j.id, j.attempts
    INTO v_job_id, v_attempts
    FROM public.calendar_sync_jobs j
   WHERE j.appointment_id = p_appointment_id
     AND j.business_id    = p_business_id
     AND j.status IN ('pending','retryable_error','waiting_connection','processing')
     AND j.next_attempt_at <= now()
     AND j.attempts < j.max_attempts
     AND (j.locked_until IS NULL OR j.locked_until <= now())
   FOR UPDATE SKIP LOCKED;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  UPDATE public.calendar_sync_jobs
     SET status       = 'processing',
         locked_until = now() + INTERVAL '60 seconds',
         attempts     = v_attempts + 1,
         updated_at   = now()
   WHERE id = v_job_id;

  RETURN QUERY SELECT v_job_id, p_appointment_id, v_attempts + 1;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.8  complete_calendar_sync_job
--       Actualización atómica: job→synced + appointment→confirmed.
--       Idempotente: si appointment ya es confirmed, el UPDATE no modifica filas.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.complete_calendar_sync_job(
  p_job_id            uuid,
  p_business_id       uuid,
  p_calendar_event_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_appointment_id uuid;
BEGIN
  -- Actualizar job
  UPDATE public.calendar_sync_jobs
     SET status            = 'synced',
         calendar_event_id = p_calendar_event_id,
         locked_until      = NULL,
         last_error_code   = NULL,
         updated_at        = now()
   WHERE id          = p_job_id
     AND business_id = p_business_id
  RETURNING appointment_id INTO v_appointment_id;

  IF v_appointment_id IS NULL THEN
    RETURN;
  END IF;

  -- Actualizar appointment solo si sigue pending (no sobrescribir cancelled)
  UPDATE public.appointments
     SET status            = 'confirmed',
         calendar_event_id = p_calendar_event_id,
         calendar_synced_at = now(),
         updated_at        = now()
   WHERE id          = v_appointment_id
     AND business_id = p_business_id
     AND status      = 'pending';
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.9  fail_calendar_sync_job
--       Aplica backoff exponencial o marca como permanent_error.
--       Caso especial: no_active_calendar_connection → waiting_connection.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fail_calendar_sync_job(
  p_job_id       uuid,
  p_business_id  uuid,
  p_error_code   text,
  p_is_retryable boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_attempts       integer;
  v_max_attempts   integer;
  v_interval_secs  double precision;
BEGIN
  SELECT j.attempts, j.max_attempts
    INTO v_attempts, v_max_attempts
    FROM public.calendar_sync_jobs j
   WHERE j.id = p_job_id AND j.business_id = p_business_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Caso especial: sin conexión → waiting_connection (no permanent_error)
  IF p_error_code = 'no_active_calendar_connection' THEN
    UPDATE public.calendar_sync_jobs
       SET status          = 'waiting_connection',
           locked_until    = NULL,
           last_error_code = p_error_code,
           updated_at      = now()
     WHERE id = p_job_id AND business_id = p_business_id;
    RETURN;
  END IF;

  IF p_is_retryable AND v_attempts < v_max_attempts THEN
    -- Backoff exponencial: 30 * 4^(attempts-1) segundos
    -- attempt=1→30s, 2→120s, 3→480s, 4→1920s
    v_interval_secs := 30.0 * power(4.0, (v_attempts - 1)::double precision);
    UPDATE public.calendar_sync_jobs
       SET status          = 'retryable_error',
           next_attempt_at = now() + make_interval(secs => v_interval_secs),
           locked_until    = NULL,
           last_error_code = p_error_code,
           updated_at      = now()
     WHERE id = p_job_id AND business_id = p_business_id;
  ELSE
    UPDATE public.calendar_sync_jobs
       SET status          = 'permanent_error',
           locked_until    = NULL,
           last_error_code = p_error_code,
           updated_at      = now()
     WHERE id = p_job_id AND business_id = p_business_id;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 11.10 get_appointment_sync_data
--       Retorna datos de appointment para el worker de sincronización.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_appointment_sync_data(
  p_business_id    uuid,
  p_appointment_id uuid
)
RETURNS TABLE (
  appt_status       text,
  starts_at         timestamptz,
  ends_at           timestamptz,
  calendar_event_id text,
  service_name      text,
  business_timezone text,
  extras_names      text[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN QUERY
    SELECT
      a.status,
      a.starts_at,
      a.ends_at,
      a.calendar_event_id,
      s.name,
      b.timezone,
      COALESCE(
        array_agg(e.name ORDER BY e.name) FILTER (WHERE e.name IS NOT NULL),
        ARRAY[]::text[]
      )
    FROM public.appointments a
    JOIN public.services   s  ON s.id = a.service_id  AND s.business_id = a.business_id
    JOIN public.businesses b  ON b.id = a.business_id
    LEFT JOIN public.appointment_extras ae
           ON ae.appointment_id = a.id AND ae.business_id = a.business_id
    LEFT JOIN public.extras e
           ON e.id = ae.extra_id AND e.business_id = a.business_id
   WHERE a.id          = p_appointment_id
     AND a.business_id = p_business_id
   GROUP BY a.status, a.starts_at, a.ends_at, a.calendar_event_id, s.name, b.timezone;
END;
$$;

-- =============================================================================
-- 12. REVOKE / GRANT
-- =============================================================================

-- Función del trigger: solo postgres puede ejecutar (no se expone como RPC)
REVOKE EXECUTE ON FUNCTION public.enqueue_calendar_sync_on_appointment_insert() FROM PUBLIC;

-- store_oauth_state: solo service_role
REVOKE EXECUTE ON FUNCTION public.store_oauth_state(uuid, text, text, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.store_oauth_state(uuid, text, text, timestamptz) FROM anon;
REVOKE EXECUTE ON FUNCTION public.store_oauth_state(uuid, text, text, timestamptz) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.store_oauth_state(uuid, text, text, timestamptz) TO service_role;

-- revoke_oauth_state: solo service_role
REVOKE EXECUTE ON FUNCTION public.revoke_oauth_state(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.revoke_oauth_state(text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.revoke_oauth_state(text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.revoke_oauth_state(text) TO service_role;

-- store_google_calendar_connection: solo service_role
REVOKE EXECUTE ON FUNCTION public.store_google_calendar_connection(uuid, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.store_google_calendar_connection(uuid, text, text, text, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.store_google_calendar_connection(uuid, text, text, text, text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.store_google_calendar_connection(uuid, text, text, text, text) TO service_role;

-- get_calendar_connection_for_sync: solo service_role
REVOKE EXECUTE ON FUNCTION public.get_calendar_connection_for_sync(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_calendar_connection_for_sync(uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_calendar_connection_for_sync(uuid) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.get_calendar_connection_for_sync(uuid) TO service_role;

-- update_calendar_connection_status: solo service_role
REVOKE EXECUTE ON FUNCTION public.update_calendar_connection_status(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.update_calendar_connection_status(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.update_calendar_connection_status(uuid, text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.update_calendar_connection_status(uuid, text) TO service_role;

-- get_calendar_connection_info: service_role + authenticated (única excepción)
REVOKE EXECUTE ON FUNCTION public.get_calendar_connection_info(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_calendar_connection_info(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_calendar_connection_info(uuid) TO service_role;
GRANT  EXECUTE ON FUNCTION public.get_calendar_connection_info(uuid) TO authenticated;

-- claim_calendar_sync_job: solo service_role
REVOKE EXECUTE ON FUNCTION public.claim_calendar_sync_job(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.claim_calendar_sync_job(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.claim_calendar_sync_job(uuid, uuid) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.claim_calendar_sync_job(uuid, uuid) TO service_role;

-- complete_calendar_sync_job: solo service_role
REVOKE EXECUTE ON FUNCTION public.complete_calendar_sync_job(uuid, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_calendar_sync_job(uuid, uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.complete_calendar_sync_job(uuid, uuid, text) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.complete_calendar_sync_job(uuid, uuid, text) TO service_role;

-- fail_calendar_sync_job: solo service_role
REVOKE EXECUTE ON FUNCTION public.fail_calendar_sync_job(uuid, uuid, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.fail_calendar_sync_job(uuid, uuid, text, boolean) FROM anon;
REVOKE EXECUTE ON FUNCTION public.fail_calendar_sync_job(uuid, uuid, text, boolean) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.fail_calendar_sync_job(uuid, uuid, text, boolean) TO service_role;

-- get_appointment_sync_data: solo service_role
REVOKE EXECUTE ON FUNCTION public.get_appointment_sync_data(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_appointment_sync_data(uuid, uuid) FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_appointment_sync_data(uuid, uuid) FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.get_appointment_sync_data(uuid, uuid) TO service_role;
