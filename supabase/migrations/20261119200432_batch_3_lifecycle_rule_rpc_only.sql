-- Batch 3: lifecycle rules can only be changed through the validated scope-aware RPC.
-- Reads remain available to authorised event managers; direct INSERT/UPDATE/DELETE
-- could otherwise bypass the event/stage/match ownership checks in the RPC.
revoke insert, update, delete, truncate, references, trigger
  on table public.event_channel_lifecycle_rules
  from anon, authenticated;
grant select on table public.event_channel_lifecycle_rules to authenticated;

revoke all on function public.save_event_channel_lifecycle_rule(
  uuid,text,uuid,text,text,boolean,boolean,boolean
) from public, anon;
grant execute on function public.save_event_channel_lifecycle_rule(
  uuid,text,uuid,text,text,boolean,boolean,boolean
) to authenticated;
