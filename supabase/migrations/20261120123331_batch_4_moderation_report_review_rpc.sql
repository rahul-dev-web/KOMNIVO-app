-- Batch 4 audited report review operation.
CREATE OR REPLACE FUNCTION public.review_community_moderation_report(p_report_id uuid, p_status text, p_review_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_uid uuid := (select auth.uid());
 v_community_id uuid;
 v_current_status text;
begin
 if v_uid is null then
  raise exception using errcode='28000',message='Authentication required.';
 end if;
 if p_status not in ('reviewing','resolved','dismissed') then
  raise exception using errcode='22023',message='Unsupported report status.';
 end if;
 if char_length(coalesce(p_review_note,''))>1000 then
  raise exception using errcode='22023',message='Review note exceeds 1000 characters.';
 end if;

 select community_id,status into v_community_id,v_current_status
 from public.moderation_reports
 where id=p_report_id
 for update;
 if not found then raise exception using errcode='P0002',message='Report not found.'; end if;

 if not app_private.resolve_permission(
  'community.manage_members','community',v_community_id,null,null
 ) then
  raise exception using errcode='42501',message='You cannot review reports in this community.';
 end if;
 if v_current_status in ('resolved','dismissed') then
  raise exception using errcode='22023',message='This report is already closed.';
 end if;

 update public.moderation_reports
 set status=p_status,
     assigned_to=v_uid,
     resolved_at=case when p_status in ('resolved','dismissed') then now() else null end
 where id=p_report_id;

 insert into public.audit_logs(
  actor_id,community_id,entity_type,entity_id,action,reason,metadata
 ) values (
  v_uid,v_community_id,'moderation_report',p_report_id,
  'moderation.report.'||p_status,nullif(btrim(coalesce(p_review_note,'')),''),
  jsonb_build_object('previous_status',v_current_status,'status',p_status)
 );

 return jsonb_build_object('saved',true,'status',p_status);
end;
$function$

revoke all on function public.review_community_moderation_report(uuid,text,text) from public,anon;
grant execute on function public.review_community_moderation_report(uuid,text,text) to authenticated;
