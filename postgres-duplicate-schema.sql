-- Create the new schema
CREATE SCHEMA targetschema;
CREATE OR REPLACE FUNCTION duplicate_schema(
    source_schema TEXT,
    dest_schema TEXT,
    drop_if_exists BOOLEAN DEFAULT FALSE
) RETURNS VOID AS $$
DECLARE
    object record;
    seq_info record;
    seq_params record;
BEGIN
    IF drop_if_exists AND EXISTS(
        SELECT 1 FROM information_schema.schemata WHERE schema_name = dest_schema
    ) THEN
        EXECUTE format('DROP SCHEMA %I CASCADE', dest_schema);
    END IF;
    
    -- Create the new schema
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', dest_schema);
    
    -- Copy sequences first (to avoid issues with serial columns)
    FOR object IN 
        SELECT sequence_name::text 
        FROM information_schema.sequences 
        WHERE sequence_schema = source_schema
    LOOP
        -- Get all sequence parameters
        EXECUTE format(
            'SELECT 
                last_value, 
                is_called,
                increment_by, 
                max_value, 
                min_value, 
                cache_size, 
                cycle
            FROM %I.%I', 
            source_schema, object.sequence_name
        ) INTO seq_params;
        
        -- Create sequence with all the same parameters
        EXECUTE format(
            'CREATE SEQUENCE %I.%I 
            INCREMENT BY %s 
            MINVALUE %s 
            MAXVALUE %s 
            START WITH %s 
            %s 
            CACHE %s', 
            dest_schema, 
            object.sequence_name,
            seq_params.increment_by,
            seq_params.min_value,
            seq_params.max_value,
            1, -- Start with 1 initially, we'll set the correct value later
            CASE WHEN seq_params.cycle THEN 'CYCLE' ELSE 'NO CYCLE' END,
            seq_params.cache_size
        );
        
        -- Set the sequence to the correct value
        IF seq_params.is_called THEN
            EXECUTE format('SELECT setval(%L, %s, true)', 
                          dest_schema || '.' || object.sequence_name, seq_params.last_value);
        ELSE
            EXECUTE format('SELECT setval(%L, %s, false)', 
                          dest_schema || '.' || object.sequence_name, seq_params.last_value);
        END IF;
    END LOOP;
    
    -- Copy tables structure (including sequences associated with columns)
    FOR object IN 
        SELECT table_name::text 
        FROM information_schema.tables 
        WHERE table_schema = source_schema 
        AND table_type = 'BASE TABLE'
    LOOP
        EXECUTE format('CREATE TABLE %I.%I (LIKE %I.%I INCLUDING ALL)', 
                      dest_schema, object.table_name, source_schema, object.table_name);
        
        -- Copy table data
        EXECUTE format('INSERT INTO %I.%I SELECT * FROM %I.%I', 
                      dest_schema, object.table_name, source_schema, object.table_name);
    END LOOP;
    
    -- Fix ownership of sequences attached to serial/identity columns
    FOR object IN
        SELECT 
            a.attname as column_name,
            t.relname as table_name,
            s.relname as sequence_name
        FROM pg_class s
        JOIN pg_depend d ON d.objid = s.oid
        JOIN pg_class t ON d.refobjid = t.oid
        JOIN pg_attribute a ON (d.refobjid, d.refobjsubid) = (a.attrelid, a.attnum)
        JOIN pg_namespace ns ON s.relnamespace = ns.oid
        JOIN pg_namespace nt ON t.relnamespace = nt.oid
        WHERE s.relkind = 'S'
        AND ns.nspname = source_schema
    LOOP
        EXECUTE format('ALTER SEQUENCE %I.%I OWNED BY %I.%I.%I', 
                      dest_schema, object.sequence_name, 
                      dest_schema, object.table_name, object.column_name);
    END LOOP;
    
    -- Copy views
    FOR object IN
        SELECT viewname::text, definition
        FROM pg_views
        WHERE schemaname = source_schema
    LOOP
        -- Replace references to the source schema with dest schema in view definition
        DECLARE
            view_definition TEXT := object.definition;
        BEGIN
            -- Replace schema references in the view definition
            view_definition := regexp_replace(
                view_definition,
                source_schema || '\.',
                dest_schema || '.',
                'g'
            );
            
            EXECUTE format('CREATE OR REPLACE VIEW %I.%I AS %s',
                          dest_schema, object.viewname, view_definition);
        END;
    END LOOP;
    
    -- Copy functions
    FOR object IN
        SELECT proname::text, oid::regprocedure
        FROM pg_proc
        WHERE pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = source_schema)
    LOOP
        -- Get function definition and replace schema references
        DECLARE
            func_def TEXT := pg_get_functiondef(object.oid);
        BEGIN
            func_def := replace(func_def, source_schema || '.', dest_schema || '.');
            func_def := regexp_replace(func_def, 
                            format('FUNCTION %s.', source_schema), 
                            format('FUNCTION %s.', dest_schema), 
                            'g');
            EXECUTE func_def;
        END;
    END LOOP;
    
    -- Copy triggers
    FOR object IN
        SELECT 
            tgname::text as trigger_name,
            relname::text as table_name,
            pg_get_triggerdef(t.oid) as definition
        FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE n.nspname = source_schema
        AND NOT t.tgisinternal
    LOOP
        DECLARE
            trigger_def TEXT := object.definition;
        BEGIN
            -- Replace schema references in trigger definition
            trigger_def := regexp_replace(
                trigger_def,
                'ON ' || source_schema || '\.',
                'ON ' || dest_schema || '.',
                'g'
            );
            
            -- Replace function references if they're in the same schema
            trigger_def := regexp_replace(
                trigger_def,
                'EXECUTE FUNCTION ' || source_schema || '\.',
                'EXECUTE FUNCTION ' || dest_schema || '.',
                'g'
            );
            
            trigger_def := regexp_replace(
                trigger_def,
                'EXECUTE PROCEDURE ' || source_schema || '\.',
                'EXECUTE PROCEDURE ' || dest_schema || '.',
                'g'
            );
            
            EXECUTE trigger_def;
        END;
    END LOOP;
    
    RAISE NOTICE 'Schema % successfully duplicated to % with all sequences properly migrated', 
                 source_schema, dest_schema;
END;
$$ LANGUAGE plpgsql;

-- Example usage
SELECT duplicate_schema('public', 'targetschema', TRUE);
