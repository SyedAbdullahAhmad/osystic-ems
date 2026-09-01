-- ===========================================================
-- PHASE 1 - STEP 5
-- Permission-check functions and RLS policies for core RBAC tables
--
-- Verified against Finance's actual, real Phase 3 permission-functions
-- migration (pasted directly into this project's working session) -
-- has_permission()'s signature and logic here matches theirs exactly:
-- core.has_permission(p_user_id uuid, p_permission_code text), NOT the
-- 1-arg placeholder in 001_create_schemas.sql.
-- ===========================================================

CREATE OR REPLACE FUNCTION core.get_user_max_level(p_user_id UUID)
RETURNS INTEGER AS $$
DECLARE
  v_max_level INTEGER := 0;
BEGIN
  SELECT COALESCE(MAX(r.level), 0) INTO v_max_level
  FROM core.user_roles ur
  JOIN core.roles r ON r.id = ur.role_id
  WHERE ur.user_id = p_user_id
    AND ur.is_active = true
    AND (ur.effective_to IS NULL OR ur.effective_to >= CURRENT_DATE);

  RETURN v_max_level;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION core.has_permission(
  p_user_id UUID,
  p_permission_code TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
  v_result BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM core.user_roles ur
    JOIN core.role_permissions rp ON rp.role_id = ur.role_id
    JOIN core.permissions p ON p.id = rp.permission_id
    WHERE ur.user_id = p_user_id
      AND p.code = p_permission_code
      AND ur.is_active = true
      AND (ur.effective_to IS NULL OR ur.effective_to >= CURRENT_DATE)
      AND CURRENT_DATE >= rp.effective_from
      AND (rp.effective_to IS NULL OR rp.effective_to >= CURRENT_DATE)
  ) INTO v_result;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION core.has_permission_with_limit(
  p_user_id UUID,
  p_permission_code TEXT,
  p_amount NUMERIC(18,2)
)
RETURNS BOOLEAN AS $$
DECLARE
  v_result BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM core.user_roles ur
    JOIN core.role_permissions rp ON rp.role_id = ur.role_id
    JOIN core.permissions p ON p.id = rp.permission_id
    WHERE ur.user_id = p_user_id
      AND p.code = p_permission_code
      AND ur.is_active = true
      AND (ur.effective_to IS NULL OR ur.effective_to >= CURRENT_DATE)
      AND CURRENT_DATE >= rp.effective_from
      AND (rp.effective_to IS NULL OR rp.effective_to >= CURRENT_DATE)
      AND (rp.amount_limit IS NULL OR rp.amount_limit >= p_amount)
  ) INTO v_result;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION core.get_data_scope(
  p_user_id UUID,
  p_permission_code TEXT
)
RETURNS TEXT AS $$
DECLARE
  v_scope TEXT := 'NONE';
BEGIN
  SELECT rp.data_scope INTO v_scope
  FROM core.user_roles ur
  JOIN core.role_permissions rp ON rp.role_id = ur.role_id
  JOIN core.permissions p ON p.id = rp.permission_id
  WHERE ur.user_id = p_user_id
    AND p.code = p_permission_code
    AND ur.is_active = true
    AND (ur.effective_to IS NULL OR ur.effective_to >= CURRENT_DATE)
  ORDER BY
    CASE rp.data_scope
      WHEN 'ALL' THEN 1
      WHEN 'DEPARTMENT' THEN 2
      WHEN 'PROJECT' THEN 3
      WHEN 'OWN' THEN 4
      ELSE 5
    END
  LIMIT 1;

  RETURN COALESCE(v_scope, 'NONE');
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION core.get_user_permissions(p_user_id UUID)
RETURNS TABLE (
  code TEXT,
  module TEXT,
  action TEXT,
  data_scope TEXT,
  amount_limit NUMERIC(18,2)
) AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT ON (p.code)
    p.code, p.module, p.action, rp.data_scope, rp.amount_limit
  FROM core.user_roles ur
  JOIN core.role_permissions rp ON rp.role_id = ur.role_id
  JOIN core.permissions p ON p.id = rp.permission_id
  WHERE ur.user_id = p_user_id
    AND ur.is_active = true
    AND (ur.effective_to IS NULL OR ur.effective_to >= CURRENT_DATE)
  ORDER BY p.code,
    CASE rp.data_scope WHEN 'ALL' THEN 1 ELSE 2 END;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- ===========================================================
-- RLS POLICIES
-- ===========================================================
ALTER TABLE core.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.user_roles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "perm_select" ON core.permissions FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "perm_manage" ON core.permissions FOR ALL USING (core.has_permission(auth.uid(), 'ADMIN_CONFIG'));

CREATE POLICY "role_select" ON core.roles FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "role_manage" ON core.roles FOR ALL USING (core.has_permission(auth.uid(), 'ADMIN_USERS'));

CREATE POLICY "rp_select" ON core.role_permissions FOR SELECT USING (core.has_permission(auth.uid(), 'ADMIN_USERS'));
CREATE POLICY "rp_manage" ON core.role_permissions FOR ALL USING (core.has_permission(auth.uid(), 'ADMIN_USERS'));

CREATE POLICY "ur_select" ON core.user_roles FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "ur_manage" ON core.user_roles FOR ALL USING (core.has_permission(auth.uid(), 'ADMIN_USERS'));

DROP TRIGGER IF EXISTS perm_updated_at ON core.permissions;
CREATE TRIGGER perm_updated_at BEFORE UPDATE ON core.permissions FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();
DROP TRIGGER IF EXISTS role_updated_at ON core.roles;
CREATE TRIGGER role_updated_at BEFORE UPDATE ON core.roles FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();
DROP TRIGGER IF EXISTS rp_updated_at ON core.role_permissions;
CREATE TRIGGER rp_updated_at BEFORE UPDATE ON core.role_permissions FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();
DROP TRIGGER IF EXISTS ur_updated_at ON core.user_roles;
CREATE TRIGGER ur_updated_at BEFORE UPDATE ON core.user_roles FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- NOT YET ADDED: audit triggers on these 4 tables (AFTER INSERT OR
-- UPDATE ... EXECUTE FUNCTION audit.trigger_audit_log()), present in
-- Finance's real Phase 3 migration. audit.trigger_audit_log() doesn't
-- exist anywhere in this repo yet (no audit-schema migration has been
-- written) - add it once that function exists, rather than reference
-- something that isn't there yet.
