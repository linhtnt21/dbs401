/* HospitalZT - member 3 Ledger checks
   Run in SSMS against HospitalZT after Setup.ps1 succeeds.
   This script is read-only. Export a digest after a committed write using the
   documented procedure at the end; preserve the returned JSON outside DBA control.
*/
USE HospitalZT;
GO

-- Confirm all seven application tables are updatable ledger tables and expose views.
SELECT s.name AS SchemaName, t.name AS TableName, t.ledger_type_desc AS LedgerType,
       t.temporal_type_desc AS TemporalType, v.name AS LedgerView
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id=t.schema_id
LEFT JOIN sys.views AS v ON v.object_id=t.ledger_view_id
WHERE s.name=N'dbo' AND t.name IN
 (N'Patients',N'Encounters',N'MedicalRecords',N'Prescriptions',N'PrescriptionItems',N'LabOrders',N'LabResults')
ORDER BY t.name;
GO

-- Confirm the seven system-versioned history tables exist and show row counts.
SELECT s.name AS SchemaName, h.name AS HistoryTable, SUM(p.rows) AS HistoryRows
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id=t.schema_id
JOIN sys.tables AS h ON h.object_id=t.history_table_id
JOIN sys.partitions AS p ON p.object_id=h.object_id AND p.index_id IN (0,1)
WHERE s.name=N'dbo' AND t.name IN
 (N'Patients',N'Encounters',N'MedicalRecords',N'Prescriptions',N'PrescriptionItems',N'LabOrders',N'LabResults')
GROUP BY s.name,h.name ORDER BY h.name;
GO

-- Ledger views include transaction ID, sequence number, operation type and
-- table columns. Inspect actual records after a controlled test update.
SELECT TOP (100) * FROM dbo.PrescriptionsLedgerView ORDER BY ledger_start_transaction_id DESC;
SELECT TOP (100) * FROM dbo.LabResultsLedgerView ORDER BY ledger_start_transaction_id DESC;
GO

-- After a committed test UPDATE, generate a database ledger digest and save
-- the full returned JSON to protected storage outside the DBA's control:
-- EXEC sys.sp_generate_database_ledger_digest;
-- Verify a trusted digest by passing its JSON payload to:
-- EXEC sys.sp_verify_database_ledger @digest = N'<paste trusted digest JSON>';
-- Do not use a digest generated after suspected tampering as the trusted copy.
