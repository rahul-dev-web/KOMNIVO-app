-- Durable FCM delivery attempt ledger contracts.
-- Run with: supabase test db
begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(18);

select extensions.has_table('public','notification_delivery_attempts',
  'FCM delivery attempts are stored in a dedicated table');
select extensions.ok(
  (select relrowsecurity from pg_class where oid='public.notification_delivery_attempts'::regclass),
  'Delivery attempts have RLS enabled'
);
select extensions.ok(
  NOT has_table_privilege('authenticated','public.notification_delivery_attempts','SELECT')
  AND NOT has_table_privilege('authenticated','public.notification_delivery_attempts','INSERT')
  AND NOT has_table_privilege('authenticated','public.notification_delivery_attempts','UPDATE')
  AND NOT has_table_privilege('authenticated','public.notification_delivery_attempts','DELETE'),
  'Authenticated clients cannot inspect or mutate delivery logs'
);
select extensions.ok(
  has_table_privilege('service_role','public.notification_delivery_attempts','SELECT')
  AND has_table_privilege('service_role','public.notification_delivery_attempts','INSERT')
  AND has_table_privilege('service_role','public.notification_delivery_attempts','UPDATE')
  AND has_table_privilege('service_role','public.notification_delivery_attempts','DELETE'),
  'Only the server service role manages delivery attempts'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.notification_delivery_attempts'::regclass
    and conname='notification_delivery_attempts_notification_id_fkey'
    and pg_get_constraintdef(oid) ilike '%notifications(id)%'),
  'Each attempt belongs to an existing notification'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.notification_delivery_attempts'::regclass
    and conname='notification_delivery_attempts_user_id_fkey'
    and pg_get_constraintdef(oid) ilike '%profiles(id)%'),
  'Each attempt is attributed to the notification recipient'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.notification_delivery_attempts'::regclass
    and conname='notification_delivery_attempts_device_token_id_fkey'
    and pg_get_constraintdef(oid) ilike '%device_tokens(id)%'),
  'Each attempt references a registered device row, not a copied token'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.notification_delivery_attempts'::regclass
    and contype='c' and pg_get_constraintdef(oid) ilike '%attempt_number >= 1%' 
    and pg_get_constraintdef(oid) ilike '%attempt_number <= 3%'),
  'The attempt counter is constrained to one through three'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.notification_delivery_attempts'::regclass
    and contype='c' and pg_get_constraintdef(oid) ilike '%accepted%retryable_failure%permanent_failure%'),
  'Attempt status distinguishes accepted, retryable and permanent outcomes'
);
select extensions.ok(
  exists(select 1 from pg_constraint where conrelid='public.notification_delivery_attempts'::regclass
    and contype='u' and pg_get_constraintdef(oid) ilike '%notification_id, device_token_id, attempt_number%'),
  'A notification/device pair cannot duplicate the same attempt number'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='notification_delivery_attempts'
    and indexname='notification_delivery_notification_time_idx'),
  'Notification history can be queried by recent attempt time'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='notification_delivery_attempts'
    and indexname='notification_delivery_user_time_idx'),
  'A recipient can be audited by recent delivery attempts'
);
select extensions.ok(
  NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='notification_delivery_attempts'
      AND column_name='token'
  ),
  'Raw FCM device tokens are never persisted in delivery attempts'
);
select extensions.ok(
  exists(select 1 from information_schema.columns
    where table_schema='public' and table_name='notification_delivery_attempts'
      and column_name='error_code')
  AND exists(select 1 from information_schema.columns
    where table_schema='public' and table_name='notification_delivery_attempts'
      and column_name='http_status'),
  'Failure diagnostics store status/error categories without response bodies'
);
select extensions.ok(
  exists(select 1 from pg_policies where schemaname='public'
    and tablename='notification_delivery_attempts'
    and policyname='notification_delivery_attempts_deny_client'
    and cmd='ALL' and qual='false' and with_check='false'),
  'An explicit RLS deny policy blocks all anonymous and authenticated delivery-log access'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='message_mentions'
    and indexname='message_mentions_notification_id_idx'),
  'Mention notification foreign key has a supporting index'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='message_mentions'
    and indexname='message_mentions_sender_id_idx'),
  'Mention sender foreign key has a supporting index'
);
select extensions.ok(
  exists(select 1 from pg_indexes where schemaname='public'
    and tablename='notification_delivery_attempts'
    and indexname='notification_delivery_attempts_device_token_id_idx'),
  'Delivery device-token foreign key has a supporting index'
);


select * from extensions.finish();
rollback;
