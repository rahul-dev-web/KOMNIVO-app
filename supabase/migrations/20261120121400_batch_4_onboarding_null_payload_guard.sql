-- Reject SQL NULL payloads before an onboarding write can clear existing responses.
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
  if p_questions is null
    or jsonb_typeof(p_questions)<>'array'
    or jsonb_array_length(p_questions)<>4
  then
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
  if p_answers is null or jsonb_typeof(p_answers)<>'object' then
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

revoke all on function app_private.save_community_onboarding_configuration(uuid,jsonb) from public,anon;
grant execute on function app_private.save_community_onboarding_configuration(uuid,jsonb) to authenticated;
revoke all on function app_private.submit_community_onboarding_answers(uuid,jsonb) from public,anon;
grant execute on function app_private.submit_community_onboarding_answers(uuid,jsonb) to authenticated;