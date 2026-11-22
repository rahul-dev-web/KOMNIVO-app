-- Phase 4 hardening: move direct-entry teams between stages safely and
-- alert every assigned tournament staff member while a live roadmap is unpublished.
CREATE OR REPLACE FUNCTION public.set_event_stage_direct_invites(
  p_event_id uuid,p_target_round_number integer,p_team_ids uuid[]
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $function$
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
END;$function$;
REVOKE ALL ON FUNCTION public.set_event_stage_direct_invites(uuid,integer,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.set_event_stage_direct_invites(uuid,integer,uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION app_private.dispatch_unpublished_roadmap_live_match_alerts()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $function$
DECLARE r record; user_id uuid; notice uuid; sent integer:=0; bucket text;
BEGIN
 bucket:=floor(extract(epoch FROM now())/3600)::bigint::text;
 FOR r IN SELECT DISTINCT e.id event_id,e.organizer_id,e.name event_name,s.id stage_id,s.name stage_name
  FROM public.events e JOIN public.event_rounds s ON s.event_id=e.id
  JOIN public.matches m ON m.stage_id=s.id AND m.status='live'
  LEFT JOIN public.event_stage_roadmaps rm ON rm.event_id=e.id AND rm.round_number=s.round_number AND rm.published_at IS NOT NULL
  WHERE e.roadmap_published_at IS NULL OR rm.event_id IS NULL
 LOOP
  FOR user_id IN
   SELECT r.organizer_id
   UNION SELECT esa.user_id FROM public.event_staff_assignments esa WHERE esa.event_id=r.event_id
  LOOP
   notice:=app_private.enqueue_event_notification(r.event_id,user_id,
    'roadmap_unpublished_live:'||r.stage_id::text||':'||bucket,
    'Action required: tournament roadmap not published',
    r.event_name||' · '||r.stage_name||
    ' has a live match, but the complete stage-to-stage roadmap is not published. Publish the full roadmap now.');
   IF notice IS NOT NULL THEN sent:=sent+1; END IF;
  END LOOP;
 END LOOP;
 RETURN sent;
END;$function$;
REVOKE ALL ON FUNCTION app_private.dispatch_unpublished_roadmap_live_match_alerts() FROM PUBLIC,anon,authenticated;
