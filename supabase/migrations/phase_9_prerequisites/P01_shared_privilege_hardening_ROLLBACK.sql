-- ========================================================================
-- P01_shared_privilege_hardening_ROLLBACK.sql
-- Restores exactly the three privileges P01 removed, to "authenticated" only
-- ("anon" held none of them before P01, so nothing is granted to it).
-- NOTE: this re-opens the TRUNCATE exposure; it exists only to prove
-- reversibility.
-- ========================================================================
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."employees"             TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."contracts"             TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "hr"."contract_versions"     TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."asset_assignments" TO "authenticated";
GRANT TRUNCATE, TRIGGER, REFERENCES ON TABLE "assets"."assets"            TO "authenticated";
-- ========================================================================
-- END P01_shared_privilege_hardening_ROLLBACK.sql
-- ========================================================================
