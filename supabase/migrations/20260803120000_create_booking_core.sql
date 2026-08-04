-- =============================================================================
-- Migración: Núcleo de datos multiempresa (Corte 4, rev 3)
--
-- Consistencia cross-business: foreign keys compuestas (no CHECK con subquery).
-- Orden de secciones:
--   1. Función genérica set_updated_at
--   2. CREATE TABLE (todas las tablas, en orden de dependencias FK simples)
--   3. Constraints UNIQUE compuestos, FKs compuestas e índices
--   4. Funciones helper RLS (DESPUÉS de que business_members exista)
--   5. REVOKE / GRANT de las funciones helper
--   6. ENABLE ROW LEVEL SECURITY
--   7. CREATE POLICY
--   8. Triggers updated_at
-- =============================================================================

-- =============================================================================
-- 1. FUNCIÓN GENÉRICA set_updated_at
--    No depende de ninguna tabla — se define primero.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- =============================================================================
-- 2. CREATE TABLE
--    Orden respetando dependencias de FK simples (REFERENCES inline).
--    Las FKs compuestas y UNIQUE(id, business_id) van en la sección 3.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2.1  businesses
-- ---------------------------------------------------------------------------

CREATE TABLE public.businesses (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text        NOT NULL,
  slug       text        NOT NULL,
  timezone   text        NOT NULL,
  status     text        NOT NULL DEFAULT 'active'
               CHECK (status IN ('active', 'inactive')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 2.2  business_members
--      FK simple a businesses (ya existe) y a auth.users (siempre existe).
-- ---------------------------------------------------------------------------

CREATE TABLE public.business_members (
  business_id uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  user_id     uuid        NOT NULL REFERENCES auth.users(id)        ON DELETE CASCADE,
  role        text        NOT NULL CHECK (role IN ('owner', 'admin', 'staff')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, user_id)
);

-- ---------------------------------------------------------------------------
-- 2.3  services
--      FK simple a businesses.
--      UNIQUE(id, business_id) → sección 3 (necesario para FKs compuestas).
-- ---------------------------------------------------------------------------

CREATE TABLE public.services (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id      uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  code             text        NOT NULL,
  name             text        NOT NULL,
  description      text,
  duration_minutes integer     NOT NULL CHECK (duration_minutes > 0),
  price_cents      integer     CHECK (price_cents IS NULL OR price_cents >= 0),
  active           boolean     NOT NULL DEFAULT true,
  sort_order       integer     NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, code)
);

-- ---------------------------------------------------------------------------
-- 2.4  extras
--      FK simple a businesses.
--      UNIQUE(id, business_id) → sección 3.
-- ---------------------------------------------------------------------------

CREATE TABLE public.extras (
  id                     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id            uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  code                   text        NOT NULL,
  name                   text        NOT NULL,
  duration_delta_minutes integer     NOT NULL DEFAULT 0,
  price_cents            integer     CHECK (price_cents IS NULL OR price_cents >= 0),
  active                 boolean     NOT NULL DEFAULT true,
  sort_order             integer     NOT NULL DEFAULT 0,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, code)
);

-- ---------------------------------------------------------------------------
-- 2.5  service_extras
--      Sin FKs inline: las FKs compuestas requieren UNIQUE(id, business_id)
--      en services y extras, que se agrega en la sección 3.
-- ---------------------------------------------------------------------------

CREATE TABLE public.service_extras (
  business_id uuid        NOT NULL,
  service_id  uuid        NOT NULL,
  extra_id    uuid        NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, service_id, extra_id)
);

-- ---------------------------------------------------------------------------
-- 2.6  business_hours
--      FK simple a businesses.
-- ---------------------------------------------------------------------------

CREATE TABLE public.business_hours (
  business_id uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
  weekday     integer     NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  is_closed   boolean     NOT NULL DEFAULT false,
  opens_at    time,
  closes_at   time,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, weekday),
  CONSTRAINT business_hours_closed_nulls CHECK (
    (    is_closed AND opens_at IS NULL     AND closes_at IS NULL) OR
    (NOT is_closed AND opens_at IS NOT NULL AND closes_at IS NOT NULL AND opens_at < closes_at)
  )
);

-- ---------------------------------------------------------------------------
-- 2.7  customers
--      FK simple a businesses.
--      UNIQUE(id, business_id) → sección 3.
-- ---------------------------------------------------------------------------

CREATE TABLE public.customers (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id         uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  whatsapp_phone_e164 text        NOT NULL
    CHECK (whatsapp_phone_e164 ~ '^\+[1-9]\d{7,14}$'),
  display_name        text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (business_id, whatsapp_phone_e164)
);

-- ---------------------------------------------------------------------------
-- 2.8  appointments
--      FK simple a businesses y a auth.users (ambos ya existen).
--      customer_id y service_id: columnas sin FK inline; las FKs compuestas
--      (que requieren UNIQUE en customers y services) van en la sección 3.
--      UNIQUE(id, business_id) → sección 3.
-- ---------------------------------------------------------------------------

CREATE TABLE public.appointments (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id        uuid        NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  customer_id        uuid        NOT NULL,
  service_id         uuid        NOT NULL,
  starts_at          timestamptz NOT NULL,
  ends_at            timestamptz NOT NULL,
  status             text        NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','confirmed','completed','cancelled','no_show')),
  source             text        NOT NULL DEFAULT 'whatsapp_flow'
    CHECK (source IN ('whatsapp_flow','admin','import')),
  flow_version       text,
  external_reference text,
  created_by         uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT appointments_ends_after_starts CHECK (ends_at > starts_at)
);

-- ---------------------------------------------------------------------------
-- 2.9  appointment_extras
--      Sin FKs inline: requieren UNIQUE(id, business_id) en appointments y
--      extras, que se agrega en la sección 3.
-- ---------------------------------------------------------------------------

CREATE TABLE public.appointment_extras (
  business_id    uuid        NOT NULL,
  appointment_id uuid        NOT NULL,
  extra_id       uuid        NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, appointment_id, extra_id)
);

-- =============================================================================
-- 3. CONSTRAINTS UNIQUE COMPUESTOS, FKs COMPUESTAS E ÍNDICES
--
--    Orden dentro de la sección:
--      a) UNIQUE(id, business_id) en las 4 tablas padre
--         (prerequisito de todas las FKs compuestas)
--      b) FKs compuestas de service_extras
--         (requiere UNIQUE en services y extras)
--      c) FKs compuestas de appointments
--         (requiere UNIQUE en customers y services)
--      d) UNIQUE(id, business_id) en appointments
--         (prerequisito de las FKs compuestas de appointment_extras)
--      e) FKs compuestas de appointment_extras
--         (requiere UNIQUE en appointments y extras)
--      f) Índices únicos
--      g) Índices de FK y de RLS helpers
-- =============================================================================

-- 3a. UNIQUE(id, business_id) en tablas padre ---------------------------------

ALTER TABLE public.services
  ADD CONSTRAINT services_id_business_id_key UNIQUE (id, business_id);

ALTER TABLE public.extras
  ADD CONSTRAINT extras_id_business_id_key UNIQUE (id, business_id);

ALTER TABLE public.customers
  ADD CONSTRAINT customers_id_business_id_key UNIQUE (id, business_id);

-- 3b. FKs compuestas de service_extras ----------------------------------------
--     Requieren UNIQUE(id, business_id) en services y extras (ya agregados).

ALTER TABLE public.service_extras
  ADD CONSTRAINT service_extras_service_fk
    FOREIGN KEY (service_id, business_id)
    REFERENCES public.services (id, business_id)
    ON DELETE CASCADE;

ALTER TABLE public.service_extras
  ADD CONSTRAINT service_extras_extra_fk
    FOREIGN KEY (extra_id, business_id)
    REFERENCES public.extras (id, business_id)
    ON DELETE CASCADE;

-- 3c. FKs compuestas de appointments ------------------------------------------
--     Requieren UNIQUE(id, business_id) en customers y services (ya agregados).

ALTER TABLE public.appointments
  ADD CONSTRAINT appointments_customer_fk
    FOREIGN KEY (customer_id, business_id)
    REFERENCES public.customers (id, business_id)
    ON DELETE RESTRICT;

ALTER TABLE public.appointments
  ADD CONSTRAINT appointments_service_fk
    FOREIGN KEY (service_id, business_id)
    REFERENCES public.services (id, business_id)
    ON DELETE RESTRICT;

-- 3d. UNIQUE(id, business_id) en appointments ---------------------------------
--     Prerequisito de las FKs compuestas de appointment_extras.

ALTER TABLE public.appointments
  ADD CONSTRAINT appointments_id_business_id_key UNIQUE (id, business_id);

-- 3e. FKs compuestas de appointment_extras ------------------------------------
--     Requieren UNIQUE en appointments (3d) y extras (3a).

ALTER TABLE public.appointment_extras
  ADD CONSTRAINT appointment_extras_appointment_fk
    FOREIGN KEY (appointment_id, business_id)
    REFERENCES public.appointments (id, business_id)
    ON DELETE CASCADE;

ALTER TABLE public.appointment_extras
  ADD CONSTRAINT appointment_extras_extra_fk
    FOREIGN KEY (extra_id, business_id)
    REFERENCES public.extras (id, business_id)
    ON DELETE RESTRICT;

-- 3f. Índices únicos ----------------------------------------------------------

CREATE UNIQUE INDEX businesses_slug_lower_idx
  ON public.businesses (lower(slug));

CREATE UNIQUE INDEX appointments_external_ref_idx
  ON public.appointments (business_id, external_reference)
  WHERE external_reference IS NOT NULL;

-- 3g. Índices de FK y de RLS helpers ------------------------------------------

-- business_members: búsqueda por user, por business y conteo de roles
CREATE INDEX business_members_business_id_idx   ON public.business_members (business_id);
CREATE INDEX business_members_user_id_idx       ON public.business_members (user_id);
CREATE INDEX business_members_user_business_idx ON public.business_members (user_id, business_id);
CREATE INDEX business_members_business_role_idx ON public.business_members (business_id, role);

-- catálogo
CREATE INDEX services_business_id_idx     ON public.services (business_id);
CREATE INDEX extras_business_id_idx       ON public.extras (business_id);
CREATE INDEX business_hours_business_id_idx ON public.business_hours (business_id);
CREATE INDEX customers_business_id_idx    ON public.customers (business_id);

-- service_extras: reverse lookup de FK al eliminar un extra
CREATE INDEX service_extras_extra_id_idx ON public.service_extras (extra_id);

-- appointments
CREATE INDEX appointments_business_id_idx ON public.appointments (business_id);
CREATE INDEX appointments_customer_id_idx ON public.appointments (customer_id);
CREATE INDEX appointments_service_id_idx  ON public.appointments (service_id);
CREATE INDEX appointments_starts_at_idx   ON public.appointments (starts_at);

-- appointment_extras: reverse lookup de FK al eliminar un extra
CREATE INDEX appointment_extras_extra_id_idx ON public.appointment_extras (extra_id);

-- =============================================================================
-- 4. FUNCIONES HELPER RLS
--
--    Se crean DESPUÉS de que public.business_members exista (sección 2.2).
--    LANGUAGE sql: PostgreSQL valida el cuerpo al crearlas — si business_members
--    no existe aún, lanza "relation does not exist".
--
--    SECURITY DEFINER: consultan business_members con privilegios del dueño
--      de la función, evitando recursión infinita en las políticas de
--      business_members que invocan a estos helpers.
--    SET search_path = '': previene search_path injection.
--    (SELECT auth.uid()): optimization fence — evalúa una sola vez por query.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.is_business_member(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   public.business_members
    WHERE  business_id = p_business_id
      AND  user_id     = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.has_business_role(p_business_id uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM   public.business_members
    WHERE  business_id = p_business_id
      AND  user_id     = (SELECT auth.uid())
      AND  role        = ANY(p_roles)
  );
$$;

-- =============================================================================
-- 5. REVOKE / GRANT DE LAS FUNCIONES HELPER
--
--    Por defecto PostgreSQL otorga EXECUTE a PUBLIC en nuevas funciones.
--    Se revoca de PUBLIC y de anon para que solo usuarios autenticados
--    puedan invocarlas directamente.
-- =============================================================================

REVOKE EXECUTE ON FUNCTION public.is_business_member(uuid)       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.is_business_member(uuid)       FROM anon;
GRANT  EXECUTE ON FUNCTION public.is_business_member(uuid)       TO   authenticated;

REVOKE EXECUTE ON FUNCTION public.has_business_role(uuid, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.has_business_role(uuid, text[]) FROM anon;
GRANT  EXECUTE ON FUNCTION public.has_business_role(uuid, text[]) TO   authenticated;

-- =============================================================================
-- 6. ENABLE ROW LEVEL SECURITY
-- =============================================================================

ALTER TABLE public.businesses         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_members   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.services           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.extras             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_extras     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_hours     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appointments       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appointment_extras ENABLE ROW LEVEL SECURITY;

-- =============================================================================
-- 7. POLÍTICAS RLS
--    Se crean después de las funciones helper (sección 4) y de ENABLE RLS.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- businesses
--   SELECT: cualquier miembro del negocio
--   UPDATE: owner/admin
--   Sin INSERT/DELETE via RLS: solo service_role puede crear/eliminar negocios
-- ---------------------------------------------------------------------------

CREATE POLICY "businesses_select" ON public.businesses
  FOR SELECT TO authenticated
  USING (public.is_business_member(id));

CREATE POLICY "businesses_update" ON public.businesses
  FOR UPDATE TO authenticated
  USING     (public.has_business_role(id, ARRAY['owner','admin']))
  WITH CHECK (public.has_business_role(id, ARRAY['owner','admin']));

-- ---------------------------------------------------------------------------
-- business_members
--   SELECT: cualquier miembro
--   INSERT: owner puede agregar cualquier rol; admin solo puede agregar staff
--   UPDATE: owner puede modificar cualquier fila; admin solo puede modificar
--           filas con role='staff' (USING) y solo puede asignar role='staff'
--           (WITH CHECK). Protección de último owner en WITH CHECK.
--   DELETE: owner puede eliminar cualquier miembro; admin solo puede eliminar
--           staff. Ambos: se prohíbe eliminar al último owner del negocio.
-- ---------------------------------------------------------------------------

CREATE POLICY "business_members_select" ON public.business_members
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

CREATE POLICY "business_members_insert" ON public.business_members
  FOR INSERT TO authenticated
  WITH CHECK (
    public.has_business_role(business_id, ARRAY['owner'])
    OR (public.has_business_role(business_id, ARRAY['admin']) AND role = 'staff')
  );

CREATE POLICY "business_members_update" ON public.business_members
  FOR UPDATE TO authenticated
  USING (
    public.has_business_role(business_id, ARRAY['owner'])
    OR (public.has_business_role(business_id, ARRAY['admin']) AND role = 'staff')
  )
  WITH CHECK (
    (
      public.has_business_role(business_id, ARRAY['owner'])
      AND (
        role = 'owner'
        OR (SELECT count(*) FROM public.business_members bm2
            WHERE bm2.business_id = business_members.business_id
              AND bm2.role = 'owner') > 1
      )
    )
    OR (public.has_business_role(business_id, ARRAY['admin']) AND role = 'staff')
  );

CREATE POLICY "business_members_delete" ON public.business_members
  FOR DELETE TO authenticated
  USING (
    (
      public.has_business_role(business_id, ARRAY['owner'])
      OR (public.has_business_role(business_id, ARRAY['admin']) AND role = 'staff')
    )
    AND NOT (
      role = 'owner'
      AND (SELECT count(*) FROM public.business_members bm2
           WHERE bm2.business_id = business_members.business_id
             AND bm2.role = 'owner') <= 1
    )
  );

-- ---------------------------------------------------------------------------
-- services
-- ---------------------------------------------------------------------------

CREATE POLICY "services_select" ON public.services
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

CREATE POLICY "services_insert" ON public.services
  FOR INSERT TO authenticated
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

CREATE POLICY "services_update" ON public.services
  FOR UPDATE TO authenticated
  USING     (public.has_business_role(business_id, ARRAY['owner','admin']))
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

CREATE POLICY "services_delete" ON public.services
  FOR DELETE TO authenticated
  USING (public.has_business_role(business_id, ARRAY['owner','admin']));

-- ---------------------------------------------------------------------------
-- extras
-- ---------------------------------------------------------------------------

CREATE POLICY "extras_select" ON public.extras
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

CREATE POLICY "extras_insert" ON public.extras
  FOR INSERT TO authenticated
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

CREATE POLICY "extras_update" ON public.extras
  FOR UPDATE TO authenticated
  USING     (public.has_business_role(business_id, ARRAY['owner','admin']))
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

CREATE POLICY "extras_delete" ON public.extras
  FOR DELETE TO authenticated
  USING (public.has_business_role(business_id, ARRAY['owner','admin']));

-- ---------------------------------------------------------------------------
-- service_extras
--   RLS usa business_id de la propia tabla (sin subquery).
-- ---------------------------------------------------------------------------

CREATE POLICY "service_extras_select" ON public.service_extras
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

CREATE POLICY "service_extras_insert" ON public.service_extras
  FOR INSERT TO authenticated
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

CREATE POLICY "service_extras_delete" ON public.service_extras
  FOR DELETE TO authenticated
  USING (public.has_business_role(business_id, ARRAY['owner','admin']));

-- ---------------------------------------------------------------------------
-- business_hours
--   Sin DELETE individual: los días se gestionan con UPDATE is_closed=true.
-- ---------------------------------------------------------------------------

CREATE POLICY "business_hours_select" ON public.business_hours
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

CREATE POLICY "business_hours_insert" ON public.business_hours
  FOR INSERT TO authenticated
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

CREATE POLICY "business_hours_update" ON public.business_hours
  FOR UPDATE TO authenticated
  USING     (public.has_business_role(business_id, ARRAY['owner','admin']))
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin']));

-- ---------------------------------------------------------------------------
-- customers
-- ---------------------------------------------------------------------------

CREATE POLICY "customers_select" ON public.customers
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

CREATE POLICY "customers_insert" ON public.customers
  FOR INSERT TO authenticated
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin','staff']));

CREATE POLICY "customers_update" ON public.customers
  FOR UPDATE TO authenticated
  USING     (public.has_business_role(business_id, ARRAY['owner','admin','staff']))
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin','staff']));

CREATE POLICY "customers_delete" ON public.customers
  FOR DELETE TO authenticated
  USING (public.has_business_role(business_id, ARRAY['owner','admin']));

-- ---------------------------------------------------------------------------
-- appointments
-- ---------------------------------------------------------------------------

CREATE POLICY "appointments_select" ON public.appointments
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

CREATE POLICY "appointments_insert" ON public.appointments
  FOR INSERT TO authenticated
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin','staff']));

CREATE POLICY "appointments_update" ON public.appointments
  FOR UPDATE TO authenticated
  USING     (public.has_business_role(business_id, ARRAY['owner','admin','staff']))
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin','staff']));

CREATE POLICY "appointments_delete" ON public.appointments
  FOR DELETE TO authenticated
  USING (public.has_business_role(business_id, ARRAY['owner','admin']));

-- ---------------------------------------------------------------------------
-- appointment_extras
--   RLS usa business_id de la propia tabla (sin subquery).
-- ---------------------------------------------------------------------------

CREATE POLICY "appointment_extras_select" ON public.appointment_extras
  FOR SELECT TO authenticated
  USING (public.is_business_member(business_id));

CREATE POLICY "appointment_extras_insert" ON public.appointment_extras
  FOR INSERT TO authenticated
  WITH CHECK (public.has_business_role(business_id, ARRAY['owner','admin','staff']));

CREATE POLICY "appointment_extras_delete" ON public.appointment_extras
  FOR DELETE TO authenticated
  USING (public.has_business_role(business_id, ARRAY['owner','admin']));

-- =============================================================================
-- 8. TRIGGERS updated_at
--    set_updated_at() existe desde la sección 1; las tablas existen desde
--    la sección 2. Se definen al final para no intercalar lógica entre
--    las secciones de constraints y políticas.
-- =============================================================================

CREATE TRIGGER businesses_set_updated_at
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER business_hours_set_updated_at
  BEFORE UPDATE ON public.business_hours
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER services_set_updated_at
  BEFORE UPDATE ON public.services
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER extras_set_updated_at
  BEFORE UPDATE ON public.extras
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER customers_set_updated_at
  BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER appointments_set_updated_at
  BEFORE UPDATE ON public.appointments
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
