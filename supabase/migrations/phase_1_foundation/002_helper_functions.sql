-- ===========================================================
-- PHASE 1 - STEP 3
-- Shared Helper Functions
-- ===========================================================

-- ===========================================================
-- Automatically update updated_at
-- ===========================================================

CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- ===========================================================
-- Current authenticated user
-- ===========================================================

CREATE OR REPLACE FUNCTION core.current_user_id()
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
BEGIN
    RETURN auth.uid();
END;
$$;

-- ===========================================================
-- Current timestamp helper
-- ===========================================================

CREATE OR REPLACE FUNCTION core.current_timestamp_utc()
RETURNS timestamptz
LANGUAGE sql
STABLE
AS $$
SELECT NOW();
$$;

-- ===========================================================
-- Generate UUID helper
-- ===========================================================

CREATE OR REPLACE FUNCTION core.generate_uuid()
RETURNS UUID
LANGUAGE sql
AS $$
SELECT gen_random_uuid();
$$;