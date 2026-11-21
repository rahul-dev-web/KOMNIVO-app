-- A previously accepted candidate that is reopened by a new conflict
-- must not retain stale reviewer-approved values.
CREATE OR REPLACE FUNCTION app_private.clear_unaccepted_liveops_candidate_values()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $function$
BEGIN
  IF NEW.review_status IS DISTINCT FROM 'accepted' THEN
    NEW.reviewed_placement := NULL;
    NEW.reviewed_kills := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.clear_unaccepted_liveops_candidate_values() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION app_private.clear_unaccepted_liveops_candidate_values() TO service_role;

DROP TRIGGER IF EXISTS result_candidates_clear_unaccepted_review_values
  ON public.result_candidates;
CREATE TRIGGER result_candidates_clear_unaccepted_review_values
  BEFORE INSERT OR UPDATE OF review_status,reviewed_placement,reviewed_kills
  ON public.result_candidates
  FOR EACH ROW
  EXECUTE FUNCTION app_private.clear_unaccepted_liveops_candidate_values();
