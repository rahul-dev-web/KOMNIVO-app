alter table public.channel_settings
  add column if not exists allow_threads boolean not null default true,
  add column if not exists allow_pins boolean not null default true,
  add column if not exists keep_history boolean not null default true;

create or replace function app_private.guard_batch3_channel_message()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  v_settings public.channel_settings%rowtype;
  v_last_sent timestamptz;
  v_kind text;
  v_community_id uuid;
begin
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
  select c.kind,c.community_id into v_kind,v_community_id
  from public.channels c where c.id=new.channel_id and c.archived_at is null;
  if v_kind is null then raise exception 'Channel is unavailable or archived'; end if;
  select * into v_settings from public.channel_settings where channel_id=new.channel_id;
  if v_settings.channel_id is not null and v_settings.read_only
    and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
  then raise exception 'This channel is read-only'; end if;
  if not app_private.can_send_channel_message(new.channel_id)
    and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
  then raise exception 'You cannot send messages in this channel'; end if;
  if new.parent_message_id is not null and v_settings.channel_id is not null and not v_settings.allow_threads
    and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
  then raise exception 'Message threads are disabled in this channel'; end if;
  if v_settings.channel_id is not null then
    if v_settings.announcement_publishers_only
      and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
    then raise exception 'Only authorised announcement publishers can post'; end if;
    if not v_settings.allow_links and new.body ~* '(https?://|www\\.)'
    then raise exception 'Links are disabled in this channel'; end if;
    if not v_settings.allow_everyone_mention and new.body ~ '(^|[[:space:]])@everyone([[:space:]]|$)'
    then raise exception '@everyone mentions are disabled in this channel'; end if;
    if not v_settings.allow_role_mentions and new.body ~ '<@&[0-9a-fA-F-]{36}>'
    then raise exception 'Role mentions are disabled in this channel'; end if;
    if not v_settings.allow_user_mentions and new.body ~ '<@[0-9a-fA-F-]{36}>'
    then raise exception 'User mentions are disabled in this channel'; end if;
    if v_settings.slow_mode_seconds > 0
      and not app_private.resolve_permission('channel.manage_messages','community',v_community_id,null,new.channel_id)
    then
      select max(m.created_at) into v_last_sent from public.messages m
      where m.channel_id=new.channel_id and m.sender_id=new.sender_id and m.deleted_at is null;
      if v_last_sent is not null and v_last_sent > now() - make_interval(secs => v_settings.slow_mode_seconds)
      then raise exception 'Slow mode is active. Please wait before sending again'; end if;
    end if;
  end if;
  return new;
end;
$function$;

create or replace function app_private.guard_batch3_message_pin()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare v_allowed boolean; v_community uuid; v_channel uuid;
begin
  if session_user='postgres' or auth.role()='service_role' then return new; end if;
  v_channel := case when tg_op='DELETE' then old.channel_id else new.channel_id end;
  select c.community_id into v_community from public.channels c where c.id=v_channel;
  select coalesce(cs.allow_pins,true) into v_allowed from public.channel_settings cs where cs.channel_id=v_channel;
  if not coalesce(v_allowed,true) then raise exception 'Pins are disabled in this channel'; end if;
  if not app_private.resolve_permission('channel.manage_messages','community',v_community,null,v_channel)
  then raise exception 'You cannot manage pinned messages in this channel'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$function$;
revoke all on function app_private.guard_batch3_message_pin() from public,anon,authenticated;
drop trigger if exists message_pins_batch3_guard on public.message_pins;
create trigger message_pins_batch3_guard before insert or delete on public.message_pins
for each row execute function app_private.guard_batch3_message_pin();
