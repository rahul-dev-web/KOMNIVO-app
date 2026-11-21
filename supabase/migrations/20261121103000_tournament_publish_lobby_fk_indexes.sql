-- Cover foreign-key access paths introduced by tournament publication and Lobby identity.
CREATE INDEX IF NOT EXISTS event_publications_community_idx
  ON public.event_publications(community_id);
CREATE INDEX IF NOT EXISTS event_publications_category_idx
  ON public.event_publications(category_id);
CREATE INDEX IF NOT EXISTS liveops_sessions_lobby_idx
  ON public.liveops_sessions(lobby_id)
  WHERE lobby_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS event_lobbies_created_by_idx
  ON public.event_lobbies(created_by);
CREATE INDEX IF NOT EXISTS event_lobby_matches_created_by_idx
  ON public.event_lobby_matches(created_by);
