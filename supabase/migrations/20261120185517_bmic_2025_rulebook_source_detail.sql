-- Preserve the exact BMIC 2025 match map sequence from the official KRAFTON PDF.
UPDATE public.tournament_rulebooks rb
SET rules_config = jsonb_set(
  COALESCE(rb.rules_config,'{}'::jsonb),
  '{competition_format,map_sequence}',
  '["Rondo","Erangel","Erangel","Erangel","Miramar","Miramar"]'::jsonb,
  true
),
source_checked_at = now()
FROM public.games g
WHERE g.id = rb.game_id
  AND g.code = 'bgmi'
  AND rb.title LIKE 'BATTLEGROUNDS MOBILE INDIA International Cup 2025%';
