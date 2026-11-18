-- Community structure and recurring scrim foundations for Organizer AI.
-- Existing community_members.role and channels rows remain unchanged.

CREATE OR REPLACE FUNCTION app_private.valid_days_of_week(p_days smallint[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $function$
  SELECT COALESCE(bool_and(d BETWEEN 0 AND 6), true)
  FROM unnest(COALESCE(p_days, ARRAY[]::smallint[])) AS d;
$function$;
REVOKE ALL ON FUNCTION app_private.valid_days_of_week(smallint[]) FROM public, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.community_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id uuid NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(name) BETWEEN 2 AND 40),
  description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 300),
  colour text,
  position integer NOT NULL DEFAULT 0,
  is_system boolean NOT NULL DEFAULT false,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (community_id, name),
  UNIQUE (id, community_id)
);
CREATE INDEX IF NOT EXISTS community_roles_community_position_idx
  ON public.community_roles(community_id, position DESC);

CREATE TABLE IF NOT EXISTS public.community_member_roles (
  community_id uuid NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role_id uuid NOT NULL,
  assigned_by uuid NOT NULL REFERENCES auth.users(id),
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (community_id, user_id, role_id),
  FOREIGN KEY (role_id, community_id)
    REFERENCES public.community_roles(id, community_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS community_member_roles_role_idx
  ON public.community_member_roles(role_id, community_id);
CREATE INDEX IF NOT EXISTS community_member_roles_user_idx
  ON public.community_member_roles(user_id, community_id);

CREATE TABLE IF NOT EXISTS public.role_permissions (
  role_id uuid NOT NULL REFERENCES public.community_roles(id) ON DELETE CASCADE,
  permission_key text NOT NULL CHECK (char_length(permission_key) BETWEEN 3 AND 80),
  allowed boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role_id, permission_key)
);

CREATE TABLE IF NOT EXISTS public.channel_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id uuid NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(name) BETWEEN 2 AND 60),
  description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 300),
  position integer NOT NULL DEFAULT 0,
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (community_id, name),
  UNIQUE (id, community_id)
);
CREATE INDEX IF NOT EXISTS channel_categories_community_position_idx
  ON public.channel_categories(community_id, position);

ALTER TABLE public.channels
  ADD COLUMN IF NOT EXISTS category_id uuid;
ALTER TABLE public.channels
  ADD CONSTRAINT channels_id_community_unique UNIQUE (id, community_id);
ALTER TABLE public.channels
  ADD CONSTRAINT channels_category_community_fkey
  FOREIGN KEY (category_id, community_id)
  REFERENCES public.channel_categories(id, community_id)
  ON DELETE SET NULL (category_id);
CREATE INDEX IF NOT EXISTS channels_category_id_idx
  ON public.channels(category_id) WHERE category_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.channel_permission_overrides (
  community_id uuid NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  channel_id uuid NOT NULL,
  role_id uuid NOT NULL,
  permission_key text NOT NULL CHECK (char_length(permission_key) BETWEEN 3 AND 80),
  effect text NOT NULL CHECK (effect IN ('allow','deny')),
  updated_by uuid NOT NULL REFERENCES auth.users(id),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel_id, role_id, permission_key),
  FOREIGN KEY (channel_id, community_id)
    REFERENCES public.channels(id, community_id) ON DELETE CASCADE,
  FOREIGN KEY (role_id, community_id)
    REFERENCES public.community_roles(id, community_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS channel_permission_overrides_role_idx
  ON public.channel_permission_overrides(role_id, channel_id);

CREATE TABLE IF NOT EXISTS public.scrim_series (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id uuid NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  organizer_id uuid NOT NULL REFERENCES public.profiles(id),
  game_id uuid NOT NULL REFERENCES public.games(id),
  name text NOT NULL CHECK (char_length(name) BETWEEN 3 AND 100),
  description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 2000),
  format text NOT NULL CHECK (format IN ('solo','duo','squad','custom')),
  recurrence_type text NOT NULL CHECK (recurrence_type IN ('daily','weekly','biweekly','monthly')),
  interval_count integer NOT NULL DEFAULT 1 CHECK (interval_count BETWEEN 1 AND 12),
  days_of_week smallint[] NOT NULL DEFAULT ARRAY[]::smallint[],
  timezone text NOT NULL DEFAULT 'Asia/Kolkata',
  local_start_time time NOT NULL,
  duration_minutes integer NOT NULL DEFAULT 120 CHECK (duration_minutes BETWEEN 15 AND 720),
  starts_on date NOT NULL,
  ends_on date,
  capacity integer NOT NULL CHECK (capacity BETWEEN 1 AND 1000),
  rules_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  scoring_config jsonb NOT NULL DEFAULT '{}'::jsonb,
  enabled boolean NOT NULL DEFAULT false,
  next_run_at timestamptz,
  last_generated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_on IS NULL OR ends_on >= starts_on),
  CHECK (app_private.valid_days_of_week(days_of_week))
);
CREATE INDEX IF NOT EXISTS scrim_series_community_enabled_idx
  ON public.scrim_series(community_id, enabled, next_run_at);
CREATE INDEX IF NOT EXISTS scrim_series_organizer_idx
  ON public.scrim_series(organizer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.scrim_series_occurrences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  series_id uuid NOT NULL REFERENCES public.scrim_series(id) ON DELETE CASCADE,
  event_id uuid REFERENCES public.events(id) ON DELETE SET NULL,
  scheduled_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned','draft_created','published','cancelled','failed')),
  idempotency_key text NOT NULL UNIQUE,
  generated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS scrim_occurrences_series_schedule_idx
  ON public.scrim_series_occurrences(series_id, scheduled_at);
CREATE INDEX IF NOT EXISTS scrim_occurrences_event_idx
  ON public.scrim_series_occurrences(event_id) WHERE event_id IS NOT NULL;

CREATE OR REPLACE FUNCTION app_private.can_manage_community_roles(p_community_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    EXISTS (SELECT 1 FROM public.communities c
            WHERE c.id=p_community_id AND c.owner_user_id=(SELECT auth.uid()))
    OR EXISTS (SELECT 1 FROM public.community_members cm
               WHERE cm.community_id=p_community_id AND cm.user_id=(SELECT auth.uid())
                 AND cm.role IN ('owner','admin'));
$function$;
REVOKE ALL ON FUNCTION app_private.can_manage_community_roles(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION app_private.can_manage_community_roles(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION app_private.can_manage_community_structure(p_community_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    EXISTS (SELECT 1 FROM public.communities c
            WHERE c.id=p_community_id AND c.owner_user_id=(SELECT auth.uid()))
    OR EXISTS (SELECT 1 FROM public.community_members cm
               WHERE cm.community_id=p_community_id AND cm.user_id=(SELECT auth.uid())
                 AND cm.role IN ('owner','admin','moderator','organiser'));
$function$;
REVOKE ALL ON FUNCTION app_private.can_manage_community_structure(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION app_private.can_manage_community_structure(uuid) TO authenticated;

ALTER TABLE public.community_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.community_member_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channel_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channel_permission_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scrim_series ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scrim_series_occurrences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS community_roles_read_member ON public.community_roles;
CREATE POLICY community_roles_read_member ON public.community_roles
FOR SELECT TO authenticated USING (app_private.is_community_member(community_id));
DROP POLICY IF EXISTS community_roles_write_admin ON public.community_roles;
CREATE POLICY community_roles_write_admin ON public.community_roles
FOR ALL TO authenticated
USING (app_private.can_manage_community_roles(community_id))
WITH CHECK (app_private.can_manage_community_roles(community_id));

DROP POLICY IF EXISTS community_member_roles_read_scoped ON public.community_member_roles;
CREATE POLICY community_member_roles_read_scoped ON public.community_member_roles
FOR SELECT TO authenticated
USING (user_id=(SELECT auth.uid()) OR app_private.can_manage_community_roles(community_id));
DROP POLICY IF EXISTS community_member_roles_write_admin ON public.community_member_roles;
CREATE POLICY community_member_roles_write_admin ON public.community_member_roles
FOR ALL TO authenticated
USING (app_private.can_manage_community_roles(community_id))
WITH CHECK (
  app_private.can_manage_community_roles(community_id)
  AND EXISTS (
    SELECT 1 FROM public.community_members cm
    WHERE cm.community_id=community_id AND cm.user_id=user_id
  )
);

DROP POLICY IF EXISTS role_permissions_read_member ON public.role_permissions;
CREATE POLICY role_permissions_read_member ON public.role_permissions
FOR SELECT TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.community_roles cr
  WHERE cr.id=role_id AND app_private.is_community_member(cr.community_id)
));
DROP POLICY IF EXISTS role_permissions_write_admin ON public.role_permissions;
CREATE POLICY role_permissions_write_admin ON public.role_permissions
FOR ALL TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.community_roles cr
  WHERE cr.id=role_id AND app_private.can_manage_community_roles(cr.community_id)
))
WITH CHECK (EXISTS (
  SELECT 1 FROM public.community_roles cr
  WHERE cr.id=role_id AND app_private.can_manage_community_roles(cr.community_id)
));

DROP POLICY IF EXISTS channel_categories_read_member ON public.channel_categories;
CREATE POLICY channel_categories_read_member ON public.channel_categories
FOR SELECT TO authenticated USING (app_private.is_community_member(community_id));
DROP POLICY IF EXISTS channel_categories_write_staff ON public.channel_categories;
CREATE POLICY channel_categories_write_staff ON public.channel_categories
FOR ALL TO authenticated
USING (app_private.can_manage_community_structure(community_id))
WITH CHECK (app_private.can_manage_community_structure(community_id));

DROP POLICY IF EXISTS channel_permission_overrides_read_staff ON public.channel_permission_overrides;
CREATE POLICY channel_permission_overrides_read_staff ON public.channel_permission_overrides
FOR SELECT TO authenticated USING (app_private.can_manage_community_structure(community_id));
DROP POLICY IF EXISTS channel_permission_overrides_write_admin ON public.channel_permission_overrides;
CREATE POLICY channel_permission_overrides_write_admin ON public.channel_permission_overrides
FOR ALL TO authenticated USING (app_private.can_manage_community_roles(community_id))
WITH CHECK (app_private.can_manage_community_roles(community_id));

DROP POLICY IF EXISTS scrim_series_read_member ON public.scrim_series;
CREATE POLICY scrim_series_read_member ON public.scrim_series
FOR SELECT TO authenticated USING (app_private.is_community_member(community_id));
DROP POLICY IF EXISTS scrim_series_write_staff ON public.scrim_series;
CREATE POLICY scrim_series_write_staff ON public.scrim_series
FOR ALL TO authenticated
USING (app_private.can_manage_community_structure(community_id))
WITH CHECK (
  organizer_id=(SELECT auth.uid())
  AND app_private.can_manage_community_structure(community_id)
);

DROP POLICY IF EXISTS scrim_occurrences_read_member ON public.scrim_series_occurrences;
CREATE POLICY scrim_occurrences_read_member ON public.scrim_series_occurrences
FOR SELECT TO authenticated USING (EXISTS (
  SELECT 1 FROM public.scrim_series ss
  WHERE ss.id=series_id AND app_private.is_community_member(ss.community_id)
));
DROP POLICY IF EXISTS scrim_occurrences_write_staff ON public.scrim_series_occurrences;
CREATE POLICY scrim_occurrences_write_staff ON public.scrim_series_occurrences
FOR ALL TO authenticated
USING (EXISTS (
  SELECT 1 FROM public.scrim_series ss
  WHERE ss.id=series_id AND app_private.can_manage_community_structure(ss.community_id)
))
WITH CHECK (EXISTS (
  SELECT 1 FROM public.scrim_series ss
  WHERE ss.id=series_id AND app_private.can_manage_community_structure(ss.community_id)
));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.community_roles, public.community_member_roles,
  public.role_permissions, public.channel_categories, public.channel_permission_overrides,
  public.scrim_series, public.scrim_series_occurrences TO authenticated;

DROP TRIGGER IF EXISTS community_roles_set_updated_at ON public.community_roles;
CREATE TRIGGER community_roles_set_updated_at BEFORE UPDATE ON public.community_roles
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();
DROP TRIGGER IF EXISTS channel_categories_set_updated_at ON public.channel_categories;
CREATE TRIGGER channel_categories_set_updated_at BEFORE UPDATE ON public.channel_categories
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();
DROP TRIGGER IF EXISTS scrim_series_set_updated_at ON public.scrim_series;
CREATE TRIGGER scrim_series_set_updated_at BEFORE UPDATE ON public.scrim_series
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();
DROP TRIGGER IF EXISTS scrim_occurrences_set_updated_at ON public.scrim_series_occurrences;
CREATE TRIGGER scrim_occurrences_set_updated_at BEFORE UPDATE ON public.scrim_series_occurrences
FOR EACH ROW EXECUTE FUNCTION app_private.set_updated_at();

COMMENT ON TABLE public.community_roles IS 'Custom community roles; cannot replace or elevate the built-in owner/admin hierarchy.';
COMMENT ON TABLE public.channel_permission_overrides IS 'Per-channel allow/deny overrides with same-community foreign keys.';
COMMENT ON TABLE public.scrim_series IS 'Recurring scrim templates. New series default disabled until explicitly enabled by an organiser.';
COMMENT ON TABLE public.scrim_series_occurrences IS 'Idempotent occurrences generated from recurring scrim templates.';

