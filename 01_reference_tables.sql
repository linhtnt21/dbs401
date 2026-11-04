USE HospitalZT;
SET XACT_ABORT ON;
BEGIN TRAN;
CREATE TABLE dbo.Departments (DepartmentId int PRIMARY KEY, DepartmentCode varchar(10) UNIQUE NOT NULL, DepartmentName nvarchar(100) NOT NULL, Location nvarchar(100), Phone varchar(20), IsActive bit NOT NULL DEFAULT 1);
CREATE TABLE dbo.Staff (StaffId int PRIMARY KEY, DepartmentId int NOT NULL REFERENCES dbo.Departments(DepartmentId), StaffCode varchar(20) UNIQUE NOT NULL, FullName nvarchar(100) NOT NULL, JobTitle nvarchar(50), Email varchar(100), IsActive bit NOT NULL DEFAULT 1);
CREATE TABLE dbo.UserDepartments (DatabaseUser sysname NOT NULL, DepartmentId int NOT NULL REFERENCES dbo.Departments(DepartmentId), PRIMARY KEY(DatabaseUser, DepartmentId));
CREATE TABLE dbo.Medications (MedicationId int PRIMARY KEY, MedicationCode varchar(20) UNIQUE NOT NULL, MedicationName nvarchar(100) NOT NULL, Strength nvarchar(50), Unit nvarchar(30), IsActive bit NOT NULL DEFAULT 1);
INSERT dbo.Departments(DepartmentId,DepartmentCode,DepartmentName) VALUES (1,'IM',N'Internal Medicine'),(2,'SUR',N'Surgery'),(3,'PED',N'Pediatrics'),(4,'OBG',N'Obstetrics and Gynecology'),(5,'CAR',N'Cardiology');
COMMIT;
