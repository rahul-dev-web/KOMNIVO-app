-- Private AI document storage, version metadata, and text chunks for source-linked retrieval.
alter table public.ai_documents
  add column if not exists visibility text not null default 'organizer_only'
  check (visibility in ('organizer_only','participants','public'));

create table if not exists public.ai_document_chunks (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.ai_documents(id) on delete cascade,
  chunk_index integer not null check (chunk_index >= 0),
  source_ref text not null default '',
  content text not null check (char_length(content) between 1 and 12000),
  metadata jsonb not null default '{}'::jsonb,
  search_vector tsvector generated always as (to_tsvector('simple', coalesce(content, ''))) stored,
  created_at timestamptz not null default now(),
  unique (document_id, chunk_index)
);
create index if not exists ai_document_chunks_document_idx on public.ai_document_chunks(document_id, chunk_index);
create index if not exists ai_document_chunks_search_idx on public.ai_document_chunks using gin(search_vector);

alter table public.ai_document_chunks enable row level security;

drop policy if exists ai_documents_insert_organizer on public.ai_documents;
create policy ai_documents_insert_organizer on public.ai_documents
for insert to authenticated
with check (
  owner_user_id = (select auth.uid())
  and app_private.can_access_ai_scope('organizer', community_id, event_id)
);

drop policy if exists ai_documents_select_scope on public.ai_documents;
create policy ai_documents_select_scope on public.ai_documents
for select to authenticated
using (
  owner_user_id = (select auth.uid())
  or app_private.can_access_ai_scope('organizer', community_id, event_id)
);

drop policy if exists ai_document_chunks_select_scope on public.ai_document_chunks;
create policy ai_document_chunks_select_scope on public.ai_document_chunks
for select to authenticated
using (
  exists (
    select 1 from public.ai_documents d
    where d.id = document_id
      and (
        d.owner_user_id = (select auth.uid())
        or app_private.can_access_ai_scope('organizer', d.community_id, d.event_id)
      )
  )
);

grant select, insert on public.ai_documents to authenticated;
grant select on public.ai_document_chunks to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'ai-documents','ai-documents',false,26214400,
  array[
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-excel',
    'text/csv','text/plain','text/markdown',
    'image/png','image/jpeg','image/webp'
  ]
)
on conflict (id) do update
set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists ai_documents_storage_insert_owner on storage.objects;
create policy ai_documents_storage_insert_owner on storage.objects
for insert to authenticated
with check (bucket_id = 'ai-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists ai_documents_storage_select_owner on storage.objects;
create policy ai_documents_storage_select_owner on storage.objects
for select to authenticated
using (bucket_id = 'ai-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists ai_documents_storage_delete_owner on storage.objects;
create policy ai_documents_storage_delete_owner on storage.objects
for delete to authenticated
using (bucket_id = 'ai-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);

comment on table public.ai_document_chunks is 'Extracted text chunks with source/page/sheet provenance.';
comment on column public.ai_documents.visibility is 'organizer_only = staff; participants = event participants; public = public event/community context.';
