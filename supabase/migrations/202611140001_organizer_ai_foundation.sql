-- KOMNIVO AI foundation: private, scope-aware conversations and audit records.
-- Organizer AI is restricted to community owner/admin/organiser or event organiser.
-- Player AI is restricted to the signed-in player's own event participation/community membership.
-- Model output is advisory only; this migration does not grant AI permission to execute business actions.

create schema if not exists app_private;
revoke all on schema app_private from public, anon;

create or replace function app_private.can_access_ai_scope(
  p_mode text, p_community_id uuid default null, p_event_id uuid default null
) returns boolean
language plpgsql stable security definer set search_path = ''
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_event_community uuid;
  v_event_organizer uuid;
begin
  if v_uid is null then return false; end if;
  if p_mode = 'organizer' then
    if p_community_id is null and p_event_id is null then return false; end if;
    if p_community_id is not null and not exists (
      select 1 from public.community_members cm
      where cm.community_id = p_community_id and cm.user_id = v_uid
        and cm.role in ('owner','admin','organiser')
    ) then return false; end if;
    if p_event_id is not null then
      select e.community_id, e.organizer_id into v_event_community, v_event_organizer
      from public.events e where e.id = p_event_id;
      if not found then return false; end if;
      if p_community_id is not null and v_event_community is distinct from p_community_id then return false; end if;
      if v_event_organizer is distinct from v_uid and not (
        v_event_community is not null and exists (
          select 1 from public.community_members cm
          where cm.community_id = v_event_community and cm.user_id = v_uid
            and cm.role in ('owner','admin','organiser')
        )
      ) then return false; end if;
    end if;
    return true;
  elsif p_mode = 'player' then
    if p_community_id is not null and not exists (
      select 1 from public.community_members cm
      where cm.community_id = p_community_id and cm.user_id = v_uid
    ) then return false; end if;
    if p_event_id is not null and not exists (
      select 1 from public.event_registrations er
      where er.event_id = p_event_id and (
        er.captain_user_id = v_uid or exists (
          select 1 from public.registration_players rp
          where rp.registration_id = er.id and rp.user_id = v_uid
        )
      )
    ) then return false; end if;
    return true;
  end if;
  return false;
end;
$function$;
revoke all on function app_private.can_access_ai_scope(text,uuid,uuid) from public, anon;
grant usage on schema app_private to authenticated;
grant execute on function app_private.can_access_ai_scope(text,uuid,uuid) to authenticated;

create table if not exists public.ai_conversations (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  mode text not null check (mode in ('organizer','player')),
  community_id uuid references public.communities(id) on delete cascade,
  event_id uuid references public.events(id) on delete cascade,
  title text not null default 'New conversation' check (char_length(title) between 1 and 120),
  status text not null default 'active' check (status in ('active','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_conversation_scope_check check (mode = 'player' or community_id is not null or event_id is not null)
);
create index if not exists ai_conversations_owner_updated_idx on public.ai_conversations(owner_user_id, updated_at desc);
create index if not exists ai_conversations_event_idx on public.ai_conversations(event_id) where event_id is not null;
create index if not exists ai_conversations_community_idx on public.ai_conversations(community_id) where community_id is not null;

create table if not exists public.ai_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  role text not null check (role in ('user','assistant','tool','system')),
  content text not null check (char_length(content) <= 20000),
  metadata jsonb not null default '{}'::jsonb,
  input_tokens integer check (input_tokens is null or input_tokens >= 0),
  output_tokens integer check (output_tokens is null or output_tokens >= 0),
  created_at timestamptz not null default now()
);
create index if not exists ai_messages_conversation_created_idx on public.ai_messages(conversation_id, created_at);

create table if not exists public.ai_documents (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  community_id uuid references public.communities(id) on delete cascade,
  event_id uuid references public.events(id) on delete cascade,
  storage_path text not null unique,
  original_filename text not null,
  content_type text not null,
  file_size bigint not null check (file_size > 0 and file_size <= 26214400),
  sha256 text,
  processing_status text not null default 'uploaded' check (processing_status in ('uploaded','queued','processing','ready','failed','deleted')),
  extracted_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ai_document_scope_check check (community_id is not null or event_id is not null)
);
create index if not exists ai_documents_event_idx on public.ai_documents(event_id);
create index if not exists ai_documents_community_idx on public.ai_documents(community_id);

create table if not exists public.ai_proposals (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  action_type text not null check (char_length(action_type) between 1 and 100),
  proposal jsonb not null,
  source_refs jsonb not null default '[]'::jsonb,
  status text not null default 'draft' check (status in ('draft','pending_approval','approved','rejected','executed','failed','expired')),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  executed_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ai_proposals_conversation_idx on public.ai_proposals(conversation_id, created_at desc);

create table if not exists public.ai_runs (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  model text not null,
  status text not null default 'started' check (status in ('started','succeeded','failed','rate_limited')),
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  error_code text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists ai_runs_owner_created_idx on public.ai_runs(owner_user_id, created_at desc);
create index if not exists ai_runs_conversation_idx on public.ai_runs(conversation_id, created_at desc);

create table if not exists public.ai_actions (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.ai_runs(id) on delete cascade,
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  tool_name text not null,
  arguments jsonb not null default '{}'::jsonb,
  result jsonb,
  status text not null default 'proposed' check (status in ('proposed','awaiting_approval','approved','rejected','executing','succeeded','failed')),
  requires_approval boolean not null default true,
  idempotency_key text unique,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists ai_actions_conversation_idx on public.ai_actions(conversation_id, created_at desc);

create table if not exists public.ai_usage_ledger (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid references public.ai_conversations(id) on delete set null,
  run_id uuid references public.ai_runs(id) on delete set null,
  community_id uuid references public.communities(id) on delete set null,
  event_id uuid references public.events(id) on delete set null,
  provider text not null,
  model text not null,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  compute_units numeric(14,4),
  estimated_cost_usd numeric(14,8) not null default 0 check (estimated_cost_usd >= 0),
  created_at timestamptz not null default now()
);
create index if not exists ai_usage_owner_created_idx on public.ai_usage_ledger(owner_user_id, created_at desc);
create index if not exists ai_usage_community_created_idx on public.ai_usage_ledger(community_id, created_at desc);

create table if not exists public.ai_policy (
  community_id uuid primary key references public.communities(id) on delete cascade,
  enabled boolean not null default true,
  daily_neuron_budget numeric(14,2),
  daily_token_budget integer,
  allow_draft_generation boolean not null default true,
  allow_resource_creation boolean not null default false,
  allow_public_announcements boolean not null default false,
  allow_result_auto_publish boolean not null default false,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create or replace function app_private.can_access_ai_conversation(p_conversation_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $function$
  select exists (
    select 1 from public.ai_conversations c
    where c.id = p_conversation_id
      and c.owner_user_id = (select auth.uid())
      and app_private.can_access_ai_scope(c.mode, c.community_id, c.event_id)
  );
$function$;
revoke all on function app_private.can_access_ai_conversation(uuid) from public, anon;
grant execute on function app_private.can_access_ai_conversation(uuid) to authenticated;

alter table public.ai_conversations enable row level security;
alter table public.ai_messages enable row level security;
alter table public.ai_documents enable row level security;
alter table public.ai_proposals enable row level security;
alter table public.ai_runs enable row level security;
alter table public.ai_actions enable row level security;
alter table public.ai_usage_ledger enable row level security;
alter table public.ai_policy enable row level security;

drop policy if exists ai_conversations_select_own_scope on public.ai_conversations;
create policy ai_conversations_select_own_scope on public.ai_conversations for select to authenticated
using (owner_user_id = (select auth.uid()) and app_private.can_access_ai_scope(mode,community_id,event_id));
drop policy if exists ai_conversations_insert_own_scope on public.ai_conversations;
create policy ai_conversations_insert_own_scope on public.ai_conversations for insert to authenticated
with check (owner_user_id = (select auth.uid()) and app_private.can_access_ai_scope(mode,community_id,event_id));
drop policy if exists ai_conversations_update_own_scope on public.ai_conversations;
create policy ai_conversations_update_own_scope on public.ai_conversations for update to authenticated
using (owner_user_id = (select auth.uid()) and app_private.can_access_ai_scope(mode,community_id,event_id))
with check (owner_user_id = (select auth.uid()) and app_private.can_access_ai_scope(mode,community_id,event_id));
drop policy if exists ai_conversations_delete_own on public.ai_conversations;
create policy ai_conversations_delete_own on public.ai_conversations for delete to authenticated
using (owner_user_id = (select auth.uid()));

drop policy if exists ai_messages_select_conversation_scope on public.ai_messages;
create policy ai_messages_select_conversation_scope on public.ai_messages for select to authenticated
using (app_private.can_access_ai_conversation(conversation_id));
drop policy if exists ai_messages_insert_user_only on public.ai_messages;
create policy ai_messages_insert_user_only on public.ai_messages for insert to authenticated
with check (role = 'user' and app_private.can_access_ai_conversation(conversation_id));

drop policy if exists ai_documents_select_scope on public.ai_documents;
create policy ai_documents_select_scope on public.ai_documents for select to authenticated
using (owner_user_id = (select auth.uid()) and app_private.can_access_ai_scope('organizer',community_id,event_id));
drop policy if exists ai_proposals_select_scope on public.ai_proposals;
create policy ai_proposals_select_scope on public.ai_proposals for select to authenticated
using (owner_user_id = (select auth.uid()) and app_private.can_access_ai_conversation(conversation_id));
drop policy if exists ai_runs_select_scope on public.ai_runs;
create policy ai_runs_select_scope on public.ai_runs for select to authenticated
using (owner_user_id = (select auth.uid()) and app_private.can_access_ai_conversation(conversation_id));
drop policy if exists ai_actions_select_scope on public.ai_actions;
create policy ai_actions_select_scope on public.ai_actions for select to authenticated
using (owner_user_id = (select auth.uid()) and app_private.can_access_ai_conversation(conversation_id));
drop policy if exists ai_usage_select_own on public.ai_usage_ledger;
create policy ai_usage_select_own on public.ai_usage_ledger for select to authenticated
using (owner_user_id = (select auth.uid()));
drop policy if exists ai_policy_select_organizer on public.ai_policy;
create policy ai_policy_select_organizer on public.ai_policy for select to authenticated
using (app_private.can_access_ai_scope('organizer',community_id,null));

grant select, insert, update, delete on public.ai_conversations to authenticated;
grant select, insert on public.ai_messages to authenticated;
grant select on public.ai_documents, public.ai_proposals, public.ai_runs, public.ai_actions, public.ai_usage_ledger, public.ai_policy to authenticated;

drop trigger if exists ai_conversations_set_updated_at on public.ai_conversations;
create trigger ai_conversations_set_updated_at before update on public.ai_conversations
for each row execute function app_private.set_updated_at();
drop trigger if exists ai_documents_set_updated_at on public.ai_documents;
create trigger ai_documents_set_updated_at before update on public.ai_documents
for each row execute function app_private.set_updated_at();
drop trigger if exists ai_proposals_set_updated_at on public.ai_proposals;
create trigger ai_proposals_set_updated_at before update on public.ai_proposals
for each row execute function app_private.set_updated_at();
drop trigger if exists ai_policy_set_updated_at on public.ai_policy;
create trigger ai_policy_set_updated_at before update on public.ai_policy
for each row execute function app_private.set_updated_at();

comment on table public.ai_conversations is 'KOMNIVO Organizer AI and Player AI conversations. All rows are owner- and scope-isolated.';
comment on table public.ai_proposals is 'AI-generated action proposals. Proposals do not execute until approved and validated by a separate backend executor.';
comment on table public.ai_actions is 'Audit trail for allowlisted AI tool calls and idempotent execution.';
comment on table public.ai_usage_ledger is 'Per-user/community/event model usage and cost ledger for budget enforcement.';
