/* ============================================================================
   TABLE INSPECTOR — DBA daily-use script (SQL Server 2017+)
   ----------------------------------------------------------------------------
   Shows for a single table:
     1. Table overview
     2. Table & index size summary (MB)
     3. Size breakdown per index
     4. Column definitions
     5. Index definitions
     6. Primary key / unique constraints
     7. Foreign keys (outgoing - this table references others)
     8. Foreign keys (incoming - other tables reference this one)
     9. Check constraints
    10. Default constraints
    11. Triggers
    12. Statistics
    13. Rowstore fragmentation / physical stats + generated maintenance commands
    14. Columnstore row group health + generated maintenance commands, if any
    15. Index usage since last SQL Server service restart / DB attach

   USAGE:
     Set @DatabaseName, @SchemaName, @TableName below, then execute whole script.

   NOTES:
     - The full inspection runs inside a dynamic batch after USE [database], so sys.*
       views and OBJECT_ID() are evaluated in the correct database.
     - Uses STRING_AGG, available in SQL Server 2017+.
     - Some DMV sections may require VIEW DATABASE STATE / VIEW SERVER STATE depending
       on SQL Server version and permissions.
   ============================================================================ */

SET NOCOUNT ON;

DECLARE @DatabaseName SYSNAME = N'EFF_TEST';
DECLARE @SchemaName   SYSNAME = N'dbo';
DECLARE @TableName    SYSNAME = N'EFFArchive';

-- Fragmentation scan mode:
--   LIMITED  = safest/fastest daily check; default recommended.
--   SAMPLED  = more accurate for large indexes, heavier.
--   DETAILED = most accurate, heaviest; avoid on large busy tables unless needed.
DECLARE @FragmentationMode NVARCHAR(20) = N'LIMITED';

-- Maintenance hint ignores fragmentation percentages below this page count.
-- 1000 pages ~= 8 MB. Adjust if your environment uses a different threshold.
DECLARE @MinPageCountForFragmentation INT = 1000;

-- Default practical thresholds commonly used for index maintenance.
-- 5 <= fragmentation < 30  => REORGANIZE
-- fragmentation >= 30      => REBUILD
DECLARE @ReorganizeFragmentationPercent DECIMAL(5,2) = 5.00;
DECLARE @RebuildFragmentationPercent     DECIMAL(5,2) = 30.00;

-- Generated commands only. They are NOT executed by this script.
-- User preference: default generated REBUILD commands include ONLINE = ON.
DECLARE @UseOnlineRebuild BIT = 1;
DECLARE @UseSortInTempdb  BIT = 1;
DECLARE @UseLobCompactionForReorganize BIT = 1;

-- For partitioned indexes, generate partition-level commands instead of whole-index commands.
DECLARE @GeneratePartitionLevelCommands BIT = 1;

-- Columnstore helper threshold for section 14.
DECLARE @ColumnstoreDeletedRowsPercentThreshold DECIMAL(5,2) = 20.00;

IF DB_ID(@DatabaseName) IS NULL
BEGIN
    DECLARE @DbErr NVARCHAR(2048) = N'Database not found: ' + COALESCE(QUOTENAME(@DatabaseName), N'<NULL>');
    THROW 51000, @DbErr, 1;
END;

DECLARE @Sql NVARCHAR(MAX) = N'
USE ' + QUOTENAME(@DatabaseName) + N';
SET NOCOUNT ON;

DECLARE @SchemaName SYSNAME = @pSchemaName;
DECLARE @TableName  SYSNAME = @pTableName;
DECLARE @FragmentationMode NVARCHAR(20) = UPPER(@pFragmentationMode);
DECLARE @MinPageCountForFragmentation INT = @pMinPageCountForFragmentation;
DECLARE @ReorganizeFragmentationPercent DECIMAL(5,2) = @pReorganizeFragmentationPercent;
DECLARE @RebuildFragmentationPercent DECIMAL(5,2) = @pRebuildFragmentationPercent;
DECLARE @UseOnlineRebuild BIT = @pUseOnlineRebuild;
DECLARE @UseSortInTempdb BIT = @pUseSortInTempdb;
DECLARE @UseLobCompactionForReorganize BIT = @pUseLobCompactionForReorganize;
DECLARE @GeneratePartitionLevelCommands BIT = @pGeneratePartitionLevelCommands;
DECLARE @ColumnstoreDeletedRowsPercentThreshold DECIMAL(5,2) = @pColumnstoreDeletedRowsPercentThreshold;
DECLARE @FullName   NVARCHAR(517) = QUOTENAME(@SchemaName) + N''.'' + QUOTENAME(@TableName);
DECLARE @ObjectId   INT = OBJECT_ID(@FullName, N''U'');

IF @FragmentationMode NOT IN (N''LIMITED'', N''SAMPLED'', N''DETAILED'')
BEGIN
    THROW 51002, N''Invalid @FragmentationMode. Use LIMITED, SAMPLED, or DETAILED.'', 1;
END;

IF @MinPageCountForFragmentation IS NULL OR @MinPageCountForFragmentation < 0
BEGIN
    SET @MinPageCountForFragmentation = 0;
END;

IF @ReorganizeFragmentationPercent IS NULL OR @RebuildFragmentationPercent IS NULL
   OR @ReorganizeFragmentationPercent < 0
   OR @RebuildFragmentationPercent <= @ReorganizeFragmentationPercent
BEGIN
    THROW 51003, N''Invalid fragmentation thresholds. Rebuild threshold must be greater than reorganize threshold.'', 1;
END;

IF @ColumnstoreDeletedRowsPercentThreshold IS NULL OR @ColumnstoreDeletedRowsPercentThreshold < 0
BEGIN
    SET @ColumnstoreDeletedRowsPercentThreshold = 20.00;
END;

IF @ObjectId IS NULL
BEGIN
    DECLARE @ObjErr NVARCHAR(2048) = N''Table not found in database '' + QUOTENAME(DB_NAME()) + N'': '' + @FullName;
    THROW 51001, @ObjErr, 1;
END;

------------------------------------------------------------------------------
-- 1. TABLE OVERVIEW
------------------------------------------------------------------------------
PRINT ''=== 1. TABLE OVERVIEW ==='';

SELECT
    DB_NAME() AS DatabaseName,
    s.name AS SchemaName,
    t.name AS TableName,
    t.object_id,
    t.create_date,
    t.modify_date,
    SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.row_count ELSE 0 END) AS ApproxRowCount,
    COUNT(DISTINCT CASE WHEN ps.index_id IN (0, 1) THEN ps.partition_number END) AS PartitionCount,
    t.temporal_type_desc,
    t.is_memory_optimized,
    t.durability_desc,
    t.is_filetable,
    t.is_replicated,
    t.lock_escalation_desc
FROM sys.tables AS t
JOIN sys.schemas AS s
    ON s.schema_id = t.schema_id
LEFT JOIN sys.dm_db_partition_stats AS ps
    ON ps.object_id = t.object_id
WHERE t.object_id = @ObjectId
GROUP BY
    s.name,
    t.name,
    t.object_id,
    t.create_date,
    t.modify_date,
    t.temporal_type_desc,
    t.is_memory_optimized,
    t.durability_desc,
    t.is_filetable,
    t.is_replicated,
    t.lock_escalation_desc;

------------------------------------------------------------------------------
-- 2. TABLE & INDEX SIZE SUMMARY
------------------------------------------------------------------------------
PRINT ''=== 2. TABLE / INDEX SIZE SUMMARY (MB) ==='';

SELECT
    OBJECT_SCHEMA_NAME(@ObjectId) AS SchemaName,
    OBJECT_NAME(@ObjectId) AS TableName,
    SUM(CASE WHEN ps.index_id IN (0, 1) THEN ps.reserved_page_count ELSE 0 END) * 8.0 / 1024 AS DataReservedMB,
    SUM(CASE WHEN ps.index_id > 1 THEN ps.reserved_page_count ELSE 0 END) * 8.0 / 1024 AS NonclusteredIndexReservedMB,
    SUM(ps.reserved_page_count) * 8.0 / 1024 AS TotalReservedMB,
    SUM(ps.used_page_count) * 8.0 / 1024 AS TotalUsedMB,
    (SUM(ps.reserved_page_count) - SUM(ps.used_page_count)) * 8.0 / 1024 AS UnusedMB,
    SUM(ps.in_row_reserved_page_count) * 8.0 / 1024 AS InRowReservedMB,
    SUM(ps.lob_reserved_page_count) * 8.0 / 1024 AS LobReservedMB,
    SUM(ps.row_overflow_reserved_page_count) * 8.0 / 1024 AS RowOverflowReservedMB
FROM sys.dm_db_partition_stats AS ps
WHERE ps.object_id = @ObjectId;

------------------------------------------------------------------------------
-- 3. SIZE PER INDEX
------------------------------------------------------------------------------
PRINT ''=== 3. SIZE PER INDEX (MB) ==='';

SELECT
    ps.index_id,
    COALESCE(i.name, CASE WHEN ps.index_id = 0 THEN N''[HEAP]'' ELSE N''[UNNAMED]'' END) AS IndexName,
    i.type_desc AS IndexType,
    i.is_unique,
    i.is_primary_key,
    i.is_unique_constraint,
    i.is_disabled,
    SUM(ps.row_count) AS RowsInIndex,
    COUNT(DISTINCT ps.partition_number) AS PartitionCount,
    CASE
        WHEN COUNT(DISTINCT p.data_compression_desc) = 1 THEN MAX(p.data_compression_desc)
        ELSE N''MIXED''
    END AS DataCompression,
    SUM(ps.reserved_page_count) * 8.0 / 1024 AS ReservedMB,
    SUM(ps.used_page_count) * 8.0 / 1024 AS UsedMB,
    SUM(ps.in_row_reserved_page_count) * 8.0 / 1024 AS InRowReservedMB,
    SUM(ps.lob_reserved_page_count) * 8.0 / 1024 AS LobReservedMB,
    SUM(ps.row_overflow_reserved_page_count) * 8.0 / 1024 AS RowOverflowReservedMB
FROM sys.dm_db_partition_stats AS ps
JOIN sys.indexes AS i
    ON i.object_id = ps.object_id
   AND i.index_id = ps.index_id
JOIN sys.partitions AS p
    ON p.object_id = ps.object_id
   AND p.index_id = ps.index_id
   AND p.partition_number = ps.partition_number
WHERE ps.object_id = @ObjectId
GROUP BY
    ps.index_id,
    i.name,
    i.type_desc,
    i.is_unique,
    i.is_primary_key,
    i.is_unique_constraint,
    i.is_disabled
ORDER BY ReservedMB DESC, ps.index_id;

------------------------------------------------------------------------------
-- 4. COLUMNS
------------------------------------------------------------------------------
PRINT ''=== 4. COLUMNS ==='';

SELECT
    c.column_id,
    c.name AS ColumnName,
    ty.name AS DataType,
    CASE
        WHEN ty.name IN (N''nvarchar'', N''nchar'') AND c.max_length = -1 THEN N''MAX''
        WHEN ty.name IN (N''nvarchar'', N''nchar'') THEN CONVERT(VARCHAR(10), c.max_length / 2)
        WHEN ty.name IN (N''varchar'', N''char'', N''varbinary'', N''binary'') AND c.max_length = -1 THEN N''MAX''
        WHEN ty.name IN (N''varchar'', N''char'', N''varbinary'', N''binary'') THEN CONVERT(VARCHAR(10), c.max_length)
        ELSE NULL
    END AS MaxLength,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity,
    ic.seed_value AS IdentitySeed,
    ic.increment_value AS IdentityIncrement,
    c.is_computed,
    cc.is_persisted AS IsComputedPersisted,
    dc.definition AS DefaultValue,
    cc.definition AS ComputedDefinition,
    c.collation_name
FROM sys.columns AS c
JOIN sys.types AS ty
    ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.identity_columns AS ic
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
LEFT JOIN sys.default_constraints AS dc
    ON dc.parent_object_id = c.object_id
   AND dc.parent_column_id = c.column_id
LEFT JOIN sys.computed_columns AS cc
    ON cc.object_id = c.object_id
   AND cc.column_id = c.column_id
WHERE c.object_id = @ObjectId
ORDER BY c.column_id;

------------------------------------------------------------------------------
-- 5. INDEX DEFINITIONS
------------------------------------------------------------------------------
PRINT ''=== 5. INDEX DEFINITIONS ==='';

SELECT
    i.index_id,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    ds.name AS DataSpaceName,
    i.is_unique,
    i.is_primary_key,
    i.is_unique_constraint,
    i.is_disabled,
    i.is_hypothetical,
    i.fill_factor,
    i.allow_row_locks,
    i.allow_page_locks,
    i.has_filter,
    i.filter_definition,
    keycols.KeyColumns,
    includecols.IncludedColumns
FROM sys.indexes AS i
LEFT JOIN sys.data_spaces AS ds
    ON ds.data_space_id = i.data_space_id
OUTER APPLY
(
    SELECT
        STRING_AGG(
            CONVERT(NVARCHAR(MAX), QUOTENAME(c.name) + CASE WHEN ic.is_descending_key = 1 THEN N'' DESC'' ELSE N'' ASC'' END),
            N'', ''
        ) WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyColumns
    FROM sys.index_columns AS ic
    JOIN sys.columns AS c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE ic.object_id = i.object_id
      AND ic.index_id = i.index_id
      AND ic.is_included_column = 0
      AND ic.key_ordinal > 0
) AS keycols
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N'', '')
            WITHIN GROUP (ORDER BY ic.index_column_id) AS IncludedColumns
    FROM sys.index_columns AS ic
    JOIN sys.columns AS c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE ic.object_id = i.object_id
      AND ic.index_id = i.index_id
      AND ic.is_included_column = 1
) AS includecols
WHERE i.object_id = @ObjectId
  AND i.type > 0
ORDER BY i.index_id;

------------------------------------------------------------------------------
-- 6. PRIMARY KEY / UNIQUE CONSTRAINTS
------------------------------------------------------------------------------
PRINT ''=== 6. PRIMARY KEY / UNIQUE CONSTRAINTS ==='';

SELECT
    kc.name AS ConstraintName,
    kc.type_desc AS ConstraintType,
    i.name AS BackingIndexName,
    cols.Columns
FROM sys.key_constraints AS kc
JOIN sys.indexes AS i
    ON i.object_id = kc.parent_object_id
   AND i.index_id = kc.unique_index_id
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N'', '')
            WITHIN GROUP (ORDER BY ic.key_ordinal) AS Columns
    FROM sys.index_columns AS ic
    JOIN sys.columns AS c
        ON c.object_id = ic.object_id
       AND c.column_id = ic.column_id
    WHERE ic.object_id = kc.parent_object_id
      AND ic.index_id = kc.unique_index_id
      AND ic.key_ordinal > 0
) AS cols
WHERE kc.parent_object_id = @ObjectId
ORDER BY kc.type_desc, kc.name;

------------------------------------------------------------------------------
-- 7. FOREIGN KEYS (outgoing - this table references others)
------------------------------------------------------------------------------
PRINT ''=== 7. FOREIGN KEYS (outgoing) ==='';

SELECT
    fk.name AS ForeignKeyName,
    QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N''.'' + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) AS ParentTable,
    parentcols.ParentColumns,
    QUOTENAME(OBJECT_SCHEMA_NAME(fk.referenced_object_id)) + N''.'' + QUOTENAME(OBJECT_NAME(fk.referenced_object_id)) AS ReferencedTable,
    refcols.ReferencedColumns,
    fk.delete_referential_action_desc AS OnDelete,
    fk.update_referential_action_desc AS OnUpdate,
    fk.is_disabled,
    fk.is_not_trusted,
    fk.is_not_for_replication
FROM sys.foreign_keys AS fk
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N'', '')
            WITHIN GROUP (ORDER BY fkc.constraint_column_id) AS ParentColumns
    FROM sys.foreign_key_columns AS fkc
    JOIN sys.columns AS c
        ON c.object_id = fkc.parent_object_id
       AND c.column_id = fkc.parent_column_id
    WHERE fkc.constraint_object_id = fk.object_id
) AS parentcols
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N'', '')
            WITHIN GROUP (ORDER BY fkc.constraint_column_id) AS ReferencedColumns
    FROM sys.foreign_key_columns AS fkc
    JOIN sys.columns AS c
        ON c.object_id = fkc.referenced_object_id
       AND c.column_id = fkc.referenced_column_id
    WHERE fkc.constraint_object_id = fk.object_id
) AS refcols
WHERE fk.parent_object_id = @ObjectId
ORDER BY fk.name;

------------------------------------------------------------------------------
-- 8. FOREIGN KEYS (incoming - other tables referencing this one)
------------------------------------------------------------------------------
PRINT ''=== 8. FOREIGN KEYS (incoming) ==='';

SELECT
    fk.name AS ForeignKeyName,
    QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N''.'' + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) AS ChildTable,
    childcols.ChildColumns,
    QUOTENAME(OBJECT_SCHEMA_NAME(fk.referenced_object_id)) + N''.'' + QUOTENAME(OBJECT_NAME(fk.referenced_object_id)) AS ThisTable,
    thiscols.ThisTableColumns,
    fk.delete_referential_action_desc AS OnDelete,
    fk.update_referential_action_desc AS OnUpdate,
    fk.is_disabled,
    fk.is_not_trusted,
    fk.is_not_for_replication
FROM sys.foreign_keys AS fk
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N'', '')
            WITHIN GROUP (ORDER BY fkc.constraint_column_id) AS ChildColumns
    FROM sys.foreign_key_columns AS fkc
    JOIN sys.columns AS c
        ON c.object_id = fkc.parent_object_id
       AND c.column_id = fkc.parent_column_id
    WHERE fkc.constraint_object_id = fk.object_id
) AS childcols
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N'', '')
            WITHIN GROUP (ORDER BY fkc.constraint_column_id) AS ThisTableColumns
    FROM sys.foreign_key_columns AS fkc
    JOIN sys.columns AS c
        ON c.object_id = fkc.referenced_object_id
       AND c.column_id = fkc.referenced_column_id
    WHERE fkc.constraint_object_id = fk.object_id
) AS thiscols
WHERE fk.referenced_object_id = @ObjectId
ORDER BY fk.name;

------------------------------------------------------------------------------
-- 9. CHECK CONSTRAINTS
------------------------------------------------------------------------------
PRINT ''=== 9. CHECK CONSTRAINTS ==='';

SELECT
    cc.name AS ConstraintName,
    COL_NAME(cc.parent_object_id, cc.parent_column_id) AS ColumnName,
    cc.definition,
    cc.is_disabled,
    cc.is_not_trusted,
    cc.is_not_for_replication
FROM sys.check_constraints AS cc
WHERE cc.parent_object_id = @ObjectId
ORDER BY cc.name;

------------------------------------------------------------------------------
-- 10. DEFAULT CONSTRAINTS
------------------------------------------------------------------------------
PRINT ''=== 10. DEFAULT CONSTRAINTS ==='';

SELECT
    dc.name AS ConstraintName,
    COL_NAME(dc.parent_object_id, dc.parent_column_id) AS ColumnName,
    dc.definition
FROM sys.default_constraints AS dc
WHERE dc.parent_object_id = @ObjectId
ORDER BY dc.name;

------------------------------------------------------------------------------
-- 11. TRIGGERS
------------------------------------------------------------------------------
PRINT ''=== 11. TRIGGERS ==='';

SELECT
    tr.name AS TriggerName,
    tr.is_disabled,
    tr.is_instead_of_trigger,
    events.EventTypes,
    tr.create_date,
    tr.modify_date
FROM sys.triggers AS tr
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), te.type_desc), N'', '')
            WITHIN GROUP (ORDER BY te.type_desc) AS EventTypes
    FROM sys.trigger_events AS te
    WHERE te.object_id = tr.object_id
) AS events
WHERE tr.parent_id = @ObjectId
ORDER BY tr.name;

------------------------------------------------------------------------------
-- 12. STATISTICS
------------------------------------------------------------------------------
PRINT ''=== 12. STATISTICS ==='';

SELECT
    st.stats_id,
    st.name AS StatName,
    st.auto_created,
    st.user_created,
    st.no_recompute,
    st.is_incremental,
    st.has_filter,
    st.filter_definition,
    statcols.StatColumns,
    sp.last_updated AS LastUpdated,
    sp.rows,
    sp.rows_sampled,
    sp.steps,
    sp.unfiltered_rows,
    sp.modification_counter
FROM sys.stats AS st
OUTER APPLY
(
    SELECT
        STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name)), N'', '')
            WITHIN GROUP (ORDER BY sc.stats_column_id) AS StatColumns
    FROM sys.stats_columns AS sc
    JOIN sys.columns AS c
        ON c.object_id = sc.object_id
       AND c.column_id = sc.column_id
    WHERE sc.object_id = st.object_id
      AND sc.stats_id = st.stats_id
) AS statcols
OUTER APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) AS sp
WHERE st.object_id = @ObjectId
ORDER BY st.stats_id;

------------------------------------------------------------------------------
-- 13. ROWSTORE FRAGMENTATION / PHYSICAL STATS + GENERATED MAINTENANCE COMMANDS
------------------------------------------------------------------------------
PRINT ''=== 13. ROWSTORE FRAGMENTATION / PHYSICAL STATS + GENERATED MAINTENANCE COMMANDS ==='';

;WITH phys AS
(
    SELECT
        ips.object_id,
        ips.index_id,
        ips.partition_number,
        ips.alloc_unit_type_desc,
        ips.index_level,
        ips.index_depth,
        ips.avg_fragmentation_in_percent,
        ips.fragment_count,
        ips.avg_fragment_size_in_pages,
        ips.page_count,
        ips.avg_page_space_used_in_percent,
        ips.record_count,
        ips.ghost_record_count,
        ips.forwarded_record_count,
        i.name AS IndexNameRaw,
        i.type AS IndexTypeId,
        i.type_desc AS IndexType,
        p.data_compression_desc AS DataCompression,
        pi.PartitionCount,
        CONVERT(DECIMAL(9, 2), 100.0 * ips.forwarded_record_count / NULLIF(ips.record_count, 0)) AS ForwardedRecordPercent
    FROM sys.dm_db_index_physical_stats(DB_ID(), @ObjectId, NULL, NULL, @FragmentationMode) AS ips
    LEFT JOIN sys.indexes AS i
        ON i.object_id = ips.object_id
       AND i.index_id = ips.index_id
    LEFT JOIN sys.partitions AS p
        ON p.object_id = ips.object_id
       AND p.index_id = ips.index_id
       AND p.partition_number = ips.partition_number
    OUTER APPLY
    (
        SELECT COUNT(*) AS PartitionCount
        FROM sys.partitions AS p2
        WHERE p2.object_id = ips.object_id
          AND p2.index_id = ips.index_id
    ) AS pi
    WHERE ips.index_level = 0
)
SELECT
    ph.index_id,
    COALESCE(ph.IndexNameRaw, CASE WHEN ph.index_id = 0 THEN N''[HEAP]'' ELSE N''[UNNAMED]'' END) AS IndexName,
    ph.IndexType,
    ph.partition_number,
    ph.PartitionCount,
    ph.DataCompression,
    ph.alloc_unit_type_desc AS AllocationUnitType,
    ph.index_depth,
    ph.avg_fragmentation_in_percent,
    ph.fragment_count,
    ph.avg_fragment_size_in_pages,
    ph.page_count,
    CONVERT(DECIMAL(19, 2), ph.page_count * 8.0 / 1024) AS SizeMB,
    ph.avg_page_space_used_in_percent,
    ph.record_count,
    ph.ghost_record_count,
    ph.forwarded_record_count,
    ph.ForwardedRecordPercent,
    CASE
        WHEN ph.page_count < @MinPageCountForFragmentation THEN N''IGNORE_SMALL_INDEX''
        WHEN ph.IndexTypeId IN (5, 6) THEN N''COLUMNSTORE_SEE_SECTION_14''
        WHEN ph.index_id = 0 AND COALESCE(ph.ForwardedRecordPercent, 0) >= 10 THEN N''HEAP_CONSIDER_REBUILD_OR_CLUSTERED_INDEX''
        WHEN ph.index_id = 0 AND ph.avg_fragmentation_in_percent >= @RebuildFragmentationPercent THEN N''HEAP_CONSIDER_REBUILD_OR_CLUSTERED_INDEX''
        WHEN ph.avg_fragmentation_in_percent < @ReorganizeFragmentationPercent THEN N''OK''
        WHEN ph.avg_fragmentation_in_percent < @RebuildFragmentationPercent THEN N''CONSIDER_REORGANIZE''
        ELSE N''CONSIDER_REBUILD''
    END AS MaintenanceHint,
    CASE
        WHEN ph.page_count < @MinPageCountForFragmentation THEN NULL
        WHEN ph.IndexTypeId IN (5, 6) THEN NULL
        WHEN ph.index_id = 0
             AND (COALESCE(ph.ForwardedRecordPercent, 0) >= 10 OR ph.avg_fragmentation_in_percent >= @RebuildFragmentationPercent)
            THEN N''ALTER TABLE '' + @FullName + N'' REBUILD;''
        WHEN ph.IndexNameRaw IS NULL THEN NULL
        WHEN ph.avg_fragmentation_in_percent >= @RebuildFragmentationPercent
            THEN N''ALTER INDEX '' + QUOTENAME(ph.IndexNameRaw) + N'' ON '' + @FullName
               + N'' REBUILD''
               + CASE WHEN @GeneratePartitionLevelCommands = 1 AND ph.PartitionCount > 1
                      THEN N'' PARTITION = '' + CONVERT(NVARCHAR(20), ph.partition_number)
                      ELSE N'''' END
               + N'' WITH (''
               + CASE WHEN @UseOnlineRebuild = 1 THEN N''ONLINE = ON'' ELSE N''ONLINE = OFF'' END
               + CASE WHEN @UseSortInTempdb = 1 THEN N'', SORT_IN_TEMPDB = ON'' ELSE N'''' END
               + N'');''
        WHEN ph.avg_fragmentation_in_percent >= @ReorganizeFragmentationPercent
            THEN N''ALTER INDEX '' + QUOTENAME(ph.IndexNameRaw) + N'' ON '' + @FullName
               + N'' REORGANIZE''
               + CASE WHEN @GeneratePartitionLevelCommands = 1 AND ph.PartitionCount > 1
                      THEN N'' PARTITION = '' + CONVERT(NVARCHAR(20), ph.partition_number)
                      ELSE N'''' END
               + CASE WHEN @UseLobCompactionForReorganize = 1 THEN N'' WITH (LOB_COMPACTION = ON)'' ELSE N'''' END
               + N'';''
        ELSE NULL
    END AS RecommendedCommand,
    CASE
        WHEN ph.page_count < @MinPageCountForFragmentation THEN N''No command generated: below minimum page-count threshold.''
        WHEN ph.IndexTypeId IN (5, 6) THEN N''Columnstore command is handled in section 14.''
        WHEN ph.index_id = 0 THEN N''Heap command generated without ONLINE option; consider whether a clustered index is a better long-term fix for forwarded records.''
        WHEN ph.avg_fragmentation_in_percent >= @RebuildFragmentationPercent THEN N''Generated REBUILD command uses ONLINE = ON by default. It can still briefly block at start/end and can fail for unsupported index/edition/type; remove ONLINE = ON if needed.''
        WHEN ph.avg_fragmentation_in_percent >= @ReorganizeFragmentationPercent THEN N''Generated REORGANIZE command is online by nature and single-threaded; no ONLINE = ON option exists for REORGANIZE.''
        ELSE N''No command generated: fragmentation below reorganize threshold.''
    END AS CommandNote,
    @FragmentationMode AS ScanMode,
    @MinPageCountForFragmentation AS HintMinPageCount,
    @ReorganizeFragmentationPercent AS ReorganizeThresholdPercent,
    @RebuildFragmentationPercent AS RebuildThresholdPercent
FROM phys AS ph
ORDER BY
    CASE WHEN ph.index_id IN (0, 1) THEN 0 ELSE 1 END,
    ph.page_count DESC,
    ph.avg_fragmentation_in_percent DESC;

------------------------------------------------------------------------------
-- 14. COLUMNSTORE ROW GROUP HEALTH + GENERATED MAINTENANCE COMMANDS, IF ANY
------------------------------------------------------------------------------
PRINT ''=== 14. COLUMNSTORE ROW GROUP HEALTH + GENERATED MAINTENANCE COMMANDS, IF ANY ==='';

SELECT
    rg.index_id,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    rg.partition_number,
    rg.row_group_id,
    rg.state_desc,
    rg.total_rows,
    rg.deleted_rows,
    CONVERT(DECIMAL(9, 2), 100.0 * rg.deleted_rows / NULLIF(rg.total_rows, 0)) AS DeletedRowsPercent,
    rg.size_in_bytes / 1024.0 / 1024.0 AS SizeMB,
    CASE
        WHEN rg.total_rows = 0 THEN N''EMPTY_ROWGROUP''
        WHEN 100.0 * rg.deleted_rows / NULLIF(rg.total_rows, 0) >= @ColumnstoreDeletedRowsPercentThreshold THEN N''CONSIDER_COLUMNSTORE_REORGANIZE''
        ELSE N''OK''
    END AS MaintenanceHint,
    CASE
        WHEN rg.total_rows > 0
         AND 100.0 * rg.deleted_rows / NULLIF(rg.total_rows, 0) >= @ColumnstoreDeletedRowsPercentThreshold
            THEN N''ALTER INDEX '' + QUOTENAME(i.name) + N'' ON '' + @FullName + N'' REORGANIZE;''
        ELSE NULL
    END AS RecommendedCommand,
    CASE
        WHEN rg.total_rows = 0 THEN N''No command generated: empty rowgroup.''
        WHEN 100.0 * rg.deleted_rows / NULLIF(rg.total_rows, 0) >= @ColumnstoreDeletedRowsPercentThreshold THEN N''Columnstore REORGANIZE can help clean up deleted rows / rowgroups. Review before running on very large tables.''
        ELSE N''No command generated: deleted row percentage below threshold.''
    END AS CommandNote,
    @ColumnstoreDeletedRowsPercentThreshold AS DeletedRowsThresholdPercent
FROM sys.dm_db_column_store_row_group_physical_stats AS rg
JOIN sys.indexes AS i
    ON i.object_id = rg.object_id
   AND i.index_id = rg.index_id
WHERE rg.object_id = @ObjectId
ORDER BY
    rg.index_id,
    rg.partition_number,
    rg.row_group_id;

------------------------------------------------------------------------------
-- 15. INDEX USAGE SINCE LAST RESTART / DB ATTACH
------------------------------------------------------------------------------
PRINT ''=== 15. INDEX USAGE SINCE LAST RESTART / DB ATTACH ==='';

SELECT
    i.index_id,
    COALESCE(i.name, CASE WHEN i.index_id = 0 THEN N''[HEAP]'' ELSE N''[UNNAMED]'' END) AS IndexName,
    i.type_desc AS IndexType,
    COALESCE(iu.user_seeks, 0) AS user_seeks,
    COALESCE(iu.user_scans, 0) AS user_scans,
    COALESCE(iu.user_lookups, 0) AS user_lookups,
    COALESCE(iu.user_updates, 0) AS user_updates,
    iu.last_user_seek,
    iu.last_user_scan,
    iu.last_user_lookup,
    iu.last_user_update
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS iu
    ON iu.database_id = DB_ID()
   AND iu.object_id = i.object_id
   AND iu.index_id = i.index_id
WHERE i.object_id = @ObjectId
ORDER BY i.index_id;
';

EXEC sys.sp_executesql
    @Sql,
    N'@pSchemaName SYSNAME,
      @pTableName SYSNAME,
      @pFragmentationMode NVARCHAR(20),
      @pMinPageCountForFragmentation INT,
      @pReorganizeFragmentationPercent DECIMAL(5,2),
      @pRebuildFragmentationPercent DECIMAL(5,2),
      @pUseOnlineRebuild BIT,
      @pUseSortInTempdb BIT,
      @pUseLobCompactionForReorganize BIT,
      @pGeneratePartitionLevelCommands BIT,
      @pColumnstoreDeletedRowsPercentThreshold DECIMAL(5,2)',
    @pSchemaName = @SchemaName,
    @pTableName  = @TableName,
    @pFragmentationMode = @FragmentationMode,
    @pMinPageCountForFragmentation = @MinPageCountForFragmentation,
    @pReorganizeFragmentationPercent = @ReorganizeFragmentationPercent,
    @pRebuildFragmentationPercent = @RebuildFragmentationPercent,
    @pUseOnlineRebuild = @UseOnlineRebuild,
    @pUseSortInTempdb = @UseSortInTempdb,
    @pUseLobCompactionForReorganize = @UseLobCompactionForReorganize,
    @pGeneratePartitionLevelCommands = @GeneratePartitionLevelCommands,
    @pColumnstoreDeletedRowsPercentThreshold = @ColumnstoreDeletedRowsPercentThreshold;



