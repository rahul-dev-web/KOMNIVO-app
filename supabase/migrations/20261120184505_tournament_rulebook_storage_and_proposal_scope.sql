-- Store a private copy of official source PDFs and constrain proposal banner ownership.
ALTER TABLE public.tournament_rulebooks
  ADD COLUMN IF NOT EXISTS file_size_bytes bigint,
  ADD COLUMN IF NOT EXISTS downloaded_at timestamptz,
  ADD COLUMN IF NOT EXISTS download_error text;

ALTER TABLE public.tournament_proposals
  DROP CONSTRAINT IF EXISTS tournament_proposals_banner_scope_check;
ALTER TABLE public.tournament_proposals
  ADD CONSTRAINT tournament_proposals_banner_scope_check
  CHECK (
    NULLIF(payload->>'banner_path','') IS NULL
    OR (payload->>'banner_path') LIKE community_id::text || '/' || owner_user_id::text || '/%'
  );

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('tournament-rulebooks','tournament-rulebooks',false,26214400,ARRAY['application/pdf']::text[])
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = 26214400,
  allowed_mime_types = ARRAY['application/pdf']::text[];

COMMENT ON COLUMN public.tournament_rulebooks.storage_path IS
  'Private Storage object populated by the authenticated server-side official-source sync on first organiser access.';
COMMENT ON COLUMN public.tournament_rulebooks.scope IS
  'general means a verified general rulebook; competition_specific must be labelled and never assumed universal.';
