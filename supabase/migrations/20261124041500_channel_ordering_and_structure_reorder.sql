ALTER TABLE public.channels
  ADD COLUMN IF NOT EXISTS position integer;

WITH ranked AS (
  SELECT
    id,
    row_number() OVER (
      PARTITION BY community_id, event_id, category_id, stage_id, group_id, match_id
      ORDER BY
        CASE lower(name)
          WHEN 'info' THEN 0
          WHEN 'updates' THEN 10
          WHEN 'roadmap' THEN 20
          WHEN 'schedule' THEN 30
          WHEN 'results' THEN 40
          WHEN 'registration' THEN 50
          WHEN 'test-registration' THEN 60
          WHEN 'registration-confirmation' THEN 70
          WHEN 'help-desk' THEN 80
          WHEN 'help-desk-voice' THEN 90
          WHEN 'staff' THEN 100
          ELSE 1000
        END,
        created_at,
        lower(name),
        id
    ) - 1 AS next_position
  FROM public.channels
)
UPDATE public.channels AS channel
SET position = ranked.next_position
FROM ranked
WHERE ranked.id = channel.id;

ALTER TABLE public.channels
  ALTER COLUMN position SET NOT NULL;

CREATE INDEX IF NOT EXISTS channels_structure_order_idx
  ON public.channels (community_id, event_id, category_id, position, created_at)
  WHERE archived_at IS NULL;

CREATE OR REPLACE FUNCTION app_private.set_channel_structure_position()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_next_position integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.position IS NOT NULL THEN
      RETURN NEW;
    END IF;
  ELSIF NEW.category_id IS DISTINCT FROM OLD.category_id THEN
    IF NEW.position IS DISTINCT FROM OLD.position THEN
      RETURN NEW;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  SELECT coalesce(max(channel.position), -1) + 1
    INTO v_next_position
  FROM public.channels AS channel
  WHERE channel.community_id IS NOT DISTINCT FROM NEW.community_id
    AND channel.event_id IS NOT DISTINCT FROM NEW.event_id
    AND channel.category_id IS NOT DISTINCT FROM NEW.category_id
    AND channel.stage_id IS NOT DISTINCT FROM NEW.stage_id
    AND channel.group_id IS NOT DISTINCT FROM NEW.group_id
    AND channel.match_id IS NOT DISTINCT FROM NEW.match_id
    AND channel.archived_at IS NULL
    AND (TG_OP = 'INSERT' OR channel.id <> NEW.id);

  NEW.position := v_next_position;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION app_private.set_channel_structure_position() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS channels_set_structure_position ON public.channels;
CREATE TRIGGER channels_set_structure_position
BEFORE INSERT OR UPDATE OF category_id ON public.channels
FOR EACH ROW
EXECUTE FUNCTION app_private.set_channel_structure_position();

CREATE OR REPLACE FUNCTION public.reorder_community_channels(p_channel_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
  v_first public.channels%rowtype;
  v_visible_count integer;
  v_requested_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING errcode = '42501';
  END IF;

  IF p_channel_ids IS NULL
     OR cardinality(p_channel_ids) < 1
     OR cardinality(p_channel_ids) > 100 THEN
    RAISE EXCEPTION 'Choose between 1 and 100 channels to reorder';
  END IF;

  SELECT count(DISTINCT requested.channel_id)
    INTO v_requested_count
  FROM unnest(p_channel_ids) AS requested(channel_id);

  IF v_requested_count <> cardinality(p_channel_ids) THEN
    RAISE EXCEPTION 'A channel can only appear once in an order';
  END IF;

  SELECT channel.*
    INTO v_first
  FROM public.channels AS channel
  WHERE channel.id = p_channel_ids[1]
    AND channel.archived_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'The channel is unavailable or you cannot view it';
  END IF;

  IF v_first.event_id IS NOT NULL THEN
    IF NOT (
      app_private.resolve_permission('event.manage', 'event', v_first.event_id, NULL, NULL)
      OR app_private.resolve_permission('event.matches.operate', 'event', v_first.event_id, NULL, NULL)
    ) THEN
      RAISE EXCEPTION 'You cannot reorder these event channels' USING errcode = '42501';
    END IF;
  ELSIF v_first.community_id IS NOT NULL THEN
    IF NOT app_private.resolve_permission('community.manage_structure', 'community', v_first.community_id, NULL, NULL) THEN
      RAISE EXCEPTION 'You cannot reorder community channels' USING errcode = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'This channel does not belong to a reorderable community';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_channel_ids) AS requested(channel_id)
    LEFT JOIN public.channels AS channel ON channel.id = requested.channel_id
    WHERE channel.id IS NULL
       OR channel.archived_at IS NOT NULL
       OR channel.community_id IS DISTINCT FROM v_first.community_id
       OR channel.event_id IS DISTINCT FROM v_first.event_id
       OR channel.category_id IS DISTINCT FROM v_first.category_id
       OR channel.stage_id IS DISTINCT FROM v_first.stage_id
       OR channel.group_id IS DISTINCT FROM v_first.group_id
       OR channel.match_id IS DISTINCT FROM v_first.match_id
  ) THEN
    RAISE EXCEPTION 'All channels must belong to the same active category and scope';
  END IF;

  SELECT count(*)
    INTO v_visible_count
  FROM public.channels AS channel
  WHERE channel.archived_at IS NULL
    AND channel.community_id IS NOT DISTINCT FROM v_first.community_id
    AND channel.event_id IS NOT DISTINCT FROM v_first.event_id
    AND channel.category_id IS NOT DISTINCT FROM v_first.category_id
    AND channel.stage_id IS NOT DISTINCT FROM v_first.stage_id
    AND channel.group_id IS NOT DISTINCT FROM v_first.group_id
    AND channel.match_id IS NOT DISTINCT FROM v_first.match_id;

  IF v_visible_count <> cardinality(p_channel_ids) THEN
    RAISE EXCEPTION 'Refresh the channel list before saving its order';
  END IF;

  UPDATE public.channels AS channel
  SET position = requested.ordinality::integer - 1
  FROM unnest(p_channel_ids) WITH ORDINALITY AS requested(channel_id, ordinality)
  WHERE channel.id = requested.channel_id
    AND channel.archived_at IS NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.reorder_community_channels(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reorder_community_channels(uuid[]) TO authenticated;
