USE master;
IF DB_ID(N'HospitalZT') IS NOT NULL THROW 50001, 'Database exists. Stop; do not overwrite.', 1;
EXEC(N'CREATE DATABASE HospitalZT COLLATE Latin1_General_100_BIN2');
