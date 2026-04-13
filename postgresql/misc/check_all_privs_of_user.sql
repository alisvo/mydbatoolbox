WITH RECURSIVE target AS (
  -- SADECE BURAYI DEĞİŞTİR: Analiz etmek istediğin rolün adı
  SELECT 'test_user'::text AS target_role
),
role_tree AS (
  -- 1. Hedef rol ve kalıtım yoluyla sahip olduğu tüm roller
  SELECT oid AS roleid, rolname FROM pg_roles WHERE rolname = (SELECT target_role FROM target)
  UNION ALL
  SELECT m.roleid, pr.rolname FROM pg_auth_members m JOIN pg_roles pr ON pr.oid = m.roleid JOIN role_tree rt ON rt.roleid = m.member
),
all_target_roles AS (
  -- 2. Hedef rol ağacı ve PUBLIC grubu
  SELECT roleid, rolname FROM role_tree
  UNION ALL
  SELECT 0::oid, 'PUBLIC'::name
),
relkind_mapping(relkind, type) AS (
  VALUES ('r', 'table'), ('v', 'view'), ('m', 'materialized view'), ('p', 'partitioned table'), ('S', 'sequence')
),
prokind_mapping(prokind, type) AS (
  VALUES ('f', 'function'), ('p', 'procedure')
)

-- =========================================================================
-- A. CLUSTER & ROL YETKİLERİ
-- =========================================================================
SELECT 
  'Cluster' AS level, 'instance_privilege' AS object_type, NULL AS object_name, 
  unnest(
    CASE WHEN r.rolcanlogin THEN ARRAY['LOGIN'] ELSE ARRAY[]::text[] END
    || CASE WHEN r.rolsuper THEN ARRAY['SUPERUSER'] ELSE ARRAY[]::text[] END
    || CASE WHEN r.rolcreaterole THEN ARRAY['CREATE ROLE'] ELSE ARRAY[]::text[] END
    || CASE WHEN r.rolcreatedb THEN ARRAY['CREATE DATABASE'] ELSE ARRAY[]::text[] END
  ) AS privilege_type,
  r.rolname AS via_role
FROM pg_roles r WHERE r.oid IN (SELECT roleid FROM role_tree)

UNION ALL

SELECT 'Cluster' AS level, 'role_membership' AS object_type, pr.rolname AS object_name, 'MEMBER' AS privilege_type, rt.rolname AS via_role
FROM pg_auth_members m JOIN pg_roles pr ON pr.oid = m.roleid JOIN role_tree rt ON rt.roleid = m.member

UNION ALL

-- =========================================================================
-- B. VERİTABANI YETKİLERİ (Bağlantı, Oluşturma)
-- =========================================================================
SELECT 'Database' AS level, 'database' AS object_type, datname AS object_name, 'OWNER' AS privilege_type, rt.rolname AS via_role 
FROM pg_database d JOIN role_tree rt ON d.datdba = rt.roleid
UNION ALL
SELECT 'Database' AS level, 'database' AS object_type, d.datname AS object_name, acl.privilege_type, tr.rolname AS via_role 
FROM pg_database d CROSS JOIN aclexplode(COALESCE(d.datacl, acldefault('d', d.datdba))) acl JOIN all_target_roles tr ON acl.grantee = tr.roleid

UNION ALL

-- =========================================================================
-- C. ŞEMA YETKİLERİ (Sistem şemaları hariç)
-- =========================================================================
SELECT 'Schema' AS level, 'schema' AS object_type, nspname AS object_name, 'OWNER' AS privilege_type, rt.rolname AS via_role 
FROM pg_namespace n JOIN role_tree rt ON n.nspowner = rt.roleid 
WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname != 'information_schema'
UNION ALL
SELECT 'Schema' AS level, 'schema' AS object_type, n.nspname AS object_name, acl.privilege_type, tr.rolname AS via_role 
FROM pg_namespace n CROSS JOIN aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) acl JOIN all_target_roles tr ON acl.grantee = tr.roleid 
WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname != 'information_schema'

UNION ALL

-- =========================================================================
-- D. TABLO, VIEW VE SEQUENCE YETKİLERİ (Sistem objeleri hariç)
-- =========================================================================
SELECT 'Object' AS level, rk.type AS object_type, n.nspname || '.' || c.relname AS object_name, 'OWNER' AS privilege_type, rt.rolname AS via_role 
FROM pg_class c JOIN role_tree rt ON c.relowner = rt.roleid JOIN relkind_mapping rk ON rk.relkind = c.relkind JOIN pg_namespace n ON n.oid = c.relnamespace 
WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname != 'information_schema'
UNION ALL
SELECT 'Object' AS level, rk.type AS object_type, n.nspname || '.' || c.relname AS object_name, acl.privilege_type, tr.rolname AS via_role 
FROM pg_class c CROSS JOIN aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) acl JOIN all_target_roles tr ON acl.grantee = tr.roleid JOIN relkind_mapping rk ON rk.relkind = c.relkind JOIN pg_namespace n ON n.oid = c.relnamespace 
WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname != 'information_schema'

UNION ALL

-- =========================================================================
-- E. FONKSİYON VE PROSEDÜR YETKİLERİ (Sistem objeleri hariç)
-- =========================================================================
SELECT 'Object' AS level, pk.type AS object_type, n.nspname || '.' || p.proname AS object_name, 'OWNER' AS privilege_type, rt.rolname AS via_role 
FROM pg_proc p JOIN role_tree rt ON p.proowner = rt.roleid JOIN prokind_mapping pk ON pk.prokind = p.prokind JOIN pg_namespace n ON n.oid = p.pronamespace 
WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname != 'information_schema'
UNION ALL
SELECT 'Object' AS level, pk.type AS object_type, n.nspname || '.' || p.proname AS object_name, acl.privilege_type, tr.rolname AS via_role 
FROM pg_proc p CROSS JOIN aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) acl JOIN all_target_roles tr ON acl.grantee = tr.roleid JOIN prokind_mapping pk ON pk.prokind = p.prokind JOIN pg_namespace n ON n.oid = p.pronamespace 
WHERE n.nspname NOT LIKE 'pg_%' AND n.nspname != 'information_schema'

UNION ALL

-- =========================================================================
-- F. VARSAYILAN YETKİLER (Gelecekte oluşturulacak tablolar vb. için)
-- =========================================================================
SELECT 
  'Default_ACL' AS level, 
  CASE dacl.defaclobjtype WHEN 'r' THEN 'table' WHEN 'S' THEN 'sequence' WHEN 'f' THEN 'function' WHEN 'n' THEN 'schema' ELSE dacl.defaclobjtype::text END AS object_type,
  COALESCE(n.nspname, 'Global (Tüm Şemalar)') AS object_name,
  acl.privilege_type, tr.rolname AS via_role
FROM pg_default_acl dacl
LEFT JOIN pg_namespace n ON n.oid = dacl.defaclnamespace
CROSS JOIN aclexplode(dacl.defaclacl) acl
JOIN all_target_roles tr ON acl.grantee = tr.roleid
WHERE (n.nspname IS NULL OR (n.nspname NOT LIKE 'pg_%' AND n.nspname != 'information_schema'));
