/* ============================================================================
   TABLE INSPECTOR — DBA daily-use script
   ----------------------------------------------------------------------------
   Shows for a single table:
     1. Table overview
     2. Table & index size summary (MB)
     3. Size breakdown per index
     4. Column definitions (type, length, nullability, identity, defaults)
     5. Index definitions (key columns, included columns, filters, fill factor)
     6. Primary key / unique constraints
     7. Foreign keys (outgoing - this table references others)
     8. Foreign keys (incoming - other tables reference this one)
     9. Check constraints
    10. Default constraints
    11. Triggers
    12. Statistics (last updated, modification counter)

   USAGE: Set @DatabaseName / @SchemaName / @TableName below, then execute
   the whole script. Works against any database on the instance without
   needing to manually switch context in SSMS first.
   Requires SQL Server 2012+ (uses sys.dm_db_stats_properties).
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @DatabaseName SYSNAME = N'EF_TEST';
DECLARE @SchemaName   SYSNAME = N'dbo';
DECLARE @TableName    SYSNAME = N'BD_TABLE';

IF DB_ID(@DatabaseName) IS NULL
BEGIN
    RAISERROR(N'Database %s not found.', 16, 1, @DatabaseName);
    RETURN;
END

DECLARE @sql NVARCHAR(MAX) = N'
USE ' + QUOTENAME(@DatabaseName) + N';

DECLARE @SchemaName SYSNAME = ' + QUOTENAME(@SchemaName, '''') + N';
DECLARE @TableName  SYSNAME = ' + QUOTENAME(@TableName, '''') + N';
DECLARE @FullName NVARCHAR(261) = QUOTENAME(@SchemaName) + N''.'' + QUOTENAME(@TableName);
DECLARE @ObjectId INT = OBJECT_ID(@FullName);

IF @ObjectId IS NULL
BEGIN
    RAISERROR(N''Table %s not found in database ' + @DatabaseName + N'.'', 16, 1, @FullName);
    RETURN;
END

------------------------------------------------------------------------------
-- 1. TABLE OVERVIEW
------------------------------------------------------------------------------
PRINT ''=== 1. TABLE OVERVIEW ==='';
SELECT
    s.name              AS SchemaName,
    t.name              AS TableName,
    t.object_id,
    t.create_date,
    t.modify_date,
    p.rows              AS ApproxRowCount
FROM sys.tables t
JOIN sys.schemas s    ON s.schema_id = t.schema_id
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.object_id = @ObjectId;

------------------------------------------------------------------------------
-- 2. TABLE & INDEX SIZE SUMMARY
------------------------------------------------------------------------------
PRINT ''=== 2. TABLE / INDEX SIZE SUMMARY (MB) ==='';
SELECT
    OBJECT_SCHEMA_NAME(t.object_id)                                     AS SchemaName,
    t.name                                                              AS TableName,
    SUM(CASE WHEN i.index_id IN (0,1) THEN a.total_pages ELSE 0 END) * 8 / 1024.0 AS DataSpaceMB,
    SUM(CASE WHEN i.index_id > 1     THEN a.total_pages ELSE 0 END) * 8 / 1024.0 AS IndexSpaceMB,
    SUM(a.total_pages) * 8 / 1024.0                                     AS TotalReservedMB,
    SUM(a.used_pages)  * 8 / 1024.0                                     AS TotalUsedMB,
    (SUM(a.total_pages) - SUM(a.used_pages)) * 8 / 1024.0               AS UnusedMB
FROM sys.tables t
JOIN sys.indexes i           ON i.object_id = t.object_id
JOIN sys.partitions p        ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.allocation_units a  ON a.container_id = p.partition_id
WHERE t.object_id = @ObjectId
GROUP BY t.object_id, t.name;

------------------------------------------------------------------------------
-- 3. SIZE PER INDEX
------------------------------------------------------------------------------
PRINT ''=== 3. SIZE PER INDEX (MB) ==='';
SELECT
    i.name                  AS IndexName,
    i.type_desc              AS IndexType,
    i.is_unique,
    i.is_primary_key,
    i.is_unique_constraint,
    p.rows                   AS RowsInIndex,
    SUM(a.total_pages) * 8 / 1024.0 AS ReservedMB,
    SUM(a.used_pages)  * 8 / 1024.0 AS UsedMB
FROM sys.indexes i
JOIN sys.partitions p       ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.allocation_units a ON a.container_id = p.partition_id
WHERE i.object_id = @ObjectId
GROUP BY i.name, i.type_desc, i.is_unique, i.is_primary_key, i.is_unique_constraint, p.rows
ORDER BY ReservedMB DESC;

------------------------------------------------------------------------------
-- 4. COLUMNS
------------------------------------------------------------------------------
PRINT ''=== 4. COLUMNS ==='';
SELECT
    c.column_id,
    c.name                  AS ColumnName,
    ty.name                 AS DataType,
    CASE
        WHEN ty.name IN (''nvarchar'',''nchar'') AND c.max_length = -1 THEN ''MAX''
        WHEN ty.name IN (''nvarchar'',''nchar'')                       THEN CAST(c.max_length/2 AS VARCHAR(10))
        WHEN ty.name IN (''varchar'',''char'',''varbinary'',''binary'') AND c.max_length = -1 THEN ''MAX''
        ELSE CAST(c.max_length AS VARCHAR(10))
    END                      AS MaxLength,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity,
    c.is_computed,
    dc.definition            AS DefaultValue,
    cc.definition            AS ComputedDefinition,
    c.collation_name
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
LEFT JOIN sys.computed_columns cc    ON cc.object_id = c.object_id AND cc.column_id = c.column_id
WHERE c.object_id = @ObjectId
ORDER BY c.column_id;

------------------------------------------------------------------------------
-- 5. INDEX DEFINITIONS (key + included columns, filters, fill factor)
------------------------------------------------------------------------------
PRINT ''=== 5. INDEX DEFINITIONS ==='';
SELECT
    i.name          AS IndexName,
    i.type_desc     AS IndexType,
    i.is_unique,
    i.is_primary_key,
    i.is_unique_constraint,
    i.is_disabled,
    i.fill_factor,
    i.has_filter,
    i.filter_definition,
    STUFF((
        SELECT '', '' + c.name + CASE WHEN ic2.is_descending_key = 1 THEN '' DESC'' ELSE '' ASC'' END
        FROM sys.index_columns ic2
        JOIN sys.columns c ON c.object_id = ic2.object_id AND c.column_id = ic2.column_id
        WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 0
        ORDER BY ic2.key_ordinal
        FOR XML PATH('''')
    ), 1, 2, '''')     AS KeyColumns,
    STUFF((
        SELECT '', '' + c.name
        FROM sys.index_columns ic2
        JOIN sys.columns c ON c.object_id = ic2.object_id AND c.column_id = ic2.column_id
        WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id AND ic2.is_included_column = 1
        FOR XML PATH('''')
    ), 1, 2, '''')     AS IncludedColumns
FROM sys.indexes i
WHERE i.object_id = @ObjectId AND i.type > 0
ORDER BY i.index_id;

------------------------------------------------------------------------------
-- 6. PRIMARY KEY / UNIQUE CONSTRAINTS
------------------------------------------------------------------------------
PRINT ''=== 6. PRIMARY KEY / UNIQUE CONSTRAINTS ==='';
SELECT
    kc.name AS ConstraintName,
    kc.type_desc AS ConstraintType,
    STUFF((
        SELECT '', '' + c.name
        FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
        ORDER BY ic.key_ordinal
        FOR XML PATH('''')
    ), 1, 2, '''') AS Columns
FROM sys.key_constraints kc
WHERE kc.parent_object_id = @ObjectId;

------------------------------------------------------------------------------
-- 7. FOREIGN KEYS (outgoing - this table references others)
------------------------------------------------------------------------------
PRINT ''=== 7. FOREIGN KEYS (outgoing) ==='';
SELECT
    fk.name AS ForeignKeyName,
    OBJECT_NAME(fk.parent_object_id) AS TableName,
    c1.name AS ColumnName,
    OBJECT_NAME(fk.referenced_object_id) AS ReferencedTable,
    c2.name AS ReferencedColumn,
    fk.delete_referential_action_desc AS OnDelete,
    fk.update_referential_action_desc AS OnUpdate,
    fk.is_disabled,
    fk.is_not_trusted
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns c1 ON c1.object_id = fkc.parent_object_id AND c1.column_id = fkc.parent_column_id
JOIN sys.columns c2 ON c2.object_id = fkc.referenced_object_id AND c2.column_id = fkc.referenced_column_id
WHERE fk.parent_object_id = @ObjectId;

------------------------------------------------------------------------------
-- 8. FOREIGN KEYS (incoming - other tables referencing this one)
------------------------------------------------------------------------------
PRINT ''=== 8. FOREIGN KEYS (incoming) ==='';
SELECT
    fk.name AS ForeignKeyName,
    OBJECT_NAME(fk.parent_object_id) AS ChildTable,
    c1.name AS ChildColumn,
    OBJECT_NAME(fk.referenced_object_id) AS ThisTable,
    c2.name AS ThisColumn
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns c1 ON c1.object_id = fkc.parent_object_id AND c1.column_id = fkc.parent_column_id
JOIN sys.columns c2 ON c2.object_id = fkc.referenced_object_id AND c2.column_id = fkc.referenced_column_id
WHERE fk.referenced_object_id = @ObjectId;

------------------------------------------------------------------------------
-- 9. CHECK CONSTRAINTS
------------------------------------------------------------------------------
PRINT ''=== 9. CHECK CONSTRAINTS ==='';
SELECT
    cc.name AS ConstraintName,
    COL_NAME(cc.parent_object_id, cc.parent_column_id) AS ColumnName,
    cc.definition,
    cc.is_disabled,
    cc.is_not_trusted
FROM sys.check_constraints cc
WHERE cc.parent_object_id = @ObjectId;

------------------------------------------------------------------------------
-- 10. DEFAULT CONSTRAINTS
------------------------------------------------------------------------------
PRINT ''=== 10. DEFAULT CONSTRAINTS ==='';
SELECT
    dc.name AS ConstraintName,
    COL_NAME(dc.parent_object_id, dc.parent_column_id) AS ColumnName,
    dc.definition
FROM sys.default_constraints dc
WHERE dc.parent_object_id = @ObjectId;

------------------------------------------------------------------------------
-- 11. TRIGGERS
------------------------------------------------------------------------------
PRINT ''=== 11. TRIGGERS ==='';
SELECT
    tr.name AS TriggerName,
    tr.is_disabled,
    te.type_desc AS EventType
FROM sys.triggers tr
JOIN sys.trigger_events te ON te.object_id = tr.object_id
WHERE tr.parent_id = @ObjectId;

------------------------------------------------------------------------------
-- 12. STATISTICS
------------------------------------------------------------------------------
PRINT ''=== 12. STATISTICS ==='';
SELECT
    st.name AS StatName,
    STATS_DATE(st.object_id, st.stats_id) AS LastUpdated,
    sp.rows,
    sp.rows_sampled,
    sp.modification_counter
FROM sys.stats st
CROSS APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) sp
WHERE st.object_id = @ObjectId;
';

EXEC sp_executesql @sql;
