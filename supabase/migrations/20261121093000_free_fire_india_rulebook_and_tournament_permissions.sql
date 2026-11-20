-- Add Free Fire India as a distinct game and seed the cleaned curated rulebook.
INSERT INTO public.games (code, name, publisher, platform, is_active)
VALUES ('free_fire_india', 'Free Fire India', 'Garena', 'android', true)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  publisher = EXCLUDED.publisher,
  platform = EXCLUDED.platform,
  is_active = true;

INSERT INTO public.tournament_rulebooks (
  game_id, title, version, region, mode_scope, scope, source_title, source_url,
  rules_config, scoring_config, notes, effective_date, is_active
)
SELECT
  g.id,
  'Free Fire India Rulebook',
  'KOMNIVO 1.0 | 21 Nov 2026',
  'IN',
  ARRAY['squad']::text[],
  'general',
  'Free Fire at 2026 Esports World Cup - Game Rulebook (user-supplied source; curated sections)',
  'https://drive.google.com/file/d/1JJG27CKPvGDh-azyqxFpDzuL0QM0bLuB/view?usp=drive_link',
  jsonb_build_object(
    'document_type', 'komnivo_curated_baseline',
    'not_garena_issued', true,
    'intended_mode', 'squad',
    'game_settings', jsonb_build_object(
      'game_mode', 'Esports',
      'gun_property_weapon_stats', 'Off',
      'revival', 'On',
      'hide_nickname_and_kill_feed', 'On',
      'generic_enemy_outfit', 'On',
      'high_tier_loot_zone', 'Off',
      'death_cam', 'On',
      'in_game_missions', 'On',
      'in_game_quests', 'Off',
      'safe_zone_moving', 'On',
      'loadouts', 'Allowed'
    ),
    'map_pool', jsonb_build_array('Bermuda','Purgatory','Kalahari','NexTerra','Solara'),
    'map_pool_version_sensitive', true,
    'map_rotation', jsonb_build_object(
      'method', 'random_order_without_repeats_per_full_cycle',
      'cycle_size', 5,
      'organiser_must_publish_before_event', true,
      'reseed_after_full_cycle', true,
      'source_note', 'Genericised from supplied source section 5.1.1. EWC Group Stage, Survival Stage, Finals, fixed dates, fixed match counts and event administration timings removed.'
    ),
    'source_sections', ARRAY['5.1','5.1.1','5.4','5.5'],
    'source_pages', ARRAY[16,17,21,22],
    'excluded_ewc_content', jsonb_build_array(
      'participant eligibility, age and roster rules',
      'regional residency, qualification and seeding',
      'EWC group stage, survival stage, finals and Match Point format',
      'fixed schedules, dates, match counts and event-specific administration',
      'character/pet whitelists and EWC-specific restricted skins',
      'disciplinary/administrative penalties, staff and travel',
      'EWC prize distribution, equipment, venue and privacy clauses'
    )
  ),
  jsonb_build_object(
    'scheme', 'kills_plus_placement',
    'kill_point', 1,
    'placement_points', jsonb_build_object(
      '1',12,'2',9,'3',8,'4',7,'5',6,'6',5,
      '7',4,'8',3,'9',2,'10',1,'11',0,'12',0
    ),
    'tiebreakers', jsonb_build_array(
      'total_booyahs_in_configured_phase',
      'total_kills_in_configured_phase',
      'latest_common_match_placement'
    ),
    'tiebreaker_period_requires_organiser_definition', true,
    'source_note', 'Values adapted from supplied source sections 5.4 and 5.5. EWC branding removed; organiser must publish the calculation period and verify the current game/event rules.'
  ),
  'KOMNIVO-curated organiser baseline prepared from the user-supplied EWC 2026 Free Fire game rulebook. Only reusable game settings, map pool, generic map rotation, scoring and tie-break mechanics are retained. This is not an official Garena publication or endorsement. Map pool and game settings are patch-sensitive and must be confirmed before every event.',
  DATE '2026-11-21',
  true
FROM public.games g
WHERE g.code = 'free_fire_india'
ON CONFLICT (game_id, title, version) DO UPDATE SET
  source_title = EXCLUDED.source_title,
  source_url = EXCLUDED.source_url,
  rules_config = EXCLUDED.rules_config,
  scoring_config = EXCLUDED.scoring_config,
  notes = EXCLUDED.notes,
  effective_date = EXCLUDED.effective_date,
  source_checked_at = now(),
  is_active = true;

DROP POLICY IF EXISTS tournament_banners_upload_manager ON storage.objects;
CREATE POLICY tournament_banners_upload_manager
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'tournament-banners'
    AND (storage.foldername(name))[2] = (SELECT auth.uid()::text)
    AND app_private.can_access_ai_scope('organizer', ((storage.foldername(name))[1])::uuid, NULL)
  );

DROP POLICY IF EXISTS tournament_banners_read_manager ON storage.objects;
CREATE POLICY tournament_banners_read_manager
  ON storage.objects FOR SELECT TO authenticated
  USING (
    bucket_id = 'tournament-banners'
    AND (storage.foldername(name))[2] = (SELECT auth.uid()::text)
    AND app_private.can_access_ai_scope('organizer', ((storage.foldername(name))[1])::uuid, NULL)
  );

DO $migration$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.resolve_tournament_proposal(uuid,uuid,text)'::regprocedure
  ) INTO v_definition;
  IF position('v_community_id := v_proposal.community_id;' in v_definition) = 0 THEN
    v_definition := replace(
      v_definition,
      'v_payload := v_proposal.payload;',
      'v_payload := v_proposal.payload;' || chr(10) || '  v_community_id := v_proposal.community_id;'
    );
    EXECUTE v_definition;
  END IF;
END
$migration$;
