DROP INDEX IF EXISTS public.liveops_captures_match_content_hash_uidx;
CREATE UNIQUE INDEX liveops_captures_match_content_hash_uidx
  ON public.liveops_captures(match_id,content_sha256)
  WHERE content_sha256 IS NOT NULL;
