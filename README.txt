HospitalZT Full Setup - Windows PowerShell 5.1 + Docker Desktop (Linux containers)
Run Setup.ps1 once from this folder. The script asks for your sa password; do not store it in Git.
Prerequisites: Docker Desktop running, Windows x64, PowerShell 5.1/.NET Framework with Always Encrypted support, internet access to Microsoft Container Registry.
The script creates Docker container, persistent volume, database, 11 domain tables, 7 updatable ledger tables, local certificate/CMK/CEK, and all synthetic seed data in English.
Seed counts: Departments 5; Staff 10; UserDepartments 5; Medications 10; Patients 30; Encounters 60; MedicalRecords 60; Prescriptions 40; PrescriptionItems 80; LabOrders 30; LabResults 30.
All dates, names, medication and clinical details are fictional; no medical advice.
Private key resides in CurrentUser/My on Windows. Use the SAME Windows user for SSMS decryption. In SSMS enable Always Encrypted and reconnect, then run Verify.sql. With Always Encrypted disabled, sensitive values are ciphertext.
Use sa ONLY for initial setup. Actual doctor logins, RLS policies and least-privilege permissions are NOT created. Mapping rows alone do NOT enforce permissions. TDE and external Ledger digest retention/verification are NOT configured. Do not treat this starter as the completed security project.
The setup account owns the private key; it cannot serve as your no-key DBA test account. Use a separate Windows user/machine without this certificate for that test. Docker administrators on the same Windows host are not a strong trust boundary.
The certificate is exportable for secure backup; use certificate manager to export a password-protected PFX to protected storage outside the repo. Losing it can make encrypted columns unrecoverable. Volume persistence is not a backup.
No existing database/container/volume is deleted. If any step fails, stop and preserve the full error. The script refuses automatic reruns against existing containers/volumes. Diagnose instead of deleting data blindly.
Schema and generator statically reviewed; not executed on Windows/Docker/SQL Server in the authoring environment. Validate all setup stages on your lab before reporting success.
Sources:
https://learn.microsoft.com/en-us/sql/linux/quickstart-install-connect-docker
https://learn.microsoft.com/en-us/sql/relational-databases/security/encryption/create-and-store-column-master-keys-always-encrypted
https://learn.microsoft.com/en-us/sql/relational-databases/security/ledger/ledger-how-to-updatable-ledger-tables
