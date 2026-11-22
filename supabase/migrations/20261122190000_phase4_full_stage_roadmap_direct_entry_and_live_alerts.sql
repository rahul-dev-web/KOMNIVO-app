ALTER TABLE public.events ADD COLUMN IF NOT EXISTS roadmap_published_at timestamptz,
 ADD COLUMN IF NOT EXISTS roadmap_published_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 ADD COLUMN IF NOT EXISTS roadmap_version integer NOT NULL DEFAULT 0 CHECK(roadmap_version>=0);

CREATE TABLE IF NOT EXISTS public.event_stage_roadmaps(
 event_id uuid NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
 round_number integer NOT NULL CHECK(round_number BETWEEN 1 AND 16),
 configuration jsonb NOT NULL CHECK(jsonb_typeof(configuration)='object'),
 version integer NOT NULL DEFAULT 1 CHECK(version>0),
 published_at timestamptz NOT NULL,published_by uuid NOT NULL REFERENCES public.profiles(id),
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(event_id,round_number));
CREATE INDEX IF NOT EXISTS event_stage_roadmaps_published_idx ON public.event_stage_roadmaps(event_id,round_number) WHERE published_at IS NOT NULL;
ALTER TABLE public.event_stage_roadmaps ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS event_stage_roadmaps_read_staff ON public.event_stage_roadmaps;
CREATE POLICY event_stage_roadmaps_read_staff ON public.event_stage_roadmaps FOR SELECT TO authenticated USING(app_private.is_event_staff(event_id));
REVOKE ALL ON public.event_stage_roadmaps FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.event_stage_roadmaps TO authenticated;
GRANT ALL ON public.event_stage_roadmaps TO service_role;

ALTER TABLE public.event_stage_direct_invites DROP CONSTRAINT IF EXISTS event_stage_direct_invites_target_round_number_check;
ALTER TABLE public.event_stage_direct_invites ADD CONSTRAINT event_stage_direct_invites_target_round_number_check CHECK(target_round_number BETWEEN 1 AND 16);

CREATE OR REPLACE FUNCTION public.set_event_stage_direct_invites(p_event_id uuid,p_target_round_number integer,p_team_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE e public.events%rowtype; n integer; tid uuid; reg uuid; gid uuid; m record; slot_no integer; added integer:=0;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF NOT app_private.is_event_staff(p_event_id) THEN RAISE EXCEPTION 'Only event staff can assign direct-entry teams'; END IF;
 SELECT * INTO e FROM public.events WHERE id=p_event_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;
 n:=COALESCE(NULLIF(e.event_config->>'stage_count','')::integer,0);
 IF p_target_round_number IS NULL OR p_target_round_number<1 OR p_target_round_number>n THEN RAISE EXCEPTION 'Choose a stage between 1 and %',n; END IF;
 IF COALESCE(cardinality(p_team_ids),0)=0 OR (SELECT count(DISTINCT x)::integer FROM unnest(p_team_ids) AS x)<>cardinality(p_team_ids) THEN RAISE EXCEPTION 'Select one or more unique teams'; END IF;
 IF EXISTS(SELECT 1 FROM public.matches WHERE event_id=p_event_id AND round_number=p_target_round_number AND status IN ('live','awaiting_result','review','completed')) THEN
  RAISE EXCEPTION 'A stage cannot receive direct-entry teams after a match has started or results exist';
 END IF;
 FOREACH tid IN ARRAY p_team_ids LOOP
  SELECT er.id INTO reg FROM public.event_registrations er JOIN public.teams t ON t.id=er.team_id
   WHERE er.event_id=p_event_id AND er.team_id=tid AND er.status IN ('approved','checked_in') AND er.roster_locked AND t.game_id=e.game_id
   ORDER BY er.registered_at DESC LIMIT 1;
  IF reg IS NULL THEN RAISE EXCEPTION 'Direct-entry teams require approved, roster-locked event registrations for this game'; END IF;
  IF EXISTS(SELECT 1 FROM public.event_groups g JOIN public.event_rounds r ON r.id=g.round_id JOIN public.event_group_teams gt ON gt.group_id=g.id
    WHERE r.event_id=p_event_id AND r.round_number=p_target_round_number AND gt.team_id=tid) THEN RAISE EXCEPTION 'Team is already assigned to this stage'; END IF;
  INSERT INTO public.event_stage_direct_invites(event_id,team_id,target_round_number,assigned_by)
   VALUES(p_event_id,tid,p_target_round_number,auth.uid())
   ON CONFLICT(event_id,team_id) DO UPDATE SET target_round_number=EXCLUDED.target_round_number,assigned_by=EXCLUDED.assigned_by,assigned_at=now();
  SELECT g.id INTO gid FROM public.event_groups g JOIN public.event_rounds r ON r.id=g.round_id
   LEFT JOIN public.event_group_teams gt ON gt.group_id=g.id
   WHERE r.event_id=p_event_id AND r.round_number=p_target_round_number
   GROUP BY g.id,g.sort_order HAVING count(gt.team_id)<24 ORDER BY count(gt.team_id),g.sort_order LIMIT 1;
  IF gid IS NOT NULL THEN
   INSERT INTO public.event_group_teams(group_id,team_id,seeded_by) VALUES(gid,tid,auth.uid());
   FOR m IN SELECT id FROM public.matches WHERE event_id=p_event_id AND round_number=p_target_round_number AND group_id=gid AND status='scheduled' LOOP
    SELECT n INTO slot_no FROM generate_series(1,24)n WHERE NOT EXISTS(SELECT 1 FROM public.match_participants mp WHERE mp.match_id=m.id AND mp.slot_number=n) ORDER BY n LIMIT 1;
    IF slot_no IS NULL THEN RAISE EXCEPTION 'No free slot in target-stage match'; END IF;
    INSERT INTO public.match_participants(match_id,team_id,registration_id,slot_number) VALUES(m.id,tid,reg,slot_no);
   END LOOP;
  ELSIF EXISTS(SELECT 1 FROM public.event_rounds WHERE event_id=p_event_id AND round_number=p_target_round_number) THEN
   RAISE EXCEPTION 'Target stage has no available group capacity';
  END IF;
  added:=added+1;
 END LOOP;
 UPDATE public.events SET roadmap_published_at=NULL,roadmap_published_by=NULL WHERE id=p_event_id;
 UPDATE public.event_rounds SET schedule_published_at=NULL,schedule_published_by=NULL,status='draft' WHERE event_id=p_event_id AND round_number=p_target_round_number;
 INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
 VALUES(auth.uid(),p_event_id,'event',p_event_id,'roadmap_direct_entry_assigned','Organiser assigned direct-entry teams to a selected stage',
 jsonb_build_object('target_round_number',p_target_round_number,'team_ids',to_jsonb(p_team_ids),'team_count',added));
 RETURN jsonb_build_object('event_id',p_event_id,'target_round_number',p_target_round_number,'assigned_count',added,'team_ids',to_jsonb(p_team_ids),'republish_required',true);
END;$function$;
REVOKE ALL ON FUNCTION public.set_event_stage_direct_invites(uuid,integer,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_event_stage_direct_invites(uuid,integer,uuid[]) TO authenticated;
CREATE OR REPLACE FUNCTION public.set_event_stage_direct_invites(uuid,uuid[]) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=''
AS $function$ SELECT public.set_event_stage_direct_invites($1,2,$2) $function$;
REVOKE ALL ON FUNCTION public.set_event_stage_direct_invites(uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_event_stage_direct_invites(uuid,uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.publish_event_roadmap(p_event_id uuid,p_stage_configs jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE e public.events%rowtype; n integer; s jsonb; r integer; nm text; gs integer; q integer; qualified integer; direct_n integer; matches_n integer; interval_n integer; first_at timestamptz; previous_at timestamptz; assigned integer; version_n integer; summary text:=''; next_direct integer; roadmap_ch uuid; sid uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF NOT app_private.is_event_staff(p_event_id) THEN RAISE EXCEPTION 'Only event staff can publish the entire roadmap'; END IF;
 SELECT * INTO e FROM public.events WHERE id=p_event_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;
 n:=COALESCE(NULLIF(e.event_config->>'stage_count','')::integer,0);
 IF n<1 OR n>16 OR jsonb_typeof(p_stage_configs)<>'array' OR jsonb_array_length(p_stage_configs)<>n THEN RAISE EXCEPTION 'Submit all % stages in order in one publication',n; END IF;
 IF EXISTS(SELECT 1 FROM public.matches WHERE event_id=p_event_id AND status IN ('live','awaiting_result','review','completed')) THEN RAISE EXCEPTION 'Cannot replace a roadmap after a stage match starts or results exist'; END IF;
 version_n:=e.roadmap_version+1; DELETE FROM public.event_stage_roadmaps WHERE event_id=p_event_id;
 FOR s IN SELECT value FROM jsonb_array_elements(p_stage_configs) LOOP
  r:=NULLIF(s->>'round_number','')::integer; nm:=NULLIF(trim(s->>'stage_name'),''); gs:=NULLIF(s->>'group_size','')::integer; q:=NULLIF(s->>'qualifiers_per_group','')::integer;
  qualified:=NULLIF(s->>'qualified_team_count','')::integer; direct_n:=COALESCE(NULLIF(s->>'direct_entry_count','')::integer,0);
  matches_n:=NULLIF(s->>'matches_per_group','')::integer; interval_n:=NULLIF(s->>'interval_minutes','')::integer; first_at:=NULLIF(s->>'first_match_at','')::timestamptz;
  IF r IS NULL OR r<>(SELECT count(*)+1 FROM public.event_stage_roadmaps WHERE event_id=p_event_id)
   OR nm IS NULL OR char_length(nm) NOT BETWEEN 2 AND 80 OR gs IS NULL OR gs NOT BETWEEN 2 AND 24
   OR q IS NULL OR q NOT BETWEEN 0 AND gs OR qualified IS NULL OR qualified<0 OR direct_n<0
   OR matches_n IS NULL OR matches_n NOT BETWEEN 1 AND 20 OR interval_n IS NULL OR interval_n NOT BETWEEN 1 AND 240
   OR first_at IS NULL OR first_at<=now() OR (previous_at IS NOT NULL AND first_at<=previous_at) THEN
   RAISE EXCEPTION 'Stage % has missing or invalid roadmap settings',r;
  END IF;
  IF r<n AND q<1 THEN RAISE EXCEPTION 'Every non-final stage needs a qualification count'; END IF;
  IF r=n AND q<>0 THEN RAISE EXCEPTION 'Final stage qualifiers_per_group must be 0'; END IF;
  SELECT count(*)::integer INTO assigned FROM public.event_stage_direct_invites WHERE event_id=p_event_id AND target_round_number=r;
  IF assigned<>direct_n THEN RAISE EXCEPTION 'Stage % expects % direct-entry teams but % are assigned',r,direct_n,assigned; END IF;
  next_direct:=CASE WHEN r<n THEN COALESCE(NULLIF(p_stage_configs->r->>'direct_entry_count','')::integer,0) ELSE 0 END;
  INSERT INTO public.event_stage_roadmaps(event_id,round_number,configuration,version,published_at,published_by)
  VALUES(p_event_id,r,jsonb_build_object('round_number',r,'stage_name',nm,'stage_type',COALESCE(NULLIF(s->>'stage_type',''),'custom'),
   'group_size',gs,'qualifiers_per_group',q,'qualified_team_count',qualified,'direct_entry_count',direct_n,
   'matches_per_group',matches_n,'interval_minutes',interval_n,'first_match_at',first_at,
   'direct_invites',next_direct,'next_round_team_count',qualified+next_direct),version_n,now(),auth.uid());
  summary:=summary||CASE WHEN summary='' THEN '' ELSE E'\n' END||format('%s. %s · group %s · matches %s · qualify %s · direct %s',r,nm,gs,matches_n,q,direct_n);
  previous_at:=first_at;
 END LOOP;
 UPDATE public.events SET roadmap_published_at=now(),roadmap_published_by=auth.uid(),roadmap_version=version_n WHERE id=p_event_id;
 SELECT id INTO roadmap_ch FROM public.channels WHERE event_id=p_event_id AND name='roadmap' AND stage_id IS NULL AND group_id IS NULL ORDER BY created_at LIMIT 1;
 IF roadmap_ch IS NULL THEN RAISE EXCEPTION 'Tournament roadmap channel is missing'; END IF;
 INSERT INTO public.messages(channel_id,sender_id,body) VALUES(roadmap_ch,auth.uid(),'Complete tournament roadmap published · v'||version_n||E'\n'||summary);
 FOR sid IN SELECT r.id FROM public.event_rounds r WHERE r.event_id=p_event_id
  AND EXISTS(SELECT 1 FROM public.matches m WHERE m.stage_id=r.id) AND r.schedule_published_at IS NULL ORDER BY r.round_number
 LOOP PERFORM public.publish_event_stage_schedule(sid); END LOOP;
 INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
 VALUES(auth.uid(),p_event_id,'event',p_event_id,'complete_event_roadmap_published','Complete stage-to-stage roadmap published in one action',
  jsonb_build_object('roadmap_version',version_n,'stage_count',n,'summary',summary));
 RETURN jsonb_build_object('event_id',p_event_id,'roadmap_version',version_n,'stage_count',n,'roadmap_published',true);
END;$function$;
REVOKE ALL ON FUNCTION public.publish_event_roadmap(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.publish_event_roadmap(uuid,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION app_private.dispatch_unpublished_roadmap_live_match_alerts()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$ DECLARE r record; notice uuid; sent integer:=0; bucket text;
BEGIN
 bucket:=floor(extract(epoch FROM now())/3600)::bigint::text;
 FOR r IN SELECT DISTINCT e.id event_id,e.organizer_id,e.name event_name,s.id stage_id,s.name stage_name
  FROM public.events e JOIN public.event_rounds s ON s.event_id=e.id JOIN public.matches m ON m.stage_id=s.id AND m.status='live'
  LEFT JOIN public.event_stage_roadmaps rm ON rm.event_id=e.id AND rm.round_number=s.round_number AND rm.published_at IS NOT NULL
  WHERE e.roadmap_published_at IS NULL OR rm.event_id IS NULL
 LOOP
  notice:=app_private.enqueue_event_notification(r.event_id,r.organizer_id,
   'roadmap_unpublished_live:'||r.stage_id::text||':'||bucket,
   'Action required: tournament roadmap not published',
   r.event_name||' · '||r.stage_name||' has a live match, but the complete stage-to-stage roadmap is not published. Publish the full roadmap now.');
  IF notice IS NOT NULL THEN sent:=sent+1; END IF;
 END LOOP; RETURN sent;
END;$function$;
REVOKE ALL ON FUNCTION app_private.dispatch_unpublished_roadmap_live_match_alerts() FROM PUBLIC,anon,authenticated;
DO $$ DECLARE j bigint; BEGIN
 SELECT jobid INTO j FROM cron.job WHERE jobname='komnivo-unpublished-roadmap-live-match-alerts' LIMIT 1;
 IF j IS NOT NULL THEN PERFORM cron.unschedule(j); END IF;
 PERFORM cron.schedule('komnivo-unpublished-roadmap-live-match-alerts','*/15 * * * *','select app_private.dispatch_unpublished_roadmap_live_match_alerts();');
END $$;

CREATE OR REPLACE FUNCTION app_private.require_published_event_stage_roadmap()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$ DECLARE p jsonb;
BEGIN
 SELECT configuration INTO p FROM public.event_stage_roadmaps
 WHERE event_id=NEW.event_id AND round_number=NEW.round_number AND published_at IS NOT NULL;
 IF p IS NULL OR (SELECT roadmap_published_at FROM public.events WHERE id=NEW.event_id) IS NULL THEN
  RAISE EXCEPTION 'This stage has no published roadmap. Publish the complete tournament roadmap before progressing.';
 END IF;
 NEW.name:=p->>'stage_name';
 NEW.stage_type:=COALESCE(p->>'stage_type','custom');
 NEW.group_size:=(p->>'group_size')::integer;
 NEW.matches_per_group:=(p->>'matches_per_group')::integer;
 NEW.starts_at:=(p->>'first_match_at')::timestamptz;
 NEW.advancement_rules:=jsonb_build_object('mode','top_per_group','qualify_per_group',(p->>'qualifiers_per_group')::integer,
  'qualified_team_count',(p->>'qualified_team_count')::integer,'direct_entry_count',(p->>'direct_entry_count')::integer);
 NEW.configuration:=COALESCE(NEW.configuration,'{}'::jsonb)||jsonb_build_object('roadmap_version',(SELECT version FROM public.event_stage_roadmaps WHERE event_id=NEW.event_id AND round_number=NEW.round_number));
 RETURN NEW;
END;$function$;
REVOKE ALL ON FUNCTION app_private.require_published_event_stage_roadmap() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS require_published_event_stage_roadmap ON public.event_rounds;
CREATE TRIGGER require_published_event_stage_roadmap
BEFORE INSERT OR UPDATE OF event_id,round_number,name,stage_type,group_size,matches_per_group,starts_at
ON public.event_rounds FOR EACH ROW EXECUTE FUNCTION app_private.require_published_event_stage_roadmap();

CREATE OR REPLACE FUNCTION public.generate_event_roadmap(p_event_id uuid, p_matches_per_group integer, p_interval_minutes integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_event public.events%ROWTYPE;
  v_roadmap jsonb;
  v_stage_count integer;
  v_stage_names jsonb;
  v_group_size integer;
  v_qualify_per_group integer;
  v_expected_qualified integer;
  v_direct_invites integer;
  v_registered_team_count integer;
  v_team_count integer;
  v_group_count integer;
  v_stage_id uuid;
  v_stage_name text;
  v_first_match_at timestamptz;
  v_result jsonb;
  v_assigned_invites integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT app_private.is_event_staff(p_event_id) THEN
    RAISE EXCEPTION 'Only authorised event staff can generate the roadmap';
  END IF;
  IF p_matches_per_group < 1 OR p_matches_per_group > 20
     OR p_interval_minutes < 1 OR p_interval_minutes > 240 THEN
    RAISE EXCEPTION 'Matches per group must be 1-20 and interval must be 1-240 minutes';
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Event not found'; END IF;
  IF v_event.format = 'solo' THEN
    RAISE EXCEPTION 'Automatic team-group roadmap currently supports Duo, Squad or Custom team formats';
  END IF;

  v_stage_count := NULLIF(v_event.event_config->>'stage_count','')::integer;
  v_stage_names := COALESCE(v_event.event_config->'stage_names','[]'::jsonb);
  SELECT configuration INTO v_roadmap FROM public.event_stage_roadmaps
   WHERE event_id=p_event_id AND round_number=1 AND published_at IS NOT NULL;
  IF v_roadmap IS NULL OR v_event.roadmap_published_at IS NULL THEN
    RAISE EXCEPTION 'Publish the complete stage-to-stage roadmap before generating Stage 1';
  END IF;
  IF v_stage_count IS NULL OR v_stage_count < 1 OR v_stage_count > 16
     OR jsonb_typeof(v_roadmap) <> 'object' THEN
    RAISE EXCEPTION 'Complete the saved stage count and roadmap before generating groups';
  END IF;

  v_group_size := NULLIF(v_roadmap->>'group_size','')::integer;
  v_qualify_per_group := NULLIF(v_roadmap->>'qualifiers_per_group','')::integer;
  v_expected_qualified := NULLIF(v_roadmap->>'qualified_team_count','')::integer;
  SELECT count(*)::integer INTO v_direct_invites FROM public.event_stage_direct_invites
   WHERE event_id=p_event_id AND target_round_number=2;
  IF v_group_size IS NULL OR v_group_size < 2 OR v_group_size > 24
     OR v_qualify_per_group IS NULL OR v_qualify_per_group < 1 OR v_qualify_per_group > v_group_size
     OR v_expected_qualified IS NULL OR v_expected_qualified < 0 OR v_direct_invites < 0
     OR COALESCE(NULLIF(v_roadmap->>'next_round_team_count','')::integer,-1) <> v_expected_qualified + v_direct_invites THEN
    RAISE EXCEPTION 'Saved roadmap values are invalid for automatic generation';
  END IF;
  IF v_direct_invites > 0 AND v_stage_count < 2 THEN
    RAISE EXCEPTION 'Direct-entry teams require a later stage';
  END IF;

  SELECT count(DISTINCT er.team_id)::integer INTO v_registered_team_count
  FROM public.event_registrations er
  WHERE er.event_id = p_event_id
    AND er.status IN ('approved','checked_in')
    AND er.roster_locked AND er.team_id IS NOT NULL;

  SELECT count(*)::integer INTO v_assigned_invites
  FROM public.event_stage_direct_invites
  WHERE event_id = p_event_id AND target_round_number = 2;

  IF v_assigned_invites <> v_direct_invites THEN
    RAISE EXCEPTION 'Select exactly % direct-entry teams in Event Operations before generating the roadmap; % currently assigned',
      v_direct_invites,v_assigned_invites;
  END IF;

  SELECT count(DISTINCT er.team_id)::integer INTO v_team_count
  FROM public.event_registrations er
  WHERE er.event_id = p_event_id
    AND er.status IN ('approved','checked_in')
    AND er.roster_locked AND er.team_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.event_stage_direct_invites di
      WHERE di.event_id = p_event_id AND di.team_id = er.team_id
        AND di.target_round_number > 1
    );

  IF v_team_count < 2 THEN
    RAISE EXCEPTION 'At least two approved, roster-locked teams must enter stage one after direct-entry teams are excluded';
  END IF;

  v_group_count := ceil(v_team_count::numeric / v_group_size)::integer;
  IF v_team_count < v_group_count * 2 THEN
    RAISE EXCEPTION 'The stage-one roster would create a group with fewer than two teams. Adjust the group size first.';
  END IF;
  IF v_group_count * v_qualify_per_group <> v_expected_qualified THEN
    RAISE EXCEPTION 'Roadmap mismatch: % groups × % qualifiers = %, but the saved roadmap expects % qualified teams',
      v_group_count,v_qualify_per_group,v_group_count * v_qualify_per_group,v_expected_qualified;
  END IF;

  SELECT id INTO v_stage_id
  FROM public.event_rounds WHERE event_id = p_event_id AND round_number = 1
  FOR UPDATE;
  IF v_stage_id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.matches WHERE stage_id = v_stage_id) THEN
      RETURN jsonb_build_object(
        'already_generated',true,'stage_id',v_stage_id,
        'message','Stage one already has generated matches; existing roadmap was preserved.'
      );
    END IF;
    IF EXISTS (SELECT 1 FROM public.event_groups WHERE round_id = v_stage_id) THEN
      RAISE EXCEPTION 'Stage one has a partial group setup. Existing rows were preserved; review it before retrying.';
    END IF;
    RAISE EXCEPTION 'Stage one already exists without generated groups. Review the draft stage before retrying.';
  END IF;

  v_stage_name := COALESCE(NULLIF(v_roadmap->>'stage_name',''),
    NULLIF(trim(v_stage_names->>0),''),CASE WHEN v_stage_count=1 THEN 'Final' ELSE 'Stage 1' END);
  IF p_matches_per_group <> (v_roadmap->>'matches_per_group')::integer
     OR p_interval_minutes <> (v_roadmap->>'interval_minutes')::integer THEN
    RAISE EXCEPTION 'Stage 1 match settings differ from the published roadmap';
  END IF;
  v_first_match_at := (v_roadmap->>'first_match_at')::timestamptz;
  IF v_first_match_at IS NULL OR v_first_match_at <= now() THEN
    RAISE EXCEPTION 'Tournament start time must still be in the future before the initial schedule is generated';
  END IF;

  INSERT INTO public.event_rounds(
    event_id,round_number,name,status,starts_at,stage_type,group_size,
    matches_per_group,advancement_rules,configuration,room_release_minutes_before
  ) VALUES (
    p_event_id,1,v_stage_name,'draft',v_first_match_at,
    CASE WHEN v_stage_count = 1 THEN 'final' ELSE 'qualifier' END,
    v_group_size,p_matches_per_group,
    jsonb_build_object('mode','top_per_group','qualify_per_group',v_qualify_per_group,
      'qualified_team_count',v_expected_qualified,'direct_invites',v_direct_invites),
    jsonb_build_object('source','events.event_config','interval_minutes',p_interval_minutes,
      'first_match_at',v_first_match_at,'roadmap_version',COALESCE(v_event.event_config->>'schema_version','1'),
      'direct_invite_team_count',v_direct_invites),
    10
  ) RETURNING id INTO v_stage_id;

  INSERT INTO public.event_groups(round_id,label,sort_order)
  SELECT v_stage_id,'Group ' || n,n
  FROM generate_series(1,v_group_count) n;

  INSERT INTO public.event_group_teams(group_id,team_id,seeded_by)
  SELECT g.id, ranked.team_id, auth.uid()
  FROM (
    SELECT er.team_id,
      ntile(v_group_count) OVER (ORDER BY er.registered_at,er.team_id) AS group_number
    FROM public.event_registrations er
    WHERE er.event_id = p_event_id
      AND er.status IN ('approved','checked_in')
      AND er.roster_locked AND er.team_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.event_stage_direct_invites di
        WHERE di.event_id = p_event_id AND di.team_id = er.team_id
      )
  ) ranked
  JOIN public.event_groups g
    ON g.round_id = v_stage_id AND g.sort_order = ranked.group_number;

  v_result := app_private.generate_event_stage_matches(
    v_stage_id,p_matches_per_group,p_interval_minutes,v_first_match_at
  );

  INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
  VALUES (
    auth.uid(),p_event_id,'event_stage',v_stage_id,'roadmap_stage_one_generated',
    'Generated from the organiser-approved event_config roadmap',
    jsonb_build_object('group_size',v_group_size,'qualify_per_group',v_qualify_per_group,
      'registered_teams',v_registered_team_count,'grouped_stage_one_teams',v_team_count,
      'direct_invite_count',v_direct_invites,'group_count',v_group_count,
      'matches_per_group',p_matches_per_group,'interval_minutes',p_interval_minutes,
      'matches_created',v_result->'matches_created','stage_name',v_stage_name)
  );

  RETURN v_result || jsonb_build_object('stage_id',v_stage_id,'stage_name',v_stage_name,
    'qualified_team_count',v_expected_qualified,'direct_invite_count',v_direct_invites,
    'schedule_published',false);
END;
$function$;

CREATE OR REPLACE FUNCTION app_private.generate_event_stage_matches(p_stage_id uuid, p_matches_per_group integer, p_interval_minutes integer, p_first_match_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_stage public.event_rounds%rowtype;
  v_roadmap jsonb;
  v_group record;
  v_team record;
  v_match_id uuid;
  v_match_number integer;
  v_match_index integer;
  v_slot_number integer;
  v_group_count integer := 0;
  v_match_count integer := 0;
  v_team_count integer := 0;
  v_code text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_stage from public.event_rounds where id = p_stage_id for update;
  if not found then raise exception 'Tournament stage not found'; end if;
  if not app_private.is_event_staff(v_stage.event_id) then
    raise exception 'Only event staff can generate stage matches';
  end if;
  select configuration into v_roadmap from public.event_stage_roadmaps
   where event_id=v_stage.event_id and round_number=v_stage.round_number and published_at is not null;
  if v_roadmap is null or (select roadmap_published_at from public.events where id=v_stage.event_id) is null then
    raise exception 'Publish the complete roadmap before generating this stage schedule';
  end if;
  p_matches_per_group := (v_roadmap->>'matches_per_group')::integer;
  p_interval_minutes := (v_roadmap->>'interval_minutes')::integer;
  p_first_match_at := (v_roadmap->>'first_match_at')::timestamptz;
  if p_matches_per_group < 1 or p_matches_per_group > 20 then
    raise exception 'Matches per group must be between 1 and 20';
  end if;
  if p_interval_minutes < 1 or p_interval_minutes > 240 then
    raise exception 'Match interval must be between 1 and 240 minutes';
  end if;
  if p_first_match_at is null then
    raise exception 'First match time is required';
  end if;
  if exists (select 1 from public.matches where stage_id = p_stage_id) then
    raise exception 'This stage already has matches. Existing schedules were not changed.';
  end if;

  select coalesce(max(match_number), 0) into v_match_number
  from public.matches where event_id = v_stage.event_id;

  for v_group in
    select
      g.id,
      g.label,
      g.sort_order,
      count(gt.team_id)::integer as team_count
    from public.event_groups g
    join public.event_group_teams gt on gt.group_id = g.id
    where g.round_id = p_stage_id
    group by g.id, g.label, g.sort_order
    order by g.sort_order
  loop
    if v_group.team_count < 2 or v_group.team_count > 24 then
      raise exception 'Group % must contain between 2 and 24 teams', v_group.label;
    end if;

    if exists (
      select 1
      from public.event_group_teams gt
      where gt.group_id = v_group.id
        and not exists (
          select 1 from public.event_registrations er
          where er.event_id = v_stage.event_id
            and er.team_id = gt.team_id
            and er.status in ('approved','checked_in')
            and er.roster_locked
        )
    ) then
      raise exception 'Every team in % must have an approved, locked roster', v_group.label;
    end if;

    v_group_count := v_group_count + 1;
    v_team_count := v_team_count + v_group.team_count;

    for v_match_index in 1..p_matches_per_group loop
      v_match_number := v_match_number + 1;
      v_code := format(
        'S%s-G%s-M%s',
        lpad(v_stage.round_number::text, 2, '0'),
        lpad(v_group.sort_order::text, 2, '0'),
        lpad(v_match_index::text, 2, '0')
      );

      insert into public.matches (
        event_id, round_number, group_label, match_number,
        starts_at, status, host_user_id, stage_id, group_id,
        group_match_number, match_code
      )
      values (
        v_stage.event_id,
        v_stage.round_number,
        v_group.label,
        v_match_number,
        p_first_match_at + ((v_match_index - 1) * p_interval_minutes * interval '1 minute'),
        'scheduled',
        auth.uid(),
        p_stage_id,
        v_group.id,
        v_match_index,
        v_code
      )
      returning id into v_match_id;

      for v_team in
        select
          gt.team_id,
          row_number() over (order by gt.seeded_at, gt.team_id)::integer as team_position,
          er.id as registration_id
        from public.event_group_teams gt
        join public.event_registrations er
          on er.event_id = v_stage.event_id
         and er.team_id = gt.team_id
         and er.status in ('approved','checked_in')
         and er.roster_locked
        where gt.group_id = v_group.id
        order by gt.seeded_at, gt.team_id
      loop
        -- The seat is local to this match only. Rotation distributes starting
        -- seats fairly across a back-to-back series; it is never a global role.
        v_slot_number := mod(v_team.team_position - 1 + v_match_index - 1, v_group.team_count) + 1;
        insert into public.match_participants (
          match_id, team_id, registration_id, slot_number
        ) values (
          v_match_id, v_team.team_id, v_team.registration_id, v_slot_number
        );
      end loop;

      insert into public.audit_logs (
        actor_id, event_id, entity_type, entity_id, action, metadata
      ) values (
        auth.uid(), v_stage.event_id, 'match', v_match_id, 'stage_match_generated',
        jsonb_build_object(
          'stage_id', p_stage_id,
          'group_id', v_group.id,
          'match_code', v_code,
          'group_match_number', v_match_index,
          'team_count', v_group.team_count
        )
      );

      v_match_count := v_match_count + 1;
    end loop;
  end loop;

  if v_group_count = 0 then raise exception 'Generate stage groups before creating matches'; end if;

  update public.event_rounds
  set matches_per_group = p_matches_per_group,
      group_size = greatest(group_size, (
        select max(team_count)
        from (
          select count(*)::integer as team_count
          from public.event_group_teams gt
          join public.event_groups g on g.id = gt.group_id
          where g.round_id = p_stage_id
          group by g.id
        ) counts
      ))
  where id = p_stage_id;

  perform public.publish_event_stage_schedule(p_stage_id);
  return jsonb_build_object(
    'stage_id', p_stage_id,
    'group_count', v_group_count,
    'team_entries', v_team_count,
    'matches_created', v_match_count,
    'match_interval_minutes', p_interval_minutes
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.advance_event_stage_from_roadmap(p_source_stage_id uuid, p_matches_per_group integer, p_interval_minutes integer, p_first_match_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_source public.event_rounds%ROWTYPE;
  v_event public.events%ROWTYPE;
  v_roadmap jsonb;
  v_source_roadmap jsonb;
  v_names jsonb;
  v_stage_count integer;
  v_next_round integer;
  v_group_size integer;
  v_qualify integer;
  v_expected_qualified integer;
  v_direct_invites integer;
  v_invite_count integer;
  v_qualified_count integer;
  v_total_count integer;
  v_group_count integer;
  v_existing_group_count integer;
  v_target_stage_id uuid;
  v_stage_name text;
  v_advanced jsonb;
  v_matches jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_source FROM public.event_rounds WHERE id = p_source_stage_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Source stage not found'; END IF;
  IF NOT app_private.is_event_staff(v_source.event_id) THEN
    RAISE EXCEPTION 'Only authorised event staff can advance a stage';
  END IF;
  IF p_matches_per_group < 1 OR p_matches_per_group > 20
     OR p_interval_minutes < 1 OR p_interval_minutes > 240
     OR p_first_match_at IS NULL OR p_first_match_at <= now() THEN
    RAISE EXCEPTION 'Enter 1-20 matches, a 1-240 minute interval and a future first-match time';
  END IF;

  SELECT * INTO v_event FROM public.events WHERE id = v_source.event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;
  v_next_round := v_source.round_number+1;
  SELECT count(*)::integer INTO v_stage_count FROM public.event_stage_roadmaps
   WHERE event_id=v_event.id AND published_at IS NOT NULL;
  IF v_stage_count<1 OR v_next_round>v_stage_count THEN
    RAISE EXCEPTION 'The complete published roadmap has no next stage after %',v_source.name;
  END IF;
  SELECT configuration INTO v_source_roadmap FROM public.event_stage_roadmaps
   WHERE event_id=v_event.id AND round_number=v_source.round_number AND published_at IS NOT NULL;
  SELECT configuration INTO v_roadmap FROM public.event_stage_roadmaps
   WHERE event_id=v_event.id AND round_number=v_next_round AND published_at IS NOT NULL;
  IF v_source_roadmap IS NULL OR v_roadmap IS NULL OR v_event.roadmap_published_at IS NULL THEN
    RAISE EXCEPTION 'Publish the entire stage-to-stage roadmap before qualifying or advancing';
  END IF;
  v_group_size := (v_roadmap->>'group_size')::integer;
  v_qualify := (v_source_roadmap->>'qualifiers_per_group')::integer;
  v_expected_qualified := (v_source_roadmap->>'qualified_team_count')::integer;
  v_direct_invites := COALESCE((v_roadmap->>'direct_entry_count')::integer,0);
    IF v_group_size IS NULL OR v_group_size < 2 OR v_group_size > 24
     OR v_qualify IS NULL OR v_qualify < 1 OR v_qualify > 24 THEN
    RAISE EXCEPTION 'The saved roadmap group/qualification settings are incomplete';
  END IF;

  IF EXISTS (SELECT 1 FROM public.event_rounds WHERE event_id = v_event.id AND round_number = v_next_round) THEN
    RAISE EXCEPTION 'The next stage already exists; it will not be overwritten';
  END IF;

  SELECT count(*)::integer INTO v_invite_count
  FROM public.event_stage_direct_invites
  WHERE event_id = v_event.id AND target_round_number = v_next_round;
  IF v_invite_count <> v_direct_invites THEN
    RAISE EXCEPTION 'The roadmap expects % direct-entry teams for stage %, but % are assigned',
      v_direct_invites,v_next_round,v_invite_count;
  END IF;
  IF v_invite_count > 0 AND EXISTS (
    SELECT 1
    FROM public.event_stage_direct_invites di
    WHERE di.event_id = v_event.id
      AND di.target_round_number = v_next_round
      AND NOT EXISTS (
        SELECT 1 FROM public.event_registrations er
        JOIN public.teams t ON t.id = er.team_id
        WHERE er.event_id = v_event.id AND er.team_id = di.team_id
          AND er.status IN ('approved','checked_in') AND er.roster_locked
          AND t.game_id = v_event.game_id
      )
  ) THEN
    RAISE EXCEPTION 'A direct-entry team no longer has an approved, roster-locked registration for this event';
  END IF;

  v_stage_name := COALESCE(NULLIF(v_roadmap->>'stage_name',''),'Stage '||v_next_round);
  v_advanced := app_private.advance_event_stage(
    p_source_stage_id,v_stage_name,
    COALESCE(NULLIF(v_roadmap->>'stage_type',''),'custom'),
    v_group_size,v_qualify
  );
  v_target_stage_id := (v_advanced->>'target_stage_id')::uuid;
  v_qualified_count := COALESCE((v_advanced->>'qualified_team_count')::integer,0);
  IF v_qualified_count <> COALESCE(v_expected_qualified,-1) THEN
    RAISE EXCEPTION 'Approved standings qualify % teams, but the published source-stage roadmap expects %',
      v_qualified_count,v_expected_qualified;
  END IF;

  v_total_count := v_qualified_count + v_invite_count;
  v_group_count := ceil(v_total_count::numeric / v_group_size)::integer;
  IF v_total_count < v_group_count * 2 THEN
    RAISE EXCEPTION 'The next stage would create a group with fewer than two teams. Change the roadmap group size.';
  END IF;

  SELECT count(*)::integer INTO v_existing_group_count
  FROM public.event_groups WHERE round_id = v_target_stage_id;

  IF v_existing_group_count < v_group_count THEN
    INSERT INTO public.event_groups(round_id,label,sort_order)
    SELECT v_target_stage_id,'Group ' || n,n
    FROM generate_series(v_existing_group_count + 1,v_group_count) n;
  END IF;

  -- Remove stale channel membership snapshots before rebuilding the group
  -- distribution. Dynamic can_access_event_group remains the authoritative gate.
  DELETE FROM public.channel_members cm
  USING public.channels c
  WHERE c.id = cm.channel_id AND c.event_id = v_event.id
    AND c.stage_id = v_target_stage_id AND c.group_id IS NOT NULL;

  DELETE FROM public.event_group_teams egt
  USING public.event_groups g
  WHERE g.id = egt.group_id AND g.round_id = v_target_stage_id;

  WITH candidates AS (
    SELECT s.team_id,0 AS invite_order,g.sort_order AS source_group_order,
      s.group_rank,s.points,s.kills,s.first_places
    FROM public.event_stage_standings s
    JOIN public.event_groups g ON g.id = s.group_id
    WHERE s.stage_id = p_source_stage_id AND s.group_rank <= v_qualify
    UNION ALL
    SELECT di.team_id,1 AS invite_order,2147483647,2147483647,
      0::numeric,0::integer,0::integer
    FROM public.event_stage_direct_invites di
    WHERE di.event_id = v_event.id AND di.target_round_number = v_next_round
  ),
  ranked AS (
    SELECT team_id,
      row_number() OVER (
        ORDER BY invite_order,source_group_order,group_rank,
          points DESC,kills DESC,first_places DESC,team_id
      )::integer AS seed_index
    FROM candidates
  ),
  distributed AS (
    SELECT team_id,
      CASE
        WHEN (floor((seed_index - 1)::numeric / v_group_count)::integer % 2) = 0
          THEN mod(seed_index - 1,v_group_count) + 1
        ELSE v_group_count - mod(seed_index - 1,v_group_count)
      END AS target_group_order
    FROM ranked
  )
  INSERT INTO public.event_group_teams(group_id,team_id,seeded_by)
  SELECT g.id,d.team_id,auth.uid()
  FROM distributed d
  JOIN public.event_groups g
    ON g.round_id = v_target_stage_id AND g.sort_order = d.target_group_order;

  INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
  VALUES (
    auth.uid(),v_event.id,'event_stage',v_target_stage_id,'roadmap_direct_entry_teams_added',
    'Balanced the approved qualifiers and explicitly assigned direct-entry teams into the next stage',
    jsonb_build_object('source_stage_id',p_source_stage_id,
      'target_stage_id',v_target_stage_id,'qualified_team_count',v_qualified_count,
      'direct_invite_count',v_invite_count,'total_team_count',v_total_count,
      'target_group_count',v_group_count)
  );

  v_matches := app_private.generate_event_stage_matches(
    v_target_stage_id,p_matches_per_group,p_interval_minutes,p_first_match_at
  );

  RETURN v_advanced || v_matches || jsonb_build_object(
    'stage_name',v_stage_name,'group_count',v_group_count,
    'qualified_team_count',v_qualified_count,'direct_invite_count',v_invite_count,
    'total_team_count',v_total_count,'schedule_published',true
  );
END;
$function$;
