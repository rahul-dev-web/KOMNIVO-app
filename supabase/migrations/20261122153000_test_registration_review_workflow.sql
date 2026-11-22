-- Phase 3 completion: organiser review workflow for isolated test registrations.
ALTER TABLE public.event_test_registrations
  ADD COLUMN IF NOT EXISTS reviewed_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS review_note text NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS event_test_registrations_status_idx
  ON public.event_test_registrations(event_id,status,created_at DESC);

CREATE OR REPLACE FUNCTION app_private.review_event_test_registration(
  p_test_registration_id uuid,
  p_status text,
  p_review_note text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_registration public.event_test_registrations%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_status NOT IN ('passed','failed','cancelled') THEN
    RAISE EXCEPTION 'Test registration status must be passed, failed or cancelled';
  END IF;

  SELECT * INTO v_registration
  FROM public.event_test_registrations
  WHERE id=p_test_registration_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Test registration not found';
  END IF;

  IF NOT app_private.resolve_permission(
    'event.registrations.manage','event',v_registration.event_id,NULL,NULL
  ) THEN
    RAISE EXCEPTION 'You do not have permission to review test registrations';
  END IF;

  IF v_registration.status <> 'submitted' THEN
    RAISE EXCEPTION 'Only submitted test registrations can be reviewed';
  END IF;

  UPDATE public.event_test_registrations
  SET status=p_status,
      reviewed_by=auth.uid(),
      reviewed_at=now(),
      review_note=left(coalesce(p_review_note,''),500),
      updated_at=now()
  WHERE id=p_test_registration_id
  RETURNING * INTO v_registration;

  INSERT INTO public.audit_logs(
    actor_id,event_id,entity_type,entity_id,action,reason
  ) VALUES (
    auth.uid(),
    v_registration.event_id,
    'event_test_registration',
    v_registration.id,
    'test_registration_'||p_status,
    nullif(v_registration.review_note,'')
  );

  RETURN jsonb_build_object(
    'test_registration_id',v_registration.id,
    'event_id',v_registration.event_id,
    'status',v_registration.status,
    'reviewed_by',v_registration.reviewed_by,
    'reviewed_at',v_registration.reviewed_at,
    'review_note',v_registration.review_note,
    'is_test',true,
    'affects_real_registration',false,
    'affects_standings',false
  );
END;
$function$;
REVOKE ALL ON FUNCTION app_private.review_event_test_registration(uuid,text,text)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.review_event_test_registration(
  p_test_registration_id uuid,
  p_status text,
  p_review_note text DEFAULT ''
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT app_private.review_event_test_registration(
    p_test_registration_id,p_status,p_review_note
  );
$function$;
REVOKE ALL ON FUNCTION public.review_event_test_registration(uuid,text,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.review_event_test_registration(uuid,text,text)
  TO authenticated;

COMMENT ON FUNCTION public.review_event_test_registration(uuid,text,text) IS
  'Allows event.registrations.manage staff to review isolated test submissions. Never changes real registration, match participants or scoring.';
