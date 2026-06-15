
    SELECT
    MAX(DATALENGTH(kolonadi)) / 2 AS max_kolonadi_len,
    AVG(CONVERT(decimal(18,2), DATALENGTH(kolonadi))) / 2 AS avg_kolonadi_len
FROM dbo.tabloadi;
