DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'inspector') THEN
        CREATE ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    ELSE
        ALTER ROLE inspector LOGIN PASSWORD 'NetoSQL2025';
    END IF;
END $$;
GRANT ALL PRIVILEGES ON SCHEMA sergeev_food TO inspector;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA sergeev_food TO inspector;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA sergeev_food TO inspector;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA sergeev_food TO inspector;
DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT typname FROM pg_type WHERE typnamespace = 'sergeev_food'::regnamespace AND typtype = 'e' LOOP
        EXECUTE format('GRANT USAGE ON TYPE sergeev_food.%I TO inspector', t.typname);
    END LOOP;
END $$;
GRANT USAGE ON SCHEMA information_schema, pg_catalog, exts TO inspector;
GRANT EXECUTE ON FUNCTION exts.uuid_generate_v4() TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA sergeev_food GRANT ALL ON TABLES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA sergeev_food GRANT ALL ON SEQUENCES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA sergeev_food GRANT EXECUTE ON ROUTINES TO inspector;
ALTER DEFAULT PRIVILEGES IN SCHEMA sergeev_food GRANT USAGE ON TYPES TO inspector;
ALTER ROLE inspector SET search_path = sergeev_food, exts, pg_catalog;
