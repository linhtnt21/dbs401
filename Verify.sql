USE HospitalZT;
GO
SELECT 'Departments' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.Departments
UNION ALL
SELECT 'Staff' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.Staff
UNION ALL
SELECT 'Medications' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.Medications
UNION ALL
SELECT 'UserDepartments' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.UserDepartments
UNION ALL
SELECT 'Patients' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.Patients
UNION ALL
SELECT 'Encounters' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.Encounters
UNION ALL
SELECT 'MedicalRecords' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.MedicalRecords
UNION ALL
SELECT 'Prescriptions' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.Prescriptions
UNION ALL
SELECT 'PrescriptionItems' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.PrescriptionItems
UNION ALL
SELECT 'LabOrders' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.LabOrders
UNION ALL
SELECT 'LabResults' AS TableName, COUNT_BIG(*) AS RowCount FROM dbo.LabResults;
GO
SELECT PatientCode,FullName,NationalId FROM dbo.Patients;
GO
SELECT RecordId,Diagnosis,TreatmentPlan FROM dbo.MedicalRecords;
GO
EXEC sys.sp_generate_database_ledger_digest;
