-- Keep Spectator as event-follow/participation state, never as Community or Team authority.
UPDATE public.community_members
SET role='member'
WHERE role='spectator';

ALTER TABLE public.community_members
DROP CONSTRAINT IF EXISTS community_members_role_check;

ALTER TABLE public.community_members
ADD CONSTRAINT community_members_role_check
CHECK (role IN ('owner','admin','moderator','organiser','member'));
