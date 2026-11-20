-- Batch 3: Forum is a supported communication channel type in the app
-- and in approved event templates; permit it at the database boundary.
alter table public.channels drop constraint if exists channels_kind_check;
alter table public.channels
  add constraint channels_kind_check
  check (kind = any (array['text','announcement','forum','voice','dm','group','match']::text[]));
