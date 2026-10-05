-- personal-map-coverage — consolidated schema
-- The net effect of supabase/migrations/001_initial.sql + 002_multi_aoi.sql, written as one file.
-- Target: Supabase Postgres (auth.users is provided by Supabase Auth).
-- Every coordinate array is GeoJSON order: [[lon, lat], ...]. There is no PostGIS; geometry lives in JSONB
-- and all spatial work happens in the app (Turf).

-- ─────────────────────────────────────────────────────────────────────────────
-- Areas of interest: SHARED. Any signed-in user can see and analyse any AOI.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS areas_of_interest (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  created_by  UUID REFERENCES auth.users(id) ON DELETE SET NULL,  -- AOI survives its creator leaving
  name        TEXT NOT NULL,
  inclusion   JSONB NOT NULL DEFAULT '[]',   -- one ring [[lon,lat], ...], at least 3 points, NOT closed (app closes it)
  exclusions  JSONB NOT NULL DEFAULT '[]',   -- zero or more rings [[[lon,lat], ...], ...], same convention
  created_at  TIMESTAMPTZ DEFAULT NOW()      -- AOI picker is ordered by this; the first one is selected by default
);

-- ─────────────────────────────────────────────────────────────────────────────
-- OSM path network, cached per AOI (one AOI = one Overpass fetch).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS osm_ways (
  aoi_id      UUID NOT NULL REFERENCES areas_of_interest(id) ON DELETE CASCADE,
  osm_id      BIGINT NOT NULL,               -- OSM way id
  tags        JSONB DEFAULT '{}',            -- raw OSM tags, e.g. {"highway":"footway","name":"Ridge Path"}
  coordinates JSONB NOT NULL DEFAULT '[]',   -- the FULL way (may extend beyond the AOI); clipping is done at analysis time
  cached_at   TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (aoi_id, osm_id)               -- upsert target: onConflict 'aoi_id,osm_id'
);
-- Migration history leaves two leftovers on this table in the real repo:
--   * a vestigial `id UUID DEFAULT gen_random_uuid()` column (it was the PK in 001), and
--   * the 001 constraint `osm_id ... UNIQUE` (osm_ways_osm_id_key), which 002 never dropped.
-- The second one means the same OSM way cannot be cached for two overlapping AOIs. For a rebuild, omit both
-- (as above); on an existing database run:
--   ALTER TABLE osm_ways DROP CONSTRAINT IF EXISTS osm_ways_osm_id_key;
--   ALTER TABLE osm_ways DROP COLUMN IF EXISTS id;

-- ─────────────────────────────────────────────────────────────────────────────
-- Strava OAuth tokens, one row per app user.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS strava_connections (
  user_id        UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  athlete_id     BIGINT NOT NULL,            -- Strava athlete id
  athlete_name   TEXT,                       -- "firstname lastname" from the token exchange
  access_token   TEXT NOT NULL,              -- ~6 h lifetime
  refresh_token  TEXT NOT NULL,              -- rotated on every refresh; always store the new one
  expires_at     TIMESTAMPTZ NOT NULL,       -- refresh when < 60 s remain
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  updated_at     TIMESTAMPTZ DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- GPS activities, PER USER. Only activities with a map polyline of >= 2 points are stored.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS activities (
  id             UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id        UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  strava_id      BIGINT NOT NULL,
  name           TEXT,
  activity_type  TEXT,                       -- Strava `type`: Run | TrailRun | Walk | Hike | Ride | MountainBikeRide | GravelRide
  start_date     TIMESTAMPTZ,                -- Strava start_date (UTC). Drives incremental sync and timeline day buckets
  coordinates    JSONB NOT NULL DEFAULT '[]',-- decoded summary_polyline as [[lon,lat], ...]
  created_at     TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, strava_id)                -- makes re-syncing idempotent (upsert target)
);
CREATE INDEX IF NOT EXISTS idx_activities_user_id    ON activities (user_id);
CREATE INDEX IF NOT EXISTS idx_activities_start_date ON activities (user_id, start_date DESC);  -- "latest cached activity" lookup

-- ─────────────────────────────────────────────────────────────────────────────
-- Timeline cache, PER USER PER AOI. The expensive day-by-day replay is stored as one JSONB blob.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS timeline_cache (
  user_id           UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  aoi_id            UUID NOT NULL REFERENCES areas_of_interest(id) ON DELETE CASCADE,
  data              JSONB NOT NULL,          -- TimelineResult: { ways[], dates[], activitiesByDate{} } (see examples/timeline-cache.json)
  activities_count  INT,                     -- user's activity count at build time; != current count  =>  stale
  built_at          TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (user_id, aoi_id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- Row Level Security
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE areas_of_interest  ENABLE ROW LEVEL SECURITY;
ALTER TABLE osm_ways           ENABLE ROW LEVEL SECURITY;
ALTER TABLE strava_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE activities         ENABLE ROW LEVEL SECURITY;
ALTER TABLE timeline_cache     ENABLE ROW LEVEL SECURITY;

-- Private per-user data: only your own rows, for every operation
-- (FOR ALL with no WITH CHECK reuses USING as the check on INSERT/UPDATE).
CREATE POLICY "own_strava"     ON strava_connections FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "own_activities" ON activities         FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "own_timeline"   ON timeline_cache     FOR ALL USING (auth.uid() = user_id);

-- Shared AOIs: everyone signed in reads; you can only create rows stamped as yours and delete your own.
-- NOTE: there is no UPDATE policy, so the PATCH /api/aoi/:id (edit exclusions) route cannot succeed
-- through the user's client. Add one if exclusions should be editable:
--   CREATE POLICY "update_aoi" ON areas_of_interest FOR UPDATE TO authenticated
--     USING (auth.uid() = created_by) WITH CHECK (auth.uid() = created_by);
CREATE POLICY "read_aoi"   ON areas_of_interest FOR SELECT TO authenticated USING (true);
CREATE POLICY "insert_aoi" ON areas_of_interest FOR INSERT TO authenticated WITH CHECK (auth.uid() = created_by);
CREATE POLICY "delete_aoi" ON areas_of_interest FOR DELETE TO authenticated USING (auth.uid() = created_by);

-- Shared OSM cache: everyone signed in reads; only the server (service-role key) writes.
CREATE POLICY "read_osm"  ON osm_ways FOR SELECT TO authenticated USING (true);
CREATE POLICY "write_osm" ON osm_ways FOR ALL    TO service_role  USING (true);
