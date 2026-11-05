/*
  HospitalZT - Thanh vien 3: Ledger va kiem chung
  SQL Server 2022

  Huong dan:
  1. Chay cac phan kiem tra va truy van trong SSMS, database HospitalZT.
  2. Doi LabOrderId o phan 4 thanh ID app vua tao neu can.
  3. Digest o phan 6 phai duoc luu nguyen ven ben ngoai database va noi DBA
     khong the sua. Khong commit digest van hanh vao Git.
  4. Phan 7 la mau; thay JSON mau bang digest that truoc khi bo comment va chay.
  5. Phan 8 du kien tra loi loi Msg 37361. Chi bo comment dung dong DELETE de demo.

  Script khong tu dong sua schema, xoa du lieu nghiep vu, hay sua/xoa history.
*/

USE HospitalZT;
GO

/* 1. Xac nhan instance/database */
SELECT @@SERVERNAME AS ServerName, DB_NAME() AS CurrentDatabase;
GO

/* 2. Kiem tra 7 bang updatable Ledger, history table va ledger view */
SELECT
    t.name AS LedgerTable,
    t.ledger_type_desc AS LedgerType,
    h.name AS HistoryTable,
    v.name AS LedgerView
FROM sys.tables AS t
LEFT JOIN sys.tables AS h
    ON h.object_id = t.history_table_id
LEFT JOIN sys.views AS v
    ON v.object_id = t.ledger_view_id
WHERE t.name IN
(
    N'Patients', N'Encounters', N'MedicalRecords', N'Prescriptions',
    N'PrescriptionItems', N'LabOrders', N'LabResults'
)
ORDER BY t.name;
GO

/* Mong doi: 7 dong, UPDATABLE LEDGER TABLE, history table va ledger view co ten. */

/* 3. Lay cac ID hop le cho demo app.
   Chon EncounterId, DepartmentId va RecordId tren cung mot dong. */
SELECT TOP (20)
    e.EncounterId,
    e.DepartmentId,
    mr.RecordId
FROM dbo.Encounters AS e
INNER JOIN dbo.MedicalRecords AS mr
    ON mr.EncounterId = e.EncounterId
   AND mr.DepartmentId = e.DepartmentId
ORDER BY e.EncounterId, mr.RecordId;
GO

/* 4. Xem ledger trace cua LabOrder vua tao boi app.
   Thay 1010 bang LabOrderId app in ra neu ban da chay lai app. */
DECLARE @LabOrderId int = 1010;

SELECT
    l.LabOrderId,
    l.ledger_transaction_id,
    l.ledger_sequence_number,
    l.ledger_operation_type_desc AS LedgerOperation,
    t.commit_time,
    t.principal_name
FROM dbo.LabOrdersLedgerView AS l
INNER JOIN sys.database_ledger_transactions AS t
    ON t.transaction_id = l.ledger_transaction_id
WHERE l.LabOrderId = @LabOrderId
ORDER BY l.ledger_transaction_id DESC, l.ledger_sequence_number DESC;
GO

/* 5. Kiem tra yeu cau SNAPSHOT isolation truoc khi verify digest.
   Neu OFF, can quyen ALTER DATABASE va phoi hop nhom truong truoc khi bat. */
SELECT
    name,
    snapshot_isolation_state_desc
FROM sys.databases
WHERE name = N'HospitalZT';
GO

/* Chi bo comment va chay ALTER neu snapshot_isolation_state_desc = OFF:
ALTER DATABASE HospitalZT SET ALLOW_SNAPSHOT_ISOLATION ON;
GO
*/

/* 6. Sinh digest sau khi cac giao dich can minh chung da commit.
   SSMS tra ve cot latest_digest (JSON). Luu JSON nguyen ven ra noi tin cay,
   ben ngoai database/Docker va ngoai quyen sua cua DBA. */
EXEC sys.sp_generate_database_ledger_digest;
GO

/* 7. Verify voi digest da luu ben ngoai database.
   CAN thay JSON mau ben duoi bang object latest_digest that, dat trong array,
   bo comment va chay. Khong sua hash hay metadata trong digest.

DECLARE @digests nvarchar(max) = N'
[
  {
    "database_name": "HospitalZT",
    "block_id": 0,
    "hash": "REPLACE_WITH_REAL_HASH",
    "last_transaction_commit_time": "REPLACE_WITH_REAL_TIME",
    "digest_time": "REPLACE_WITH_REAL_TIME"
  }
]';

EXEC sys.sp_verify_database_ledger @digests = @digests;
*/

/* 8. Demo history table tu choi ghi truc tiep.
   Du kien Msg 37361: Cannot update ledger history table.
   Chi bo comment dung dong DELETE va chay rieng; khong chay ca file.

DELETE TOP (1) FROM dbo.LabOrdersHistory;
*/

/* Quyen can thiet:
   - Sinh digest: GENERATE LEDGER DIGEST.
   - Verify digest/doc ledger content: VIEW LEDGER CONTENT.
   Chi cap quyen toi thieu theo huong dan cua nhom truong.
*/
