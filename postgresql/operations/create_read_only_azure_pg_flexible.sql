-- 1. Create the login
CREATE ROLE newuser23
    LOGIN
    PASSWORD 'strongPass@!**09';

-- 2. Read all tables, views and sequences across the server
GRANT pg_read_all_data TO newuser23;

-- 3. Allow connection to all existing user databases
DO $$
DECLARE
    db_record RECORD;
BEGIN
    FOR db_record IN
        SELECT datname
        FROM pg_database
        WHERE datallowconn = true
          AND datistemplate = false
          AND datname NOT IN ('azure_maintenance', 'azure_sys')
    LOOP
        EXECUTE format(
            'GRANT CONNECT ON DATABASE %I TO nes14665',
            db_record.datname
        );
    END LOOP;
END
$$;
