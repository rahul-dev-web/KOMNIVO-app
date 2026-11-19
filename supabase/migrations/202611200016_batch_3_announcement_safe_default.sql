-- Batch 3: announcement channel safety defaults are enforced even before
-- a channel_settings row exists; an explicit saved setting can opt out.

create or replace function app_private.guard_batch3_channel_message()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_settings public.channel_settings%rowtype;
  v_last_sent timestamptz;
  v_channel public.channels%rowtype;
  v_can_manage boolean;
  v_announcement_publishers_only boolean;
begin
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
  select * into v_channel from public.channels c
  where c.id=new.channel_id and c.archived_at is null;
  if not found then raise exception 'Channel is unavailable or archived'; end if;
  select * into v_settings from public.channel_settings where channel_id=new.channel_id;

  v_can_manage := case
    when v_channel.event_id is not null then app_private.can_manage_event_channel(v_channel.id)
    else app_private.resolve_permission('channel.manage_messages','community',v_channel.community_id,null,v_channel.id)
  end;
  v_announcement_publishers_only := case
    when v_settings.channel_id is null then v_channel.kind='announcement'
    else v_settings.announcement_publishers_only
  end;

  if v_settings.channel_id is not null and v_settings.read_only and not v_can_manage
  then raise exception 'This channel is read-only'; end if;
  if not app_private.can_send_channel_message(new.channel_id) and not v_can_manage
  then raise exception 'You cannot send messages in this channel'; end if;
  if new.parent_message_id is not null and v_settings.channel_id is not null
    and not v_settings.allow_threads and not v_can_manage
  then raise exception 'Message threads are disabled in this channel'; end if;

  if v_announcement_publishers_only and not v_can_manage
  then raise exception 'Only authorised announcement publishers can post'; end if;
  if v_settings.channel_id is not null then
    if not v_settings.allow_links and new.body ~* '(https?://|www[.])'
    then raise exception 'Links are disabled in this channel'; end if;
    if not v_settings.allow_everyone_mention
      and new.body ~* '(^|[[:space:]])@(everyone|here)([[:space:]]|$)'
    then raise exception 'Broad mentions are disabled in this channel'; end if;
    if not v_settings.allow_role_mentions and new.body ~ '<@&[0-9a-fA-F-]{36}>'
    then raise exception 'Role mentions are disabled in this channel'; end if;
    if not v_settings.allow_user_mentions and new.body ~ '<@[0-9a-fA-F-]{36}>'
    then raise exception 'User mentions are disabled in this channel'; end if;

    if v_settings.slow_mode_seconds > 0 and not v_can_manage then
      perform pg_advisory_xact_lock(hashtextextended(new.channel_id::text||':'||new.sender_id::text,0));
      select max(m.created_at) into v_last_sent from public.messages m
      where m.channel_id=new.channel_id and m.sender_id=new.sender_id and m.deleted_at is null;
      if v_last_sent is not null and v_last_sent > now() - make_interval(secs => v_settings.slow_mode_seconds)
      then raise exception 'Slow mode is active. Please wait before sending again'; end if;
    end if;
  end if;
  return new;
end;
$function$;
