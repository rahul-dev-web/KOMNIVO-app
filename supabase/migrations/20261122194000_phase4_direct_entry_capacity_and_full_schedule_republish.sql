-- Phase 4 final correction: do not silently accept an unplaced direct-entry
-- team, and make full-roadmap republication republish existing stage schedules.
CREATE OR REPLACE FUNCTION public.set_event_stage_direct_invites(p_event_id uuid, p_target_round_number integer, p_team_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 e public.events%rowtype; n integer; tid uuid; reg uuid; gid uuid; m record; slot_no integer; added integer:=0;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF NOT app_private.is_event_staff(p_event_id) THEN RAISE EXCEPTION 'Only authorised event staff can assign direct-entry teams'; END IF;
 SELECT * INTO e FROM public.events WHERE id=p_event_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found'; END IF;
 n:=COALESCE(NULLIF(e.event_config->>'stage_count','')::integer,0);
 IF p_target_round_number IS NULL OR p_target_round_number<1 OR p_target_round_number>n THEN RAISE EXCEPTION 'Choose a stage between 1 and %',n; END IF;
 IF COALESCE(cardinality(p_team_ids),0)=0 OR (SELECT count(DISTINCT x)::integer FROM unnest(p_team_ids) AS x)<>cardinality(p_team_ids) THEN RAISE EXCEPTION 'Select one or more unique teams'; END IF;
 IF EXISTS(SELECT 1 FROM public.matches WHERE event_id=p_event_id AND round_number=p_target_round_number
  AND status IN ('check_in','room_setup','lobby_review','live','awaiting_result','review','completed')) THEN
  RAISE EXCEPTION 'Target stage has started or has results; direct-entry changes are locked';
 END IF;
 FOREACH tid IN ARRAY p_team_ids LOOP
  SELECT er.id INTO reg FROM public.event_registrations er JOIN public.teams t ON t.id=er.team_id
   WHERE er.event_id=p_event_id AND er.team_id=tid AND er.status IN ('approved','checked_in')
    AND er.roster_locked AND t.game_id=e.game_id ORDER BY er.registered_at DESC LIMIT 1;
  IF reg IS NULL THEN RAISE EXCEPTION 'Direct-entry teams require approved, roster-locked registration for this event and game'; END IF;
  IF EXISTS(SELECT 1 FROM public.event_groups g JOIN public.event_rounds r ON r.id=g.round_id
    JOIN public.event_group_teams gt ON gt.group_id=g.id WHERE r.event_id=p_event_id
     AND r.round_number=p_target_round_number AND gt.team_id=tid) THEN
   RAISE EXCEPTION 'Team is already assigned to target stage';
  END IF;
  IF EXISTS(SELECT 1 FROM public.matches m JOIN public.match_participants mp ON mp.match_id=m.id
    WHERE m.event_id=p_event_id AND m.round_number<>p_target_round_number AND mp.team_id=tid
      AND m.status IN ('check_in','room_setup','lobby_review','live','awaiting_result','review','completed')) THEN
   RAISE EXCEPTION 'Team has entered match operations in another stage and cannot be moved';
  END IF;
  IF EXISTS(SELECT 1 FROM public.event_group_teams gt JOIN public.event_groups g ON g.id=gt.group_id
    JOIN public.event_rounds r ON r.id=g.round_id WHERE r.event_id=p_event_id
      AND r.round_number<>p_target_round_number AND gt.team_id=tid
      AND (SELECT count(*) FROM public.event_group_teams other WHERE other.group_id=g.id)<=2) THEN
   RAISE EXCEPTION 'Moving this team would leave an earlier group with fewer than two teams';
  END IF;

  DELETE FROM public.match_participants mp USING public.matches m
   WHERE m.id=mp.match_id AND m.event_id=p_event_id AND m.round_number<>p_target_round_number
    AND mp.team_id=tid AND m.status IN ('scheduled','cancelled');
  DELETE FROM public.channel_members cm USING public.channels c
   WHERE c.id=cm.channel_id AND c.event_id=p_event_id
    AND c.group_id IN (SELECT g.id FROM public.event_groups g JOIN public.event_rounds r ON r.id=g.round_id
      JOIN public.event_group_teams gt ON gt.group_id=g.id
      WHERE r.event_id=p_event_id AND r.round_number<>p_target_round_number AND gt.team_id=tid)
    AND cm.user_id IN (SELECT tm.user_id FROM public.team_members tm WHERE tm.team_id=tid
      UNION SELECT t.owner_user_id FROM public.teams t WHERE t.id=tid);
  DELETE FROM public.event_group_teams gt USING public.event_groups g,public.event_rounds r
   WHERE g.id=gt.group_id AND r.id=g.round_id AND r.event_id=p_event_id
    AND r.round_number<>p_target_round_number AND gt.team_id=tid;
  DELETE FROM public.event_stage_direct_invites WHERE event_id=p_event_id AND team_id=tid;
  INSERT INTO public.event_stage_direct_invites(event_id,team_id,target_round_number,assigned_by)
   VALUES(p_event_id,tid,p_target_round_number,auth.uid());

  SELECT g.id INTO gid FROM public.event_groups g JOIN public.event_rounds r ON r.id=g.round_id
   LEFT JOIN public.event_group_teams gt ON gt.group_id=g.id
   WHERE r.event_id=p_event_id AND r.round_number=p_target_round_number
   GROUP BY g.id,g.sort_order HAVING count(gt.team_id)<24 ORDER BY count(gt.team_id),g.sort_order LIMIT 1;
  IF gid IS NOT NULL THEN
   INSERT INTO public.event_group_teams(group_id,team_id,seeded_by) VALUES(gid,tid,auth.uid());
   FOR m IN SELECT id FROM public.matches WHERE event_id=p_event_id AND round_number=p_target_round_number
    AND group_id=gid AND status='scheduled'
   LOOP
    SELECT s INTO slot_no FROM generate_series(1,24)s
     WHERE NOT EXISTS(SELECT 1 FROM public.match_participants mp WHERE mp.match_id=m.id AND mp.slot_number=s)
     ORDER BY s LIMIT 1;
    IF slot_no IS NULL THEN RAISE EXCEPTION 'No free slot remains in target-stage match'; END IF;
    INSERT INTO public.match_participants(match_id,team_id,registration_id,slot_number) VALUES(m.id,tid,reg,slot_no);
   END LOOP;
  ELSIF EXISTS(SELECT 1 FROM public.event_rounds WHERE event_id=p_event_id AND round_number=p_target_round_number) THEN
   RAISE EXCEPTION 'Target stage groups are full; increase group capacity before assigning this team';
  ELSIF EXISTS(SELECT 1 FROM public.event_rounds WHERE event_id=p_event_id AND round_number=p_target_round_number) THEN
   RAISE EXCEPTION 'Target stage groups are full; increase group capacity before assigning this team';
  END IF;
  added:=added+1;
 END LOOP;
 UPDATE public.events SET roadmap_published_at=NULL,roadmap_published_by=NULL WHERE id=p_event_id;
 UPDATE public.event_rounds SET schedule_published_at=NULL,schedule_published_by=NULL,status='draft'
  WHERE event_id=p_event_id AND round_number=p_target_round_number;
 INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
 VALUES(auth.uid(),p_event_id,'event',p_event_id,'roadmap_direct_entry_assigned',
  'Organiser moved/assigned direct-entry teams to selected stage',
  jsonb_build_object('target_round_number',p_target_round_number,'team_ids',to_jsonb(p_team_ids),'team_count',added));
 RETURN jsonb_build_object('event_id',p_event_id,'target_round_number',p_target_round_number,
  'assigned_count',added,'team_ids',to_jsonb(p_team_ids),'republish_required',true);
END;$function$
;
CREATE OR REPLACE FUNCTION public.publish_event_roadmap(p_event_id uuid, p_stage_configs jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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
  AND EXISTS(SELECT 1 FROM public.matches m WHERE m.stage_id=r.id)  ORDER BY r.round_number
 LOOP PERFORM public.publish_event_stage_schedule(sid); END LOOP;
 INSERT INTO public.audit_logs(actor_id,event_id,entity_type,entity_id,action,reason,metadata)
 VALUES(auth.uid(),p_event_id,'event',p_event_id,'complete_event_roadmap_published','Complete stage-to-stage roadmap published in one action',
  jsonb_build_object('roadmap_version',version_n,'stage_count',n,'summary',summary));
 RETURN jsonb_build_object('event_id',p_event_id,'roadmap_version',version_n,'stage_count',n,'roadmap_published',true);
END;$function$
;
