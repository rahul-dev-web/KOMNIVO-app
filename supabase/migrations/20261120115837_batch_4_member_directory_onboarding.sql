-- Batch 4 Checklist 1–2: member directory, configurable onboarding and channel recommendations.
-- Trust, privacy and permission checks are enforced in PostgreSQL; the client only calls these RPCs.

alter table public.channels
  add column if not exists onboarding_topics text[] not null default '{}'::text[],
  add column if not exists onboarding_game_modes text[] not null default '{}'::text[];

create table if not exists public.community_onboarding_questions (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  question_key text not null check (question_key in (
    'game_mode','player_interests','region','preferred_activities'
  )),
  prompt text not null,
  question_type text not null check (question_type in ('single_select','multi_select','text')),
  options jsonb not null default '[]'::jsonb check (jsonb_typeof(options)='array'),
  is_enabled boolean not null default true,
  is_required boolean not null default false,
  display_order integer not null default 0 check (display_order between 1 and 4),
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint community_onboarding_questions_community_key_unique
    unique (community_id,question_key),
  constraint community_onboarding_questions_required_enabled_check
    check (not is_required or is_enabled),
  constraint community_onboarding_questions_type_key_check check (
    (question_key='game_mode' and question_type='single_select' and display_order=1)
    or (question_key='player_interests' and question_type='multi_select' and display_order=2)
    or (question_key='region' and question_type='text' and display_order=3)
    or (question_key='preferred_activities' and question_type='multi_select' and display_order=4)
  )
);

create table if not exists public.community_onboarding_responses (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  question_key text not null check (question_key in (
    'game_mode','player_interests','region','preferred_activities'
  )),
  answer jsonb not null,
  updated_at timestamptz not null default now(),
  constraint community_onboarding_responses_unique
    unique (community_id,user_id,question_key)
);

create index if not exists community_members_directory_joined_idx
  on public.community_members(community_id,joined_at desc);
create index if not exists onboarding_questions_community_order_idx
  on public.community_onboarding_questions(community_id,display_order);
create index if not exists onboarding_responses_user_community_idx
  on public.community_onboarding_responses(community_id,user_id);
create index if not exists channels_onboarding_topics_gin
  on public.channels using gin(onboarding_topics);
create index if not exists channels_onboarding_game_modes_gin
  on public.channels using gin(onboarding_game_modes);

alter table public.community_onboarding_questions enable row level security;
alter table public.community_onboarding_responses enable row level security;

revoke all on public.community_onboarding_questions from public,anon,authenticated;
revoke all on public.community_onboarding_responses from public,anon,authenticated;
grant select on public.community_onboarding_questions to authenticated;
grant select on public.community_onboarding_responses to authenticated;

drop policy if exists community_onboarding_questions_read_member
  on public.community_onboarding_questions;
create policy community_onboarding_questions_read_member
on public.community_onboarding_questions
for select to authenticated
using (
  app_private.is_community_member(community_id)
  and (
    is_enabled
    or app_private.resolve_permission(
      'community.manage_members','community',community_id,null,null
    )
  )
);

drop policy if exists community_onboarding_responses_read_self_or_manager
  on public.community_onboarding_responses;
create policy community_onboarding_responses_read_self_or_manager
on public.community_onboarding_responses
for select to authenticated
using (
  (
    user_id=(select auth.uid())
    and app_private.is_community_member(community_id)
  )
  or app_private.resolve_permission(
    'community.manage_members','community',community_id,null,null
  )
);

create or replace function app_private.seed_community_onboarding_questions()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
begin
  insert into public.community_onboarding_questions(
    community_id,question_key,prompt,question_type,options,
    is_enabled,is_required,display_order,created_by,updated_by
  ) values
    (new.id,'game_mode','Which game mode do you play?','single_select',
      '["Battle Royale","Clash Squad"]'::jsonb,true,false,1,new.owner_user_id,new.owner_user_id),
    (new.id,'player_interests','What are you interested in?','multi_select',
      '["Rank push","Competitive scrims","Casual matches","Content creation","Coaching","Team building"]'::jsonb,true,false,2,new.owner_user_id,new.owner_user_id),
    (new.id,'region','Which region are you from?','text',
      '[]'::jsonb,true,false,3,new.owner_user_id,new.owner_user_id),
    (new.id,'preferred_activities','What would you like to do here?','multi_select',
      '["Find a team","Join tournaments","Play scrims","Learn strategies","Join voice sessions","Help organise events"]'::jsonb,true,false,4,new.owner_user_id,new.owner_user_id)
  on conflict (community_id,question_key) do nothing;
  return new;
end;
$function$;

revoke all on function app_private.seed_community_onboarding_questions() from public,anon,authenticated;

drop trigger if exists communities_seed_onboarding_questions on public.communities;
create trigger communities_seed_onboarding_questions
after insert on public.communities
for each row execute function app_private.seed_community_onboarding_questions();

insert into public.community_onboarding_questions(
  community_id,question_key,prompt,question_type,options,
  is_enabled,is_required,display_order,created_by,updated_by
)
select
  c.id,
  q.question_key,
  q.prompt,
  q.question_type,
  q.options,
  true,
  false,
  q.display_order,
  c.owner_user_id,
  c.owner_user_id
from public.communities c
cross join (values
  ('game_mode','Which game mode do you play?','single_select','["Battle Royale","Clash Squad"]'::jsonb,1),
  ('player_interests','What are you interested in?','multi_select','["Rank push","Competitive scrims","Casual matches","Content creation","Coaching","Team building"]'::jsonb,2),
  ('region','Which region are you from?','text','[]'::jsonb,3),
  ('preferred_activities','What would you like to do here?','multi_select','["Find a team","Join tournaments","Play scrims","Learn strategies","Join voice sessions","Help organise events"]'::jsonb,4)
) as q(question_key,prompt,question_type,options,display_order)
on conflict (community_id,question_key) do nothing;

create or replace function app_private.get_community_member_directory(
  p_community_id uuid
)
returns table (
  user_id uuid,
  role text,
  joined_at timestamptz,
  muted_until timestamptz,
  profiles jsonb,
  _community_roles jsonb,
  _game_accounts jsonb,
  _is_team_captain boolean,
  _is_event_participant boolean,
  _is_event_staff boolean
)
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception using errcode='28000',message='Authentication required.';
  end if;
  if p_community_id is null or not app_private.is_community_member(p_community_id) then
    raise exception using errcode='42501',message='Community membership is required to view its directory.';
  end if;
  if not app_private.resolve_permission('community.view','community',p_community_id,null,null) then
    raise exception using errcode='42501',message='You do not have permission to view this community.';
  end if;

  return query
  select
    cm.user_id,
    cm.role,
    cm.joined_at,
    cm.muted_until,
    jsonb_build_object(
      'display_name',p.display_name,
      'username',case when p.is_public then p.username else null end,
      'avatar_url',case when p.is_public then p.avatar_url else null end,
      'region',case when p.is_public then p.region else null end,
      'is_public',p.is_public
    ) as profiles,
    coalesce((
      select jsonb_agg(
        jsonb_build_object('name',cr.name,'preset_key',cr.preset_key,'colour',cr.colour)
        order by cr.position desc,cr.name
      )
      from public.community_member_roles cmr
      join public.community_roles cr
        on cr.id=cmr.role_id and cr.community_id=cmr.community_id
      where cmr.community_id=cm.community_id
        and cmr.user_id=cm.user_id
        and cr.archived_at is null
    ),'[]'::jsonb) as _community_roles,
    case when exists(
      select 1 from public.game_accounts ga
      where ga.user_id=cm.user_id and ga.ownership_status='verified'
    ) then jsonb_build_array(jsonb_build_object('ownership_status','verified'))
      else '[]'::jsonb
    end as _game_accounts,
    (
      exists(
        select 1 from public.teams t
        join public.team_members tm on tm.team_id=t.id
        where t.community_id=cm.community_id
          and tm.user_id=cm.user_id
          and tm.role in ('owner','captain')
      )
      or exists(
        select 1 from public.teams t
        where t.community_id=cm.community_id and t.owner_user_id=cm.user_id
      )
    ) as _is_team_captain,
    exists(
      select 1
      from public.events e
      join public.event_registrations er on er.event_id=e.id
      where e.community_id=cm.community_id
        and er.status in ('approved','checked_in')
        and (
          er.captain_user_id=cm.user_id
          or (
            er.team_id is not null
            and exists(
              select 1 from public.team_members tm
              where tm.team_id=er.team_id and tm.user_id=cm.user_id
            )
          )
          or exists(
            select 1 from public.registration_players rp
            where rp.registration_id=er.id and rp.user_id=cm.user_id
          )
        )
    ) as _is_event_participant,
    exists(
      select 1
      from public.event_staff_assignments esa
      join public.events e on e.id=esa.event_id
      where e.community_id=cm.community_id and esa.user_id=cm.user_id
    ) as _is_event_staff
  from public.community_members cm
  join public.profiles p on p.id=cm.user_id
  where cm.community_id=p_community_id
  order by cm.joined_at desc,p.display_name
  limit 1000;
end;
$function$;

revoke all on function app_private.get_community_member_directory(uuid) from public,anon;
grant execute on function app_private.get_community_member_directory(uuid) to authenticated;

create or replace function public.get_community_member_directory(p_community_id uuid)
returns table (
  user_id uuid,
  role text,
  joined_at timestamptz,
  muted_until timestamptz,
  profiles jsonb,
  _community_roles jsonb,
  _game_accounts jsonb,
  _is_team_captain boolean,
  _is_event_participant boolean,
  _is_event_staff boolean
)
language sql
stable
security invoker
set search_path=''
as $function$
  select * from app_private.get_community_member_directory(p_community_id);
$function$;

revoke all on function public.get_community_member_directory(uuid) from public,anon;
grant execute on function public.get_community_member_directory(uuid) to authenticated;

create or replace function app_private.get_community_onboarding_data(
  p_community_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_can_configure boolean;
  v_questions jsonb;
  v_answers jsonb;
begin
  if v_uid is null then
    raise exception using errcode='28000',message='Authentication required.';
  end if;
  if p_community_id is null or not app_private.is_community_member(p_community_id) then
    raise exception using errcode='42501',message='Community membership is required.';
  end if;
  v_can_configure := app_private.resolve_permission(
    'community.manage_members','community',p_community_id,null,null
  );

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'question_key',q.question_key,
      'prompt',q.prompt,
      'question_type',q.question_type,
      'options',q.options,
      'is_enabled',q.is_enabled,
      'is_required',q.is_required,
      'display_order',q.display_order
    ) order by q.display_order
  ),'[]'::jsonb)
  into v_questions
  from public.community_onboarding_questions q
  where q.community_id=p_community_id
    and (q.is_enabled or v_can_configure);

  select coalesce(jsonb_object_agg(r.question_key,r.answer),'{}'::jsonb)
  into v_answers
  from public.community_onboarding_responses r
  where r.community_id=p_community_id and r.user_id=v_uid;

  return jsonb_build_object(
    'questions',v_questions,
    'answers',v_answers,
    'can_configure',v_can_configure
  );
end;
$function$;

revoke all on function app_private.get_community_onboarding_data(uuid) from public,anon;
grant execute on function app_private.get_community_onboarding_data(uuid) to authenticated;

create or replace function public.get_community_onboarding_data(p_community_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path=''
as $function$
  select app_private.get_community_onboarding_data(p_community_id);
$function$;

revoke all on function public.get_community_onboarding_data(uuid) from public,anon;
grant execute on function public.get_community_onboarding_data(uuid) to authenticated;

create or replace function app_private.save_community_onboarding_configuration(
  p_community_id uuid,
  p_questions jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_item jsonb;
  v_key text;
  v_prompt text;
  v_type text;
  v_options jsonb;
  v_enabled boolean;
  v_required boolean;
  v_order integer;
  v_seen text[] := '{}'::text[];
  v_option_count integer;
begin
  if v_uid is null then
    raise exception using errcode='28000',message='Authentication required.';
  end if;
  if p_community_id is null or not app_private.resolve_permission(
    'community.manage_members','community',p_community_id,null,null
  ) then
    raise exception using errcode='42501',message='You do not have permission to configure onboarding.';
  end if;
  if jsonb_typeof(p_questions)<>'array' or jsonb_array_length(p_questions)<>4 then
    raise exception using errcode='22023',message='All four supported onboarding questions must be supplied.';
  end if;

  for v_item in select value from jsonb_array_elements(p_questions)
  loop
    v_key := v_item->>'question_key';
    v_prompt := btrim(coalesce(v_item->>'prompt',''));
    v_enabled := coalesce((v_item->>'is_enabled')::boolean,false);
    v_required := coalesce((v_item->>'is_required')::boolean,false);
    v_options := coalesce(v_item->'options','[]'::jsonb);

    v_order := case v_key
      when 'game_mode' then 1
      when 'player_interests' then 2
      when 'region' then 3
      when 'preferred_activities' then 4
      else null
    end;
    if v_order is null or v_key=any(v_seen) then
      raise exception using errcode='22023',message='Unsupported or duplicate onboarding question key.';
    end if;
    v_seen := array_append(v_seen,v_key);
    v_type := case when v_key='game_mode' then 'single_select'
      when v_key='region' then 'text'
      else 'multi_select' end;

    if char_length(v_prompt)<3 or char_length(v_prompt)>100 then
      raise exception using errcode='22023',message='Question prompt must contain 3–100 characters.';
    end if;
    if v_required and not v_enabled then
      raise exception using errcode='22023',message='A disabled question cannot be required.';
    end if;
    if jsonb_typeof(v_options)<>'array' then
      raise exception using errcode='22023',message='Question options must be a JSON array.';
    end if;
    if v_type='text' and jsonb_array_length(v_options)<>0 then
      raise exception using errcode='22023',message='Region is a text question and cannot have options.';
    end if;
    if v_type<>'text' then
      select count(*) into v_option_count
      from jsonb_array_elements_text(v_options) opt(value)
      where char_length(btrim(opt.value)) between 1 and 60;
      if v_option_count<>jsonb_array_length(v_options)
        or v_option_count<1 or v_option_count>30
        or v_option_count<>(
          select count(distinct lower(btrim(opt.value)))
          from jsonb_array_elements_text(v_options) opt(value)
        )
      then
        raise exception using errcode='22023',message='Select questions need 1–30 unique, non-empty options of at most 60 characters.';
      end if;
    end if;

    insert into public.community_onboarding_questions(
      community_id,question_key,prompt,question_type,options,
      is_enabled,is_required,display_order,created_by,updated_by
    ) values (
      p_community_id,v_key,v_prompt,v_type,v_options,
      v_enabled,(v_required and v_enabled),v_order,v_uid,v_uid
    )
    on conflict (community_id,question_key) do update
    set prompt=excluded.prompt,
        question_type=excluded.question_type,
        options=excluded.options,
        is_enabled=excluded.is_enabled,
        is_required=excluded.is_required,
        display_order=excluded.display_order,
        updated_by=v_uid,
        updated_at=now();
  end loop;

  if not (array['game_mode','player_interests','region','preferred_activities']::text[] <@ v_seen) then
    raise exception using errcode='22023',message='All four supported onboarding question keys are required.';
  end if;

  insert into public.audit_logs(
    actor_id,community_id,entity_type,action,metadata
  ) values (
    v_uid,p_community_id,'community_onboarding','onboarding.configuration.updated',
    jsonb_build_object('question_keys',v_seen)
  );

  return app_private.get_community_onboarding_data(p_community_id);
end;
$function$;

revoke all on function app_private.save_community_onboarding_configuration(uuid,jsonb) from public,anon;
grant execute on function app_private.save_community_onboarding_configuration(uuid,jsonb) to authenticated;

create or replace function public.save_community_onboarding_configuration(
  p_community_id uuid,
  p_questions jsonb
)
returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select app_private.save_community_onboarding_configuration(p_community_id,p_questions);
$function$;

revoke all on function public.save_community_onboarding_configuration(uuid,jsonb) from public,anon;
grant execute on function public.save_community_onboarding_configuration(uuid,jsonb) to authenticated;

create or replace function app_private.submit_community_onboarding_answers(
  p_community_id uuid,
  p_answers jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_question record;
  v_answer jsonb;
  v_choice text;
  v_valid_count integer;
  v_expected_count integer;
  v_saved_keys text[] := '{}'::text[];
begin
  if v_uid is null then
    raise exception using errcode='28000',message='Authentication required.';
  end if;
  if p_community_id is null or not app_private.is_community_member(p_community_id) then
    raise exception using errcode='42501',message='Community membership is required to submit onboarding answers.';
  end if;
  if jsonb_typeof(p_answers)<>'object' then
    raise exception using errcode='22023',message='Onboarding answers must be a JSON object.';
  end if;

  if exists(
    select 1 from jsonb_object_keys(p_answers) as supplied(key)
    where not exists(
      select 1 from public.community_onboarding_questions q
      where q.community_id=p_community_id
        and q.question_key=supplied.key
        and q.is_enabled
    )
  ) then
    raise exception using errcode='22023',message='Answers include an unknown or disabled question.';
  end if;

  for v_question in
    select q.question_key,q.question_type,q.options,q.is_required
    from public.community_onboarding_questions q
    where q.community_id=p_community_id and q.is_enabled
    order by q.display_order
  loop
    if not (p_answers ? v_question.question_key) then
      if v_question.is_required then
        raise exception using errcode='22023',message=format('The %s question is required.',v_question.question_key);
      end if;
      continue;
    end if;

    v_answer := p_answers->v_question.question_key;
    if v_question.question_type='single_select' then
      if jsonb_typeof(v_answer)<>'string' then
        raise exception using errcode='22023',message=format('%s must be a single choice.',v_question.question_key);
      end if;
      v_choice := v_answer #>> '{}';
      if not exists(
        select 1 from jsonb_array_elements_text(v_question.options) opt(value)
        where opt.value=v_choice
      ) then
        raise exception using errcode='22023',message=format('%s contains an unsupported choice.',v_question.question_key);
      end if;
    elsif v_question.question_type='multi_select' then
      if jsonb_typeof(v_answer)<>'array' then
        raise exception using errcode='22023',message=format('%s must be a list of choices.',v_question.question_key);
      end if;
      select count(*) into v_expected_count from jsonb_array_elements_text(v_answer);
      select count(*) into v_valid_count
      from jsonb_array_elements_text(v_answer) selected(value)
      where exists(
        select 1 from jsonb_array_elements_text(v_question.options) option_row(value)
        where option_row.value=selected.value
      );
      if v_expected_count>20
        or v_expected_count<>v_valid_count
        or v_expected_count<>(
          select count(distinct selected.value)
          from jsonb_array_elements_text(v_answer) selected(value)
        )
      then
        raise exception using errcode='22023',message=format('%s contains invalid or duplicate choices.',v_question.question_key);
      end if;
      if v_question.is_required and v_expected_count=0 then
        raise exception using errcode='22023',message=format('%s cannot be empty.',v_question.question_key);
      end if;
    elsif v_question.question_type='text' then
      if jsonb_typeof(v_answer)<>'string'
        or char_length(btrim(v_answer #>> '{}'))>80
      then
        raise exception using errcode='22023',message=format('%s must be text of at most 80 characters.',v_question.question_key);
      end if;
      if v_question.is_required and char_length(btrim(v_answer #>> '{}'))=0 then
        raise exception using errcode='22023',message=format('%s cannot be empty.',v_question.question_key);
      end if;
    end if;

    v_saved_keys := array_append(v_saved_keys,v_question.question_key);
  end loop;

  delete from public.community_onboarding_responses r
  where r.community_id=p_community_id and r.user_id=v_uid
    and exists(
      select 1 from public.community_onboarding_questions q
      where q.community_id=p_community_id
        and q.question_key=r.question_key
        and q.is_enabled
    );

  insert into public.community_onboarding_responses(
    community_id,user_id,question_key,answer,updated_at
  )
  select p_community_id,v_uid,supplied.key,supplied.value,now()
  from jsonb_each(p_answers) supplied(key,value);

  return jsonb_build_object(
    'saved',true,
    'question_keys',v_saved_keys,
    'updated_at',now()
  );
end;
$function$;

revoke all on function app_private.submit_community_onboarding_answers(uuid,jsonb) from public,anon;
grant execute on function app_private.submit_community_onboarding_answers(uuid,jsonb) to authenticated;

create or replace function public.submit_community_onboarding_answers(
  p_community_id uuid,
  p_answers jsonb
)
returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select app_private.submit_community_onboarding_answers(p_community_id,p_answers);
$function$;

revoke all on function public.submit_community_onboarding_answers(uuid,jsonb) from public,anon;
grant execute on function public.submit_community_onboarding_answers(uuid,jsonb) to authenticated;

create or replace function app_private.save_community_channel_onboarding_tags(
  p_community_id uuid,
  p_channel_id uuid,
  p_topics text[],
  p_game_modes text[]
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_allowed_topics text[];
  v_allowed_modes text[];
  v_topics text[] := coalesce(p_topics,'{}'::text[]);
  v_modes text[] := coalesce(p_game_modes,'{}'::text[]);
begin
  if v_uid is null then
    raise exception using errcode='28000',message='Authentication required.';
  end if;
  if p_community_id is null or not app_private.resolve_permission(
    'community.manage_structure','community',p_community_id,null,null
  ) then
    raise exception using errcode='42501',message='You do not have permission to edit channel recommendations.';
  end if;
  if cardinality(v_topics)>40
    or cardinality(v_modes)>20
    or array_position(v_topics,null) is not null
    or array_position(v_modes,null) is not null
    or cardinality(v_topics)<>(
      select count(distinct lower(x)) from unnest(v_topics) x
    )
    or cardinality(v_modes)<>(
      select count(distinct lower(x)) from unnest(v_modes) x
    )
  then
    raise exception using errcode='22023',message='Channel recommendation tags are duplicated or exceed their allowed size.';
  end if;

  select coalesce(array_agg(distinct option_row.value),'{}'::text[])
  into v_allowed_topics
  from public.community_onboarding_questions q,
       jsonb_array_elements_text(q.options) option_row(value)
  where q.community_id=p_community_id
    and q.is_enabled
    and q.question_key in ('player_interests','preferred_activities');

  select coalesce(array_agg(distinct option_row.value),'{}'::text[])
  into v_allowed_modes
  from public.community_onboarding_questions q,
       jsonb_array_elements_text(q.options) option_row(value)
  where q.community_id=p_community_id
    and q.is_enabled
    and q.question_key='game_mode';

  if exists(
    select 1 from unnest(v_topics) supplied(value)
    where not (supplied.value=any(v_allowed_topics))
  ) or exists(
    select 1 from unnest(v_modes) supplied(value)
    where not (supplied.value=any(v_allowed_modes))
  ) then
    raise exception using errcode='22023',message='A channel tag does not match a currently enabled onboarding option.';
  end if;

  update public.channels c
  set onboarding_topics=v_topics,
      onboarding_game_modes=v_modes
  where c.id=p_channel_id
    and c.community_id=p_community_id
    and c.event_id is null
    and c.archived_at is null;

  if not found then
    raise exception using errcode='P0002',message='Channel not found in this community.';
  end if;

  insert into public.audit_logs(
    actor_id,community_id,entity_type,entity_id,action,metadata
  ) values (
    v_uid,p_community_id,'community_channel',p_channel_id,
    'channel.onboarding_tags.updated',
    jsonb_build_object('topics',v_topics,'game_modes',v_modes)
  );

  return jsonb_build_object('saved',true,'channel_id',p_channel_id);
end;
$function$;

revoke all on function app_private.save_community_channel_onboarding_tags(uuid,uuid,text[],text[]) from public,anon;
grant execute on function app_private.save_community_channel_onboarding_tags(uuid,uuid,text[],text[]) to authenticated;

create or replace function public.save_community_channel_onboarding_tags(
  p_community_id uuid,
  p_channel_id uuid,
  p_topics text[],
  p_game_modes text[]
)
returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select app_private.save_community_channel_onboarding_tags(
    p_community_id,p_channel_id,p_topics,p_game_modes
  );
$function$;

revoke all on function public.save_community_channel_onboarding_tags(uuid,uuid,text[],text[]) from public,anon;
grant execute on function public.save_community_channel_onboarding_tags(uuid,uuid,text[],text[]) to authenticated;

create or replace function app_private.get_community_channel_recommendations(
  p_community_id uuid
)
returns table (
  channel_id uuid,
  name text,
  kind text,
  description text,
  matched_topics text[],
  matched_game_modes text[],
  match_score integer
)
language plpgsql
stable
security definer
set search_path=''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_topics text[] := '{}'::text[];
  v_modes text[] := '{}'::text[];
begin
  if v_uid is null then
    raise exception using errcode='28000',message='Authentication required.';
  end if;
  if p_community_id is null or not app_private.is_community_member(p_community_id) then
    raise exception using errcode='42501',message='Community membership is required.';
  end if;

  select coalesce(array_agg(distinct selected.value),'{}'::text[])
  into v_topics
  from public.community_onboarding_responses r,
       lateral jsonb_array_elements_text(
         case when jsonb_typeof(r.answer)='array' then r.answer else '[]'::jsonb end
       ) selected(value)
  where r.community_id=p_community_id
    and r.user_id=v_uid
    and r.question_key in ('player_interests','preferred_activities');

  select coalesce(array_agg(distinct r.answer #>> '{}'),'{}'::text[])
  into v_modes
  from public.community_onboarding_responses r
  where r.community_id=p_community_id
    and r.user_id=v_uid
    and r.question_key='game_mode'
    and jsonb_typeof(r.answer)='string';

  return query
  select
    c.id,
    c.name,
    c.kind,
    c.description,
    array(
      select topic from unnest(c.onboarding_topics) topic
      where topic=any(v_topics)
    ) as matched_topics,
    array(
      select mode from unnest(c.onboarding_game_modes) mode
      where mode=any(v_modes)
    ) as matched_game_modes,
    (
      select count(*)::integer
      from (
        select topic from unnest(c.onboarding_topics) topic where topic=any(v_topics)
        union all
        select mode from unnest(c.onboarding_game_modes) mode where mode=any(v_modes)
      ) matched
    ) as match_score
  from public.channels c
  where c.community_id=p_community_id
    and c.event_id is null
    and c.archived_at is null
    and app_private.resolve_permission('channel.view','community',p_community_id,null,c.id)
    and (
      c.onboarding_topics && v_topics
      or c.onboarding_game_modes && v_modes
    )
  order by match_score desc,c.name
  limit 30;
end;
$function$;

revoke all on function app_private.get_community_channel_recommendations(uuid) from public,anon;
grant execute on function app_private.get_community_channel_recommendations(uuid) to authenticated;

create or replace function public.get_community_channel_recommendations(p_community_id uuid)
returns table (
  channel_id uuid,
  name text,
  kind text,
  description text,
  matched_topics text[],
  matched_game_modes text[],
  match_score integer
)
language sql
stable
security invoker
set search_path=''
as $function$
  select * from app_private.get_community_channel_recommendations(p_community_id);
$function$;

revoke all on function public.get_community_channel_recommendations(uuid) from public,anon;
grant execute on function public.get_community_channel_recommendations(uuid) to authenticated;
