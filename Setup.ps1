param([switch]$ReuseContainer, [switch]$UpdateData)
if ($UpdateData) { $ReuseContainer = $true }
# Run in Windows PowerShell 5.1. Docker Desktop must be running.
# Setup v1.6: creates a new database; optionally reuses the known lab container. Never deletes data.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
if ($ReuseContainer) { $prompt = 'Enter the SAME sa password used to create hospital-sql' } else { $prompt = 'Choose the SQL sa password (12+ chars, upper/lower/digit/symbol)' }
$secure = Read-Host $prompt -AsSecureString
$password = [System.Net.NetworkCredential]::new('', $secure).Password
if ($password.Length -lt 12) { throw 'Use at least 12 characters.' }
$container = 'hospital-sql'
$existing = & docker ps -a --filter "name=^/$container`$" --format '{{.Names}}'
if ($LASTEXITCODE -ne 0) { throw 'Start Docker Desktop first.' }
if ($existing) {
    if (-not $ReuseContainer) { throw 'Container exists. If the earlier attempt stopped before creating HospitalZT, run: .\Setup.ps1 -ReuseContainer' }
    $port = & docker port hospital-sql 1433/tcp
    if ($LASTEXITCODE -ne 0 -or $port -notcontains '127.0.0.1:14330') { throw 'Existing container port differs from expected localhost:14330. Stop and inspect configuration.' }
    $inspectJson = & docker inspect hospital-sql
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect hospital-sql. No changes made.' }
    $containerInfo = ($inspectJson -join "`n") | ConvertFrom-Json
    $mounts = @($containerInfo[0].Mounts | Where-Object { $_.Destination -eq '/var/opt/mssql' })
    if ($mounts.Count -ne 1) { throw 'Expected exactly one data mount. No changes made.' }
    if ($mounts[0].Type -ne 'volume' -or $mounts[0].Name -ne 'hospital_sql_data') {
        throw 'Unexpected data volume. No changes made.'
    }
    & docker start hospital-sql
    if ($LASTEXITCODE -ne 0) { throw 'Cannot start existing container.' }
} else {
if ($ReuseContainer) { throw 'No hospital-sql container exists. Run without -ReuseContainer for a new setup.' }

$volumes = & docker volume ls --format '{{.Name}}'
if ($volumes -contains 'hospital_sql_data') { throw 'hospital_sql_data already exists. Refusing to reuse existing data automatically.' }
& docker pull mcr.microsoft.com/mssql/server:2022-latest
if ($LASTEXITCODE -ne 0) { throw 'Docker image download failed.' }
& docker volume create hospital_sql_data
if ($LASTEXITCODE -ne 0) { throw 'Volume creation failed.' }
$env:MSSQL_SA_PASSWORD = $password
try {
    & docker run -d --name hospital-sql --hostname hospital-sql --restart unless-stopped -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_SA_PASSWORD -p 127.0.0.1:14330:1433 -v hospital_sql_data:/var/opt/mssql mcr.microsoft.com/mssql/server:2022-latest
    if ($LASTEXITCODE -ne 0) { throw 'Container creation failed.' }
} finally { Remove-Item Env:MSSQL_SA_PASSWORD -ErrorAction SilentlyContinue }
}
$b = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
$b["Data Source"]='tcp:127.0.0.1,14330'; $b["Initial Catalog"]='master'; $b["User ID"]='sa'; $b["Password"]=$password
$b["Encrypt"]=$true; $b["TrustServerCertificate"]=$true; $b["Connect Timeout"]=5
$conn=[System.Data.SqlClient.SqlConnection]::new($b.get_ConnectionString())
$ready=$false
$lastConnectionError='No connection attempt completed.'
for($i=0;$i -lt 12;$i++) {
    try {
        $conn.Open()
        $ready=$true
        break
    } catch {
        $errorDetail=$_.Exception
        while ($errorDetail.InnerException) { $errorDetail=$errorDetail.InnerException }
        $lastConnectionError=$errorDetail.Message
        Write-Host ("Connection attempt {0}/12 failed: {1}" -f ($i+1), $lastConnectionError)
        if ($errorDetail -is [System.Data.SqlClient.SqlException] -and $errorDetail.Number -eq 18456) {
            throw 'SQL Server rejected the login. Enter the ORIGINAL sa password; -ReuseContainer does not change it.'
        }
        $conn.Dispose()
        [System.Data.SqlClient.SqlConnection]::ClearAllPools()
        $conn=[System.Data.SqlClient.SqlConnection]::new($b.get_ConnectionString())
        if ($i -lt 11) { Start-Sleep -Seconds 2 }
    }
}
if(-not $ready) { throw ("Cannot connect to tcp:127.0.0.1,14330. Last error: " + $lastConnectionError) }
function Run-SqlFile([string]$name) {
    $sql=Get-Content (Join-Path $PSScriptRoot $name) -Raw
    foreach($batch in [regex]::Split($sql,'(?im)^\s*GO\s*\r?$')) {
        if($batch.Trim()) { $cmd=$conn.CreateCommand(); $cmd.CommandText=$batch; $cmd.CommandTimeout=120; [void]$cmd.ExecuteNonQuery(); $cmd.Dispose() }
    }
}
$check=$conn.CreateCommand()
$check.CommandText="SELECT CASE WHEN DB_ID(N'HospitalZT') IS NULL THEN 0 ELSE 1 END"
$alreadyExists=[int]$check.ExecuteScalar();$check.Dispose()
if ($UpdateData) {
    if ($alreadyExists -ne 1) { $conn.Close(); throw 'HospitalZT does not exist. Run initial setup first.' }
    $conn.Close()
    $b['Initial Catalog']='HospitalZT'
    $b['Column Encryption Setting']='Enabled'
    $conn=[System.Data.SqlClient.SqlConnection]::new($b.get_ConnectionString())
    $conn.Open()
    # Applies only to the original training dataset; never use on real records.
$keyNames=@{Departments='DepartmentId';Staff='StaffId';Medications='MedicationId';Patients='PatientId';Encounters='EncounterId';MedicalRecords='RecordId';Prescriptions='PrescriptionId';PrescriptionItems='PrescriptionItemId';LabOrders='LabOrderId';LabResults='LabResultId'}
$dataset = @'
{
  "Departments": [
    {
      "DepartmentId": 1,
      "DepartmentCode": "IM",
      "DepartmentName": "Internal Medicine",
      "Location": "Building A - Floor 1",
      "Phone": "+1-202-555-0111"
    },
    {
      "DepartmentId": 2,
      "DepartmentCode": "SUR",
      "DepartmentName": "Surgery",
      "Location": "Building A - Floor 2",
      "Phone": "+1-202-555-0112"
    },
    {
      "DepartmentId": 3,
      "DepartmentCode": "PED",
      "DepartmentName": "Pediatrics",
      "Location": "Building B - Floor 1",
      "Phone": "+1-202-555-0113"
    },
    {
      "DepartmentId": 4,
      "DepartmentCode": "OBG",
      "DepartmentName": "Obstetrics and Gynecology",
      "Location": "Building B - Floor 2",
      "Phone": "+1-202-555-0114"
    },
    {
      "DepartmentId": 5,
      "DepartmentCode": "CAR",
      "DepartmentName": "Cardiology",
      "Location": "Building C - Floor 1",
      "Phone": "+1-202-555-0115"
    }
  ],
  "Staff": [
    {
      "StaffId": 1,
      "DepartmentId": 1,
      "StaffCode": "ST001",
      "FullName": "James Carter",
      "JobTitle": "Doctor",
      "Email": "james.carter@example.com"
    },
    {
      "StaffId": 2,
      "DepartmentId": 1,
      "StaffCode": "ST002",
      "FullName": "Emma Wilson",
      "JobTitle": "Nurse",
      "Email": "emma.wilson@example.com"
    },
    {
      "StaffId": 3,
      "DepartmentId": 2,
      "StaffCode": "ST003",
      "FullName": "Michael Brown",
      "JobTitle": "Doctor",
      "Email": "michael.brown@example.com"
    },
    {
      "StaffId": 4,
      "DepartmentId": 2,
      "StaffCode": "ST004",
      "FullName": "Olivia Davis",
      "JobTitle": "Nurse",
      "Email": "olivia.davis@example.com"
    },
    {
      "StaffId": 5,
      "DepartmentId": 3,
      "StaffCode": "ST005",
      "FullName": "William Miller",
      "JobTitle": "Doctor",
      "Email": "william.miller@example.com"
    },
    {
      "StaffId": 6,
      "DepartmentId": 3,
      "StaffCode": "ST006",
      "FullName": "Sophia Taylor",
      "JobTitle": "Nurse",
      "Email": "sophia.taylor@example.com"
    },
    {
      "StaffId": 7,
      "DepartmentId": 4,
      "StaffCode": "ST007",
      "FullName": "Charlotte Lee",
      "JobTitle": "Doctor",
      "Email": "charlotte.lee@example.com"
    },
    {
      "StaffId": 8,
      "DepartmentId": 4,
      "StaffCode": "ST008",
      "FullName": "Amelia Martin",
      "JobTitle": "Nurse",
      "Email": "amelia.martin@example.com"
    },
    {
      "StaffId": 9,
      "DepartmentId": 5,
      "StaffCode": "ST009",
      "FullName": "Benjamin Clark",
      "JobTitle": "Doctor",
      "Email": "benjamin.clark@example.com"
    },
    {
      "StaffId": 10,
      "DepartmentId": 5,
      "StaffCode": "ST010",
      "FullName": "Mia Lewis",
      "JobTitle": "Nurse",
      "Email": "mia.lewis@example.com"
    }
  ],
  "Medications": [
    {
      "MedicationId": 1,
      "MedicationCode": "MED001",
      "MedicationName": "Paracetamol",
      "Strength": "500 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 2,
      "MedicationCode": "MED002",
      "MedicationName": "Amoxicillin",
      "Strength": "500 mg",
      "Unit": "Capsule"
    },
    {
      "MedicationId": 3,
      "MedicationCode": "MED003",
      "MedicationName": "Cetirizine",
      "Strength": "10 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 4,
      "MedicationCode": "MED004",
      "MedicationName": "Omeprazole",
      "Strength": "20 mg",
      "Unit": "Capsule"
    },
    {
      "MedicationId": 5,
      "MedicationCode": "MED005",
      "MedicationName": "Ibuprofen",
      "Strength": "200 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 6,
      "MedicationCode": "MED006",
      "MedicationName": "Metformin",
      "Strength": "500 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 7,
      "MedicationCode": "MED007",
      "MedicationName": "Amlodipine",
      "Strength": "5 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 8,
      "MedicationCode": "MED008",
      "MedicationName": "Losartan",
      "Strength": "50 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 9,
      "MedicationCode": "MED009",
      "MedicationName": "Folic acid",
      "Strength": "400 mcg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 10,
      "MedicationCode": "MED010",
      "MedicationName": "Oral rehydration salts",
      "Strength": "Standard sachet",
      "Unit": "Sachet"
    }
  ],
  "UserDepartments": [
    {
      "DatabaseUser": "doctor_im",
      "DepartmentId": 1
    },
    {
      "DatabaseUser": "doctor_sur",
      "DepartmentId": 2
    },
    {
      "DatabaseUser": "doctor_ped",
      "DepartmentId": 3
    },
    {
      "DatabaseUser": "doctor_obg",
      "DepartmentId": 4
    },
    {
      "DatabaseUser": "doctor_car",
      "DepartmentId": 5
    }
  ],
  "Patients": [
    {
      "PatientCode": "PT0001",
      "FullName": "Oliver Bennett",
      "DateOfBirth": "1980-01-01",
      "Gender": "Male",
      "NationalId": "805537197893",
      "Phone": "+1-202-555-0100",
      "Address": "120 Maple Avenue, Brookfield",
      "InsuranceNumber": "664680368871",
      "EmergencyContact": "Chloe Wright | +1-202-555-0150"
    },
    {
      "PatientCode": "PT0002",
      "FullName": "Ava Thompson",
      "DateOfBirth": "1981-02-02",
      "Gender": "Female",
      "NationalId": "802125173183",
      "Phone": "+1-202-555-0101",
      "Address": "121 Maple Avenue, Brookfield",
      "InsuranceNumber": "640704478310",
      "EmergencyContact": "Henry Scott | +1-202-555-0151"
    },
    {
      "PatientCode": "PT0003",
      "FullName": "Noah Anderson",
      "DateOfBirth": "1982-03-03",
      "Gender": "Male",
      "NationalId": "805881351019",
      "Phone": "+1-202-555-0102",
      "Address": "122 Maple Avenue, Brookfield",
      "InsuranceNumber": "614469123235",
      "EmergencyContact": "Lily Adams | +1-202-555-0152"
    },
    {
      "PatientCode": "PT0004",
      "FullName": "Isabella Moore",
      "DateOfBirth": "1983-04-04",
      "Gender": "Female",
      "NationalId": "868592346712",
      "Phone": "+1-202-555-0103",
      "Address": "123 Maple Avenue, Brookfield",
      "InsuranceNumber": "690415647040",
      "EmergencyContact": "Jack Nelson | +1-202-555-0153"
    },
    {
      "PatientCode": "PT0005",
      "FullName": "Elijah Harris",
      "DateOfBirth": "1984-05-05",
      "Gender": "Male",
      "NationalId": "866676378267",
      "Phone": "+1-202-555-0104",
      "Address": "124 Maple Avenue, Brookfield",
      "InsuranceNumber": "698416027782",
      "EmergencyContact": "Sofia Mitchell | +1-202-555-0154"
    },
    {
      "PatientCode": "PT0006",
      "FullName": "Grace Robinson",
      "DateOfBirth": "1985-06-06",
      "Gender": "Female",
      "NationalId": "822011291051",
      "Phone": "+1-202-555-0105",
      "Address": "125 Maple Avenue, Brookfield",
      "InsuranceNumber": "695712608727",
      "EmergencyContact": "Samuel Roberts | +1-202-555-0155"
    },
    {
      "PatientCode": "PT0007",
      "FullName": "Lucas Walker",
      "DateOfBirth": "1986-07-07",
      "Gender": "Male",
      "NationalId": "832864885729",
      "Phone": "+1-202-555-0106",
      "Address": "126 Maple Avenue, Brookfield",
      "InsuranceNumber": "607814358426",
      "EmergencyContact": "Ella Turner | +1-202-555-0156"
    },
    {
      "PatientCode": "PT0008",
      "FullName": "Chloe Wright",
      "DateOfBirth": "1987-08-08",
      "Gender": "Female",
      "NationalId": "854024319148",
      "Phone": "+1-202-555-0107",
      "Address": "127 Maple Avenue, Brookfield",
      "InsuranceNumber": "692241151450",
      "EmergencyContact": "Daniel Phillips | +1-202-555-0157"
    },
    {
      "PatientCode": "PT0009",
      "FullName": "Henry Scott",
      "DateOfBirth": "1988-09-09",
      "Gender": "Male",
      "NationalId": "840464782556",
      "Phone": "+1-202-555-0108",
      "Address": "128 Maple Avenue, Brookfield",
      "InsuranceNumber": "618311018578",
      "EmergencyContact": "Maya Campbell | +1-202-555-0158"
    },
    {
      "PatientCode": "PT0010",
      "FullName": "Lily Adams",
      "DateOfBirth": "1989-10-10",
      "Gender": "Female",
      "NationalId": "815760862459",
      "Phone": "+1-202-555-0109",
      "Address": "129 Maple Avenue, Brookfield",
      "InsuranceNumber": "638726841655",
      "EmergencyContact": "Leo Parker | +1-202-555-0159"
    },
    {
      "PatientCode": "PT0011",
      "FullName": "Jack Nelson",
      "DateOfBirth": "1990-11-11",
      "Gender": "Male",
      "NationalId": "892522771457",
      "Phone": "+1-202-555-0110",
      "Address": "130 Maple Avenue, Brookfield",
      "InsuranceNumber": "680054304869",
      "EmergencyContact": "Lucy Evans | +1-202-555-0160"
    },
    {
      "PatientCode": "PT0012",
      "FullName": "Sofia Mitchell",
      "DateOfBirth": "1991-12-12",
      "Gender": "Female",
      "NationalId": "826848314859",
      "Phone": "+1-202-555-0111",
      "Address": "131 Maple Avenue, Brookfield",
      "InsuranceNumber": "644258413855",
      "EmergencyContact": "Ethan Edwards | +1-202-555-0161"
    },
    {
      "PatientCode": "PT0013",
      "FullName": "Samuel Roberts",
      "DateOfBirth": "1992-01-13",
      "Gender": "Male",
      "NationalId": "808218286782",
      "Phone": "+1-202-555-0112",
      "Address": "132 Maple Avenue, Brookfield",
      "InsuranceNumber": "622488795881",
      "EmergencyContact": "Zoe Collins | +1-202-555-0162"
    },
    {
      "PatientCode": "PT0014",
      "FullName": "Ella Turner",
      "DateOfBirth": "1993-02-14",
      "Gender": "Female",
      "NationalId": "875853388947",
      "Phone": "+1-202-555-0113",
      "Address": "133 Maple Avenue, Brookfield",
      "InsuranceNumber": "692517589949",
      "EmergencyContact": "Alexander Stewart | +1-202-555-0163"
    },
    {
      "PatientCode": "PT0015",
      "FullName": "Daniel Phillips",
      "DateOfBirth": "1994-03-15",
      "Gender": "Male",
      "NationalId": "892760813139",
      "Phone": "+1-202-555-0114",
      "Address": "134 Maple Avenue, Brookfield",
      "InsuranceNumber": "687904576421",
      "EmergencyContact": "Emily Morris | +1-202-555-0164"
    },
    {
      "PatientCode": "PT0016",
      "FullName": "Maya Campbell",
      "DateOfBirth": "1995-04-16",
      "Gender": "Female",
      "NationalId": "829983075566",
      "Phone": "+1-202-555-0115",
      "Address": "135 Maple Avenue, Brookfield",
      "InsuranceNumber": "611860120795",
      "EmergencyContact": "Jacob Rogers | +1-202-555-0165"
    },
    {
      "PatientCode": "PT0017",
      "FullName": "Leo Parker",
      "DateOfBirth": "1996-05-17",
      "Gender": "Male",
      "NationalId": "805153841590",
      "Phone": "+1-202-555-0116",
      "Address": "136 Maple Avenue, Brookfield",
      "InsuranceNumber": "628779823851",
      "EmergencyContact": "Hannah Reed | +1-202-555-0166"
    },
    {
      "PatientCode": "PT0018",
      "FullName": "Lucy Evans",
      "DateOfBirth": "1997-06-18",
      "Gender": "Female",
      "NationalId": "828898201329",
      "Phone": "+1-202-555-0117",
      "Address": "137 Maple Avenue, Brookfield",
      "InsuranceNumber": "610469209143",
      "EmergencyContact": "Oscar Cook | +1-202-555-0167"
    },
    {
      "PatientCode": "PT0019",
      "FullName": "Ethan Edwards",
      "DateOfBirth": "1998-07-19",
      "Gender": "Male",
      "NationalId": "811488994521",
      "Phone": "+1-202-555-0118",
      "Address": "138 Maple Avenue, Brookfield",
      "InsuranceNumber": "680764336303",
      "EmergencyContact": "Alice Morgan | +1-202-555-0168"
    },
    {
      "PatientCode": "PT0020",
      "FullName": "Zoe Collins",
      "DateOfBirth": "1999-08-20",
      "Gender": "Female",
      "NationalId": "844273125622",
      "Phone": "+1-202-555-0119",
      "Address": "139 Maple Avenue, Brookfield",
      "InsuranceNumber": "600599932082",
      "EmergencyContact": "Thomas Bell | +1-202-555-0169"
    },
    {
      "PatientCode": "PT0021",
      "FullName": "Alexander Stewart",
      "DateOfBirth": "2000-09-21",
      "Gender": "Male",
      "NationalId": "877735822708",
      "Phone": "+1-202-555-0120",
      "Address": "140 Maple Avenue, Brookfield",
      "InsuranceNumber": "676296564038",
      "EmergencyContact": "Ruby Murphy | +1-202-555-0170"
    },
    {
      "PatientCode": "PT0022",
      "FullName": "Emily Morris",
      "DateOfBirth": "2001-10-22",
      "Gender": "Female",
      "NationalId": "827661611889",
      "Phone": "+1-202-555-0121",
      "Address": "141 Maple Avenue, Brookfield",
      "InsuranceNumber": "684945258328",
      "EmergencyContact": "Arthur Bailey | +1-202-555-0171"
    },
    {
      "PatientCode": "PT0023",
      "FullName": "Jacob Rogers",
      "DateOfBirth": "2002-11-23",
      "Gender": "Male",
      "NationalId": "828506626201",
      "Phone": "+1-202-555-0122",
      "Address": "142 Maple Avenue, Brookfield",
      "InsuranceNumber": "632403571609",
      "EmergencyContact": "Freya Cooper | +1-202-555-0172"
    },
    {
      "PatientCode": "PT0024",
      "FullName": "Hannah Reed",
      "DateOfBirth": "2003-12-24",
      "Gender": "Female",
      "NationalId": "827013475782",
      "Phone": "+1-202-555-0123",
      "Address": "143 Maple Avenue, Brookfield",
      "InsuranceNumber": "628335979057",
      "EmergencyContact": "Oliver Bennett | +1-202-555-0173"
    },
    {
      "PatientCode": "PT0025",
      "FullName": "Oscar Cook",
      "DateOfBirth": "2004-01-25",
      "Gender": "Male",
      "NationalId": "880459771372",
      "Phone": "+1-202-555-0124",
      "Address": "144 Maple Avenue, Brookfield",
      "InsuranceNumber": "694712311505",
      "EmergencyContact": "Ava Thompson | +1-202-555-0174"
    },
    {
      "PatientCode": "PT0026",
      "FullName": "Alice Morgan",
      "DateOfBirth": "2005-02-01",
      "Gender": "Female",
      "NationalId": "867656765422",
      "Phone": "+1-202-555-0125",
      "Address": "145 Maple Avenue, Brookfield",
      "InsuranceNumber": "635342793900",
      "EmergencyContact": "Noah Anderson | +1-202-555-0175"
    },
    {
      "PatientCode": "PT0027",
      "FullName": "Thomas Bell",
      "DateOfBirth": "2006-03-02",
      "Gender": "Male",
      "NationalId": "842516529017",
      "Phone": "+1-202-555-0126",
      "Address": "146 Maple Avenue, Brookfield",
      "InsuranceNumber": "689938767404",
      "EmergencyContact": "Isabella Moore | +1-202-555-0176"
    },
    {
      "PatientCode": "PT0028",
      "FullName": "Ruby Murphy",
      "DateOfBirth": "2007-04-03",
      "Gender": "Female",
      "NationalId": "828626510174",
      "Phone": "+1-202-555-0127",
      "Address": "147 Maple Avenue, Brookfield",
      "InsuranceNumber": "682322628683",
      "EmergencyContact": "Elijah Harris | +1-202-555-0177"
    },
    {
      "PatientCode": "PT0029",
      "FullName": "Arthur Bailey",
      "DateOfBirth": "2008-05-04",
      "Gender": "Male",
      "NationalId": "805052842686",
      "Phone": "+1-202-555-0128",
      "Address": "148 Maple Avenue, Brookfield",
      "InsuranceNumber": "690939514842",
      "EmergencyContact": "Grace Robinson | +1-202-555-0178"
    },
    {
      "PatientCode": "PT0030",
      "FullName": "Freya Cooper",
      "DateOfBirth": "2009-06-05",
      "Gender": "Female",
      "NationalId": "841202849074",
      "Phone": "+1-202-555-0129",
      "Address": "149 Maple Avenue, Brookfield",
      "InsuranceNumber": "631897250117",
      "EmergencyContact": "Lucas Walker | +1-202-555-0179"
    }
  ],
  "Encounters": [
    {
      "PatientId": 1,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 2,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 3,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 4,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 5,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 6,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 7,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 8,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 9,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 10,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 11,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 12,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 13,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 14,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 15,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 16,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 17,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 18,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 19,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 20,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 21,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 22,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 23,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 24,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 25,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 26,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 27,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 28,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 29,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 30,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 1,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 2,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 3,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 4,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 5,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 6,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 7,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 8,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 9,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 10,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 11,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 12,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 13,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 14,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 15,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 16,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 17,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 18,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 19,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 20,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 21,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 22,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 23,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 24,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 25,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 26,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 27,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 28,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 29,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 30,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    }
  ],
  "MedicalRecords": [
    {
      "EncounterId": 1,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 2,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 3,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 4,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 5,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 6,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 7,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 8,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 9,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 10,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 11,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 12,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 13,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 14,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 15,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 16,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 17,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 18,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 19,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 20,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 21,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 22,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 23,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 24,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 25,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "Penicillin",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 26,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 27,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 28,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 29,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 30,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 31,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 32,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 33,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 34,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 35,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 36,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 37,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 38,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 39,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 40,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 41,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 42,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 43,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 44,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 45,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 46,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 47,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 48,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 49,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "Penicillin",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 50,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 51,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 52,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 53,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 54,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 55,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 56,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 57,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 58,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 59,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 60,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    }
  ],
  "Prescriptions": [
    {
      "RecordId": 1,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 2,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 3,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 4,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 5,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 6,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 7,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 8,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 9,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 10,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 11,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 12,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 13,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 14,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 15,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 16,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 17,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 18,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 19,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 20,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 21,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 22,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 23,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 24,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 25,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 26,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 27,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 28,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 29,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 30,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 31,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 32,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 33,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 34,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 35,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 36,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 37,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 38,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 39,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 40,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    }
  ],
  "PrescriptionItems": [
    {
      "PrescriptionId": 1,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 1,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 2,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 2,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 3,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 3,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 4,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 4,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 5,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 5,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 6,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 6,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 7,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 7,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 8,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 8,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 9,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 9,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 10,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 10,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 11,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 11,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 12,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 12,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 13,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 13,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 14,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 14,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 15,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 15,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 16,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 16,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 17,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 17,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 18,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 18,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 19,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 19,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 20,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 20,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 21,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 21,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 22,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 22,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 23,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 23,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 24,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 24,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 25,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 25,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 26,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 26,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 27,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 27,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 28,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 28,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 29,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 29,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 30,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 30,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 31,
      "DepartmentId": 2,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 31,
      "DepartmentId": 2,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 32,
      "DepartmentId": 3,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 32,
      "DepartmentId": 3,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 33,
      "DepartmentId": 4,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 33,
      "DepartmentId": 4,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 34,
      "DepartmentId": 5,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 34,
      "DepartmentId": 5,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 35,
      "DepartmentId": 1,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 35,
      "DepartmentId": 1,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 36,
      "DepartmentId": 2,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 36,
      "DepartmentId": 2,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 37,
      "DepartmentId": 3,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 37,
      "DepartmentId": 3,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 38,
      "DepartmentId": 4,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 38,
      "DepartmentId": 4,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 39,
      "DepartmentId": 5,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 39,
      "DepartmentId": 5,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 40,
      "DepartmentId": 1,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 40,
      "DepartmentId": 1,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    }
  ],
  "LabOrders": [
    {
      "EncounterId": 1,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 2,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 3,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 4,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 5,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 6,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 7,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 8,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 9,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 10,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 11,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 12,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 13,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 14,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 15,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 16,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 17,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 18,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 19,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 20,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 21,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 22,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 23,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 24,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 25,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 26,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 27,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 28,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 29,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 30,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    }
  ],
  "LabResults": [
    {
      "LabOrderId": 1,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 2,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 3,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 4,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 5,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 6,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 7,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 8,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 9,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 10,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 11,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 12,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 13,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 14,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 15,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 16,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 17,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 18,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 19,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 20,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 21,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 22,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 23,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 24,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 25,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 26,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 27,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 28,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 29,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 30,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    }
  ]
}
'@ | ConvertFrom-Json
$dataset.PSObject.Properties.Remove('UserDepartments')
$transaction=$conn.BeginTransaction()
try {
 foreach($table in $dataset.PSObject.Properties) {
    $name=$table.Name
    $rowNumber=0
    foreach($row in $table.Value) {
        $rowNumber++
        $cmd=$conn.CreateCommand();$cmd.Transaction=$transaction
        $columns=@();$parameters=@();$n=0
        foreach($property in $row.PSObject.Properties) {
            $column=$property.Name; $parameter='@p'+$n; $n++
            $meta=$conn.CreateCommand();$meta.Transaction=$transaction
            $meta.CommandText="SELECT TYPE_NAME(system_type_id),max_length FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.$name') AND name=N'$column'"
            $reader=$meta.ExecuteReader();if(-not $reader.Read()){throw "Column missing: $name.$column"}
            $type=$reader.GetString(0);$length=[int]$reader.GetValue(1);$reader.Close();$meta.Dispose()
            switch($type) {
                'int' {$param=$cmd.Parameters.Add($parameter,[System.Data.SqlDbType]::Int);$param.Value=[int]$property.Value}
                'date' {$param=$cmd.Parameters.Add($parameter,[System.Data.SqlDbType]::Date);$param.Value=[datetime]::ParseExact($property.Value,'yyyy-MM-dd',[System.Globalization.CultureInfo]::InvariantCulture)}
                'nvarchar' {$param=$cmd.Parameters.Add($parameter,[System.Data.SqlDbType]::NVarChar,($length/2));$param.Value=[string]$property.Value}
                'varchar' {$param=$cmd.Parameters.Add($parameter,[System.Data.SqlDbType]::VarChar,$length);$param.Value=[string]$property.Value}
                default {throw "Unsupported seed type: $type"}
            }
            $columns+="[$column]";$parameters+=$parameter
        }
        $primaryKey=$keyNames[$name]
        $assignments=@()
        for($j=0;$j -lt $columns.Count;$j++) {
            if($columns[$j] -ne "[$primaryKey]" -and $columns[$j] -notin @("[DepartmentId]","[PatientId]","[DoctorId]","[EncounterId]","[RecordId]","[PrescriptionId]","[LabOrderId]")) { $assignments+=($columns[$j]+'='+$parameters[$j]) }
        }
        $targetId=$rowNumber
        if($row.PSObject.Properties.Name -contains $primaryKey) { $targetId=[int]$row.$primaryKey }
        $idParameter=$cmd.Parameters.Add('@targetId',[System.Data.SqlDbType]::Int);$idParameter.Value=$targetId
        $cmd.CommandText="UPDATE dbo.[$name] SET "+($assignments -join ',')+" WHERE [$primaryKey]=@targetId;"
        $affected=$cmd.ExecuteNonQuery()
        if($affected -ne 1) { throw "Expected one original seed row in $name with ID $targetId. Transaction rolled back." }
        $cmd.Dispose()
    }
    Write-Host "Updated $name : $(@($table.Value).Count) rows"
 }
 $transaction.Commit()
} catch { $transaction.Rollback(); throw } finally { $transaction.Dispose();$conn.Close() }

Write-Host 'Update complete. Existing encryption, keys and Ledger history were preserved.'

    return
}
if ($alreadyExists -eq 1) { $conn.Close(); throw 'HospitalZT already exists. Stopping without overwriting it. Inspect the previous setup result before continuing.' }
Run-SqlFile '00_create_database.sql'
$conn.ChangeDatabase('HospitalZT')
Run-SqlFile '01_reference_tables.sql'
$departmentCommand=$conn.CreateCommand()
$departmentCommand.CommandText=@'
UPDATE dbo.Departments SET Location=N'Building A - Floor 1',Phone='+1-202-555-0111' WHERE DepartmentId=1;
UPDATE dbo.Departments SET Location=N'Building A - Floor 2',Phone='+1-202-555-0112' WHERE DepartmentId=2;
UPDATE dbo.Departments SET Location=N'Building B - Floor 1',Phone='+1-202-555-0113' WHERE DepartmentId=3;
UPDATE dbo.Departments SET Location=N'Building B - Floor 2',Phone='+1-202-555-0114' WHERE DepartmentId=4;
UPDATE dbo.Departments SET Location=N'Building C - Floor 1',Phone='+1-202-555-0115' WHERE DepartmentId=5;
'@
[void]$departmentCommand.ExecuteNonQuery();$departmentCommand.Dispose()

$cert=New-SelfSignedCertificate -Subject 'HospitalZT-AlwaysEncrypted-Lab' -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable -Type DocumentEncryptionCert -KeyUsage KeyEncipherment -KeySpec KeyExchange -KeyLength 2048
$keyPath='CurrentUser/My/'+$cert.Thumbprint
$provider=[System.Data.SqlClient.SqlColumnEncryptionCertificateStoreProvider]::new()
$cek=New-Object byte[] 32
$rng=[System.Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($cek); $rng.Dispose()
$wrapped=$provider.EncryptColumnEncryptionKey($keyPath,'RSA_OAEP',$cek)
[Array]::Clear($cek,0,$cek.Length)
$hex='0x'+[BitConverter]::ToString($wrapped).Replace('-','')
$cmd=$conn.CreateCommand()
$cmd.CommandText="CREATE COLUMN MASTER KEY CMK_Hospital WITH (KEY_STORE_PROVIDER_NAME=N'MSSQL_CERTIFICATE_STORE',KEY_PATH=N'$keyPath'); CREATE COLUMN ENCRYPTION KEY CEK_Hospital WITH VALUES (COLUMN_MASTER_KEY=CMK_Hospital,ALGORITHM='RSA_OAEP',ENCRYPTED_VALUE=$hex);"
[void]$cmd.ExecuteNonQuery();$cmd.Dispose()
Run-SqlFile '03_clinical_encrypted_ledger.sql'
$conn.Close()
$b["Initial Catalog"]='HospitalZT';$b['Column Encryption Setting']='Enabled'
$conn=[System.Data.SqlClient.SqlConnection]::new($b.get_ConnectionString());$conn.Open()
# Fictional English training data embedded for consistent setup on all team machines.
$dataset = @'
{
  "Departments": [
    {
      "DepartmentId": 1,
      "DepartmentCode": "IM",
      "DepartmentName": "Internal Medicine",
      "Location": "Building A - Floor 1",
      "Phone": "+1-202-555-0111"
    },
    {
      "DepartmentId": 2,
      "DepartmentCode": "SUR",
      "DepartmentName": "Surgery",
      "Location": "Building A - Floor 2",
      "Phone": "+1-202-555-0112"
    },
    {
      "DepartmentId": 3,
      "DepartmentCode": "PED",
      "DepartmentName": "Pediatrics",
      "Location": "Building B - Floor 1",
      "Phone": "+1-202-555-0113"
    },
    {
      "DepartmentId": 4,
      "DepartmentCode": "OBG",
      "DepartmentName": "Obstetrics and Gynecology",
      "Location": "Building B - Floor 2",
      "Phone": "+1-202-555-0114"
    },
    {
      "DepartmentId": 5,
      "DepartmentCode": "CAR",
      "DepartmentName": "Cardiology",
      "Location": "Building C - Floor 1",
      "Phone": "+1-202-555-0115"
    }
  ],
  "Staff": [
    {
      "StaffId": 1,
      "DepartmentId": 1,
      "StaffCode": "ST001",
      "FullName": "James Carter",
      "JobTitle": "Doctor",
      "Email": "james.carter@example.com"
    },
    {
      "StaffId": 2,
      "DepartmentId": 1,
      "StaffCode": "ST002",
      "FullName": "Emma Wilson",
      "JobTitle": "Nurse",
      "Email": "emma.wilson@example.com"
    },
    {
      "StaffId": 3,
      "DepartmentId": 2,
      "StaffCode": "ST003",
      "FullName": "Michael Brown",
      "JobTitle": "Doctor",
      "Email": "michael.brown@example.com"
    },
    {
      "StaffId": 4,
      "DepartmentId": 2,
      "StaffCode": "ST004",
      "FullName": "Olivia Davis",
      "JobTitle": "Nurse",
      "Email": "olivia.davis@example.com"
    },
    {
      "StaffId": 5,
      "DepartmentId": 3,
      "StaffCode": "ST005",
      "FullName": "William Miller",
      "JobTitle": "Doctor",
      "Email": "william.miller@example.com"
    },
    {
      "StaffId": 6,
      "DepartmentId": 3,
      "StaffCode": "ST006",
      "FullName": "Sophia Taylor",
      "JobTitle": "Nurse",
      "Email": "sophia.taylor@example.com"
    },
    {
      "StaffId": 7,
      "DepartmentId": 4,
      "StaffCode": "ST007",
      "FullName": "Charlotte Lee",
      "JobTitle": "Doctor",
      "Email": "charlotte.lee@example.com"
    },
    {
      "StaffId": 8,
      "DepartmentId": 4,
      "StaffCode": "ST008",
      "FullName": "Amelia Martin",
      "JobTitle": "Nurse",
      "Email": "amelia.martin@example.com"
    },
    {
      "StaffId": 9,
      "DepartmentId": 5,
      "StaffCode": "ST009",
      "FullName": "Benjamin Clark",
      "JobTitle": "Doctor",
      "Email": "benjamin.clark@example.com"
    },
    {
      "StaffId": 10,
      "DepartmentId": 5,
      "StaffCode": "ST010",
      "FullName": "Mia Lewis",
      "JobTitle": "Nurse",
      "Email": "mia.lewis@example.com"
    }
  ],
  "Medications": [
    {
      "MedicationId": 1,
      "MedicationCode": "MED001",
      "MedicationName": "Paracetamol",
      "Strength": "500 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 2,
      "MedicationCode": "MED002",
      "MedicationName": "Amoxicillin",
      "Strength": "500 mg",
      "Unit": "Capsule"
    },
    {
      "MedicationId": 3,
      "MedicationCode": "MED003",
      "MedicationName": "Cetirizine",
      "Strength": "10 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 4,
      "MedicationCode": "MED004",
      "MedicationName": "Omeprazole",
      "Strength": "20 mg",
      "Unit": "Capsule"
    },
    {
      "MedicationId": 5,
      "MedicationCode": "MED005",
      "MedicationName": "Ibuprofen",
      "Strength": "200 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 6,
      "MedicationCode": "MED006",
      "MedicationName": "Metformin",
      "Strength": "500 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 7,
      "MedicationCode": "MED007",
      "MedicationName": "Amlodipine",
      "Strength": "5 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 8,
      "MedicationCode": "MED008",
      "MedicationName": "Losartan",
      "Strength": "50 mg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 9,
      "MedicationCode": "MED009",
      "MedicationName": "Folic acid",
      "Strength": "400 mcg",
      "Unit": "Tablet"
    },
    {
      "MedicationId": 10,
      "MedicationCode": "MED010",
      "MedicationName": "Oral rehydration salts",
      "Strength": "Standard sachet",
      "Unit": "Sachet"
    }
  ],
  "UserDepartments": [
    {
      "DatabaseUser": "doctor_im",
      "DepartmentId": 1
    },
    {
      "DatabaseUser": "doctor_sur",
      "DepartmentId": 2
    },
    {
      "DatabaseUser": "doctor_ped",
      "DepartmentId": 3
    },
    {
      "DatabaseUser": "doctor_obg",
      "DepartmentId": 4
    },
    {
      "DatabaseUser": "doctor_car",
      "DepartmentId": 5
    }
  ],
  "Patients": [
    {
      "PatientCode": "PT0001",
      "FullName": "Oliver Bennett",
      "DateOfBirth": "1980-01-01",
      "Gender": "Male",
      "NationalId": "805537197893",
      "Phone": "+1-202-555-0100",
      "Address": "120 Maple Avenue, Brookfield",
      "InsuranceNumber": "664680368871",
      "EmergencyContact": "Chloe Wright | +1-202-555-0150"
    },
    {
      "PatientCode": "PT0002",
      "FullName": "Ava Thompson",
      "DateOfBirth": "1981-02-02",
      "Gender": "Female",
      "NationalId": "802125173183",
      "Phone": "+1-202-555-0101",
      "Address": "121 Maple Avenue, Brookfield",
      "InsuranceNumber": "640704478310",
      "EmergencyContact": "Henry Scott | +1-202-555-0151"
    },
    {
      "PatientCode": "PT0003",
      "FullName": "Noah Anderson",
      "DateOfBirth": "1982-03-03",
      "Gender": "Male",
      "NationalId": "805881351019",
      "Phone": "+1-202-555-0102",
      "Address": "122 Maple Avenue, Brookfield",
      "InsuranceNumber": "614469123235",
      "EmergencyContact": "Lily Adams | +1-202-555-0152"
    },
    {
      "PatientCode": "PT0004",
      "FullName": "Isabella Moore",
      "DateOfBirth": "1983-04-04",
      "Gender": "Female",
      "NationalId": "868592346712",
      "Phone": "+1-202-555-0103",
      "Address": "123 Maple Avenue, Brookfield",
      "InsuranceNumber": "690415647040",
      "EmergencyContact": "Jack Nelson | +1-202-555-0153"
    },
    {
      "PatientCode": "PT0005",
      "FullName": "Elijah Harris",
      "DateOfBirth": "1984-05-05",
      "Gender": "Male",
      "NationalId": "866676378267",
      "Phone": "+1-202-555-0104",
      "Address": "124 Maple Avenue, Brookfield",
      "InsuranceNumber": "698416027782",
      "EmergencyContact": "Sofia Mitchell | +1-202-555-0154"
    },
    {
      "PatientCode": "PT0006",
      "FullName": "Grace Robinson",
      "DateOfBirth": "1985-06-06",
      "Gender": "Female",
      "NationalId": "822011291051",
      "Phone": "+1-202-555-0105",
      "Address": "125 Maple Avenue, Brookfield",
      "InsuranceNumber": "695712608727",
      "EmergencyContact": "Samuel Roberts | +1-202-555-0155"
    },
    {
      "PatientCode": "PT0007",
      "FullName": "Lucas Walker",
      "DateOfBirth": "1986-07-07",
      "Gender": "Male",
      "NationalId": "832864885729",
      "Phone": "+1-202-555-0106",
      "Address": "126 Maple Avenue, Brookfield",
      "InsuranceNumber": "607814358426",
      "EmergencyContact": "Ella Turner | +1-202-555-0156"
    },
    {
      "PatientCode": "PT0008",
      "FullName": "Chloe Wright",
      "DateOfBirth": "1987-08-08",
      "Gender": "Female",
      "NationalId": "854024319148",
      "Phone": "+1-202-555-0107",
      "Address": "127 Maple Avenue, Brookfield",
      "InsuranceNumber": "692241151450",
      "EmergencyContact": "Daniel Phillips | +1-202-555-0157"
    },
    {
      "PatientCode": "PT0009",
      "FullName": "Henry Scott",
      "DateOfBirth": "1988-09-09",
      "Gender": "Male",
      "NationalId": "840464782556",
      "Phone": "+1-202-555-0108",
      "Address": "128 Maple Avenue, Brookfield",
      "InsuranceNumber": "618311018578",
      "EmergencyContact": "Maya Campbell | +1-202-555-0158"
    },
    {
      "PatientCode": "PT0010",
      "FullName": "Lily Adams",
      "DateOfBirth": "1989-10-10",
      "Gender": "Female",
      "NationalId": "815760862459",
      "Phone": "+1-202-555-0109",
      "Address": "129 Maple Avenue, Brookfield",
      "InsuranceNumber": "638726841655",
      "EmergencyContact": "Leo Parker | +1-202-555-0159"
    },
    {
      "PatientCode": "PT0011",
      "FullName": "Jack Nelson",
      "DateOfBirth": "1990-11-11",
      "Gender": "Male",
      "NationalId": "892522771457",
      "Phone": "+1-202-555-0110",
      "Address": "130 Maple Avenue, Brookfield",
      "InsuranceNumber": "680054304869",
      "EmergencyContact": "Lucy Evans | +1-202-555-0160"
    },
    {
      "PatientCode": "PT0012",
      "FullName": "Sofia Mitchell",
      "DateOfBirth": "1991-12-12",
      "Gender": "Female",
      "NationalId": "826848314859",
      "Phone": "+1-202-555-0111",
      "Address": "131 Maple Avenue, Brookfield",
      "InsuranceNumber": "644258413855",
      "EmergencyContact": "Ethan Edwards | +1-202-555-0161"
    },
    {
      "PatientCode": "PT0013",
      "FullName": "Samuel Roberts",
      "DateOfBirth": "1992-01-13",
      "Gender": "Male",
      "NationalId": "808218286782",
      "Phone": "+1-202-555-0112",
      "Address": "132 Maple Avenue, Brookfield",
      "InsuranceNumber": "622488795881",
      "EmergencyContact": "Zoe Collins | +1-202-555-0162"
    },
    {
      "PatientCode": "PT0014",
      "FullName": "Ella Turner",
      "DateOfBirth": "1993-02-14",
      "Gender": "Female",
      "NationalId": "875853388947",
      "Phone": "+1-202-555-0113",
      "Address": "133 Maple Avenue, Brookfield",
      "InsuranceNumber": "692517589949",
      "EmergencyContact": "Alexander Stewart | +1-202-555-0163"
    },
    {
      "PatientCode": "PT0015",
      "FullName": "Daniel Phillips",
      "DateOfBirth": "1994-03-15",
      "Gender": "Male",
      "NationalId": "892760813139",
      "Phone": "+1-202-555-0114",
      "Address": "134 Maple Avenue, Brookfield",
      "InsuranceNumber": "687904576421",
      "EmergencyContact": "Emily Morris | +1-202-555-0164"
    },
    {
      "PatientCode": "PT0016",
      "FullName": "Maya Campbell",
      "DateOfBirth": "1995-04-16",
      "Gender": "Female",
      "NationalId": "829983075566",
      "Phone": "+1-202-555-0115",
      "Address": "135 Maple Avenue, Brookfield",
      "InsuranceNumber": "611860120795",
      "EmergencyContact": "Jacob Rogers | +1-202-555-0165"
    },
    {
      "PatientCode": "PT0017",
      "FullName": "Leo Parker",
      "DateOfBirth": "1996-05-17",
      "Gender": "Male",
      "NationalId": "805153841590",
      "Phone": "+1-202-555-0116",
      "Address": "136 Maple Avenue, Brookfield",
      "InsuranceNumber": "628779823851",
      "EmergencyContact": "Hannah Reed | +1-202-555-0166"
    },
    {
      "PatientCode": "PT0018",
      "FullName": "Lucy Evans",
      "DateOfBirth": "1997-06-18",
      "Gender": "Female",
      "NationalId": "828898201329",
      "Phone": "+1-202-555-0117",
      "Address": "137 Maple Avenue, Brookfield",
      "InsuranceNumber": "610469209143",
      "EmergencyContact": "Oscar Cook | +1-202-555-0167"
    },
    {
      "PatientCode": "PT0019",
      "FullName": "Ethan Edwards",
      "DateOfBirth": "1998-07-19",
      "Gender": "Male",
      "NationalId": "811488994521",
      "Phone": "+1-202-555-0118",
      "Address": "138 Maple Avenue, Brookfield",
      "InsuranceNumber": "680764336303",
      "EmergencyContact": "Alice Morgan | +1-202-555-0168"
    },
    {
      "PatientCode": "PT0020",
      "FullName": "Zoe Collins",
      "DateOfBirth": "1999-08-20",
      "Gender": "Female",
      "NationalId": "844273125622",
      "Phone": "+1-202-555-0119",
      "Address": "139 Maple Avenue, Brookfield",
      "InsuranceNumber": "600599932082",
      "EmergencyContact": "Thomas Bell | +1-202-555-0169"
    },
    {
      "PatientCode": "PT0021",
      "FullName": "Alexander Stewart",
      "DateOfBirth": "2000-09-21",
      "Gender": "Male",
      "NationalId": "877735822708",
      "Phone": "+1-202-555-0120",
      "Address": "140 Maple Avenue, Brookfield",
      "InsuranceNumber": "676296564038",
      "EmergencyContact": "Ruby Murphy | +1-202-555-0170"
    },
    {
      "PatientCode": "PT0022",
      "FullName": "Emily Morris",
      "DateOfBirth": "2001-10-22",
      "Gender": "Female",
      "NationalId": "827661611889",
      "Phone": "+1-202-555-0121",
      "Address": "141 Maple Avenue, Brookfield",
      "InsuranceNumber": "684945258328",
      "EmergencyContact": "Arthur Bailey | +1-202-555-0171"
    },
    {
      "PatientCode": "PT0023",
      "FullName": "Jacob Rogers",
      "DateOfBirth": "2002-11-23",
      "Gender": "Male",
      "NationalId": "828506626201",
      "Phone": "+1-202-555-0122",
      "Address": "142 Maple Avenue, Brookfield",
      "InsuranceNumber": "632403571609",
      "EmergencyContact": "Freya Cooper | +1-202-555-0172"
    },
    {
      "PatientCode": "PT0024",
      "FullName": "Hannah Reed",
      "DateOfBirth": "2003-12-24",
      "Gender": "Female",
      "NationalId": "827013475782",
      "Phone": "+1-202-555-0123",
      "Address": "143 Maple Avenue, Brookfield",
      "InsuranceNumber": "628335979057",
      "EmergencyContact": "Oliver Bennett | +1-202-555-0173"
    },
    {
      "PatientCode": "PT0025",
      "FullName": "Oscar Cook",
      "DateOfBirth": "2004-01-25",
      "Gender": "Male",
      "NationalId": "880459771372",
      "Phone": "+1-202-555-0124",
      "Address": "144 Maple Avenue, Brookfield",
      "InsuranceNumber": "694712311505",
      "EmergencyContact": "Ava Thompson | +1-202-555-0174"
    },
    {
      "PatientCode": "PT0026",
      "FullName": "Alice Morgan",
      "DateOfBirth": "2005-02-01",
      "Gender": "Female",
      "NationalId": "867656765422",
      "Phone": "+1-202-555-0125",
      "Address": "145 Maple Avenue, Brookfield",
      "InsuranceNumber": "635342793900",
      "EmergencyContact": "Noah Anderson | +1-202-555-0175"
    },
    {
      "PatientCode": "PT0027",
      "FullName": "Thomas Bell",
      "DateOfBirth": "2006-03-02",
      "Gender": "Male",
      "NationalId": "842516529017",
      "Phone": "+1-202-555-0126",
      "Address": "146 Maple Avenue, Brookfield",
      "InsuranceNumber": "689938767404",
      "EmergencyContact": "Isabella Moore | +1-202-555-0176"
    },
    {
      "PatientCode": "PT0028",
      "FullName": "Ruby Murphy",
      "DateOfBirth": "2007-04-03",
      "Gender": "Female",
      "NationalId": "828626510174",
      "Phone": "+1-202-555-0127",
      "Address": "147 Maple Avenue, Brookfield",
      "InsuranceNumber": "682322628683",
      "EmergencyContact": "Elijah Harris | +1-202-555-0177"
    },
    {
      "PatientCode": "PT0029",
      "FullName": "Arthur Bailey",
      "DateOfBirth": "2008-05-04",
      "Gender": "Male",
      "NationalId": "805052842686",
      "Phone": "+1-202-555-0128",
      "Address": "148 Maple Avenue, Brookfield",
      "InsuranceNumber": "690939514842",
      "EmergencyContact": "Grace Robinson | +1-202-555-0178"
    },
    {
      "PatientCode": "PT0030",
      "FullName": "Freya Cooper",
      "DateOfBirth": "2009-06-05",
      "Gender": "Female",
      "NationalId": "841202849074",
      "Phone": "+1-202-555-0129",
      "Address": "149 Maple Avenue, Brookfield",
      "InsuranceNumber": "631897250117",
      "EmergencyContact": "Lucas Walker | +1-202-555-0179"
    }
  ],
  "Encounters": [
    {
      "PatientId": 1,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 2,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 3,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 4,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 5,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 6,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 7,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 8,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 9,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 10,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 11,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 12,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 13,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 14,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 15,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 16,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 17,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 18,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 19,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 20,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 21,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 22,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 23,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 24,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 25,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 26,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 27,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 28,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 29,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 30,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 1,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 2,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 3,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 4,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 5,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 6,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 7,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 8,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 9,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 10,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 11,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 12,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 13,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 14,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 15,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 16,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 17,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 18,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 19,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 20,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 21,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 22,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 23,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 24,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 25,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    },
    {
      "PatientId": 26,
      "DepartmentId": 2,
      "DoctorId": 3,
      "Status": "OPEN",
      "ReasonForVisit": "Postoperative follow-up"
    },
    {
      "PatientId": 27,
      "DepartmentId": 3,
      "DoctorId": 5,
      "Status": "OPEN",
      "ReasonForVisit": "Routine pediatric assessment"
    },
    {
      "PatientId": 28,
      "DepartmentId": 4,
      "DoctorId": 7,
      "Status": "OPEN",
      "ReasonForVisit": "Routine gynecology assessment"
    },
    {
      "PatientId": 29,
      "DepartmentId": 5,
      "DoctorId": 9,
      "Status": "OPEN",
      "ReasonForVisit": "Cardiology follow-up"
    },
    {
      "PatientId": 30,
      "DepartmentId": 1,
      "DoctorId": 1,
      "Status": "OPEN",
      "ReasonForVisit": "Persistent fatigue"
    }
  ],
  "MedicalRecords": [
    {
      "EncounterId": 1,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 2,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 3,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 4,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 5,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 6,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 7,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 8,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 9,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 10,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 11,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 12,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 13,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 14,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 15,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 16,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 17,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 18,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 19,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 20,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 21,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 22,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 23,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 24,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 25,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "Penicillin",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 26,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 27,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 28,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 29,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 30,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 31,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 32,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 33,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 34,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 35,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 36,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 37,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 38,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 39,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 40,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 41,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 42,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 43,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 44,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 45,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 46,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 47,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 48,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 49,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "Penicillin",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 50,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 51,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 52,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 53,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 54,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 55,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "Penicillin",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    },
    {
      "EncounterId": 56,
      "DepartmentId": 2,
      "Symptoms": "Mild discomfort around the incision",
      "Diagnosis": "Routine postoperative review",
      "TreatmentPlan": "Inspect wound, provide wound-care instructions and arrange follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Incision reviewed. No discharge noted."
    },
    {
      "EncounterId": 57,
      "DepartmentId": 3,
      "Symptoms": "Intermittent dry cough and nasal congestion",
      "Diagnosis": "Upper respiratory symptoms",
      "TreatmentPlan": "Supportive care, hydration and reassessment if symptoms persist",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Parent or caregiver provided symptom history."
    },
    {
      "EncounterId": 58,
      "DepartmentId": 4,
      "Symptoms": "Intermittent lower abdominal discomfort",
      "Diagnosis": "Pelvic discomfort under evaluation",
      "TreatmentPlan": "Review symptom history and arrange further assessment",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Symptoms and follow-up plan discussed with patient."
    },
    {
      "EncounterId": 59,
      "DepartmentId": 5,
      "Symptoms": "Brief episodes of palpitations without chest pain",
      "Diagnosis": "Palpitations under evaluation",
      "TreatmentPlan": "Review ECG and laboratory findings at follow-up",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "No chest pain reported during consultation."
    },
    {
      "EncounterId": 60,
      "DepartmentId": 1,
      "Symptoms": "Fatigue, reduced appetite and difficulty sleeping",
      "Diagnosis": "Fatigue under evaluation",
      "TreatmentPlan": "Review sleep pattern and nutrition; follow up after laboratory results",
      "Allergies": "No known drug allergies",
      "ClinicalNotes": "Patient alert and cooperative. Follow-up appointment arranged."
    }
  ],
  "Prescriptions": [
    {
      "RecordId": 1,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 2,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 3,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 4,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 5,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 6,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 7,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 8,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 9,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 10,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 11,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 12,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 13,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 14,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 15,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 16,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 17,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 18,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 19,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 20,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 21,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 22,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 23,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 24,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 25,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 26,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 27,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 28,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 29,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 30,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 31,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 32,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 33,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 34,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 35,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 36,
      "DepartmentId": 2,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 37,
      "DepartmentId": 3,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 38,
      "DepartmentId": 4,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 39,
      "DepartmentId": 5,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    },
    {
      "RecordId": 40,
      "DepartmentId": 1,
      "Instructions": "Follow the prescribing clinician instructions; contact the clinic if adverse effects occur."
    }
  ],
  "PrescriptionItems": [
    {
      "PrescriptionId": 1,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 1,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 2,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 2,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 3,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 3,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 4,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 4,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 5,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 5,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 6,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 6,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 7,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 7,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 8,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 8,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 9,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 9,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 10,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 10,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 11,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 11,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 12,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 12,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 13,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 13,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 14,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 14,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 15,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 15,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 16,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 16,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 17,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 17,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 18,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 18,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 19,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 19,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 20,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 20,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 21,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 21,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 22,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 22,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 23,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 23,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 24,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 24,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 25,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 25,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 26,
      "DepartmentId": 1,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 26,
      "DepartmentId": 1,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 27,
      "DepartmentId": 2,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 27,
      "DepartmentId": 2,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 28,
      "DepartmentId": 3,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 28,
      "DepartmentId": 3,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 29,
      "DepartmentId": 4,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 29,
      "DepartmentId": 4,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 30,
      "DepartmentId": 5,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 30,
      "DepartmentId": 5,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 31,
      "DepartmentId": 2,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 31,
      "DepartmentId": 2,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 32,
      "DepartmentId": 3,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 32,
      "DepartmentId": 3,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 33,
      "DepartmentId": 4,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 33,
      "DepartmentId": 4,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 34,
      "DepartmentId": 5,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 34,
      "DepartmentId": 5,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 35,
      "DepartmentId": 1,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 35,
      "DepartmentId": 1,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 36,
      "DepartmentId": 2,
      "MedicationName": "Paracetamol",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 36,
      "DepartmentId": 2,
      "MedicationName": "Amoxicillin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 37,
      "DepartmentId": 3,
      "MedicationName": "Cetirizine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 37,
      "DepartmentId": 3,
      "MedicationName": "Omeprazole",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 38,
      "DepartmentId": 4,
      "MedicationName": "Ibuprofen",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 38,
      "DepartmentId": 4,
      "MedicationName": "Metformin",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 39,
      "DepartmentId": 5,
      "MedicationName": "Amlodipine",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    },
    {
      "PrescriptionId": 39,
      "DepartmentId": 5,
      "MedicationName": "Losartan",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 30
    },
    {
      "PrescriptionId": 40,
      "DepartmentId": 1,
      "MedicationName": "Folic acid",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 10
    },
    {
      "PrescriptionId": 40,
      "DepartmentId": 1,
      "MedicationName": "Oral rehydration salts",
      "Dosage": "According to the signed prescription",
      "Frequency": "According to the signed prescription",
      "Duration": "Until the scheduled clinical review",
      "Quantity": 20
    }
  ],
  "LabOrders": [
    {
      "EncounterId": 1,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 2,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 3,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 4,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 5,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 6,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 7,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 8,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 9,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 10,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 11,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 12,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 13,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 14,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 15,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 16,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 17,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 18,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 19,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 20,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 21,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 22,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 23,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 24,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 25,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 26,
      "DepartmentId": 1,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 27,
      "DepartmentId": 2,
      "TestName": "C-reactive protein",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 28,
      "DepartmentId": 3,
      "TestName": "Complete blood count",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 29,
      "DepartmentId": 4,
      "TestName": "Urinalysis",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    },
    {
      "EncounterId": 30,
      "DepartmentId": 5,
      "TestName": "Thyroid-stimulating hormone",
      "ClinicalIndication": "Assessment of presenting symptoms",
      "Status": "COMPLETED"
    }
  ],
  "LabResults": [
    {
      "LabOrderId": 1,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 2,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 3,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 4,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 5,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 6,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 7,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 8,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 9,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 10,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 11,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 12,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 13,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 14,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 15,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 16,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 17,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 18,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 19,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 20,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 21,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 22,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 23,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 24,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 25,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 26,
      "DepartmentId": 1,
      "ResultValue": "Hemoglobin: 13.8 g/dL",
      "ReferenceRange": "12.0-17.5 g/dL",
      "Conclusion": "Hemoglobin within the listed reference interval"
    },
    {
      "LabOrderId": 27,
      "DepartmentId": 2,
      "ResultValue": "2.1 mg/L",
      "ReferenceRange": "0-5 mg/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 28,
      "DepartmentId": 3,
      "ResultValue": "White blood cells: 7.2 x10^9/L",
      "ReferenceRange": "4.5-13.5 x10^9/L",
      "Conclusion": "Within the listed reference interval"
    },
    {
      "LabOrderId": 29,
      "DepartmentId": 4,
      "ResultValue": "Protein: negative",
      "ReferenceRange": "Negative",
      "Conclusion": "No protein detected"
    },
    {
      "LabOrderId": 30,
      "DepartmentId": 5,
      "ResultValue": "2.3 mIU/L",
      "ReferenceRange": "0.4-4.0 mIU/L",
      "Conclusion": "Within the listed reference interval"
    }
  ]
}
'@ | ConvertFrom-Json
$dataset.PSObject.Properties.Remove('Departments')
$transaction=$conn.BeginTransaction()
try {
 foreach($table in $dataset.PSObject.Properties) {
    $name=$table.Name
    foreach($row in $table.Value) {
        $cmd=$conn.CreateCommand();$cmd.Transaction=$transaction
        $columns=@();$parameters=@();$n=0
        foreach($property in $row.PSObject.Properties) {
            $column=$property.Name; $parameter='@p'+$n; $n++
            $meta=$conn.CreateCommand();$meta.Transaction=$transaction
            $meta.CommandText="SELECT TYPE_NAME(system_type_id),max_length FROM sys.columns WHERE object_id=OBJECT_ID(N'dbo.$name') AND name=N'$column'"
            $reader=$meta.ExecuteReader();if(-not $reader.Read()){throw "Column missing: $name.$column"}
            $type=$reader.GetString(0);$length=[int]$reader.GetValue(1);$reader.Close();$meta.Dispose()
            switch($type) {
                'int' {$param=$cmd.Parameters.Add($parameter,[System.Data.SqlDbType]::Int);$param.Value=[int]$property.Value}
                'date' {$param=$cmd.Parameters.Add($parameter,[System.Data.SqlDbType]::Date);$param.Value=[datetime]::ParseExact($property.Value,'yyyy-MM-dd',[System.Globalization.CultureInfo]::InvariantCulture)}
                'nvarchar' {$param=$cmd.Parameters.Add($parameter,[System.Data.SqlDbType]::NVarChar,($length/2));$param.Value=[string]$property.Value}
                'varchar' {$param=$cmd.Parameters.Add($parameter,[System.Data.SqlDbType]::VarChar,$length);$param.Value=[string]$property.Value}
                default {throw "Unsupported seed type: $type"}
            }
            $columns+="[$column]";$parameters+=$parameter
        }
        $cmd.CommandText="INSERT dbo.[$name] ("+($columns -join ',')+") VALUES ("+($parameters -join ',')+");"
        [void]$cmd.ExecuteNonQuery();$cmd.Dispose()
    }
    Write-Host "Seeded $name : $(@($table.Value).Count) rows"
 }
 $transaction.Commit()
} catch { $transaction.Rollback(); throw } finally { $transaction.Dispose();$conn.Close() }
Write-Host 'SUCCESS: HospitalZT created and seeded. Connect SSMS to localhost,14330.'
Write-Host "Certificate thumbprint: $($cert.Thumbprint). Preserve and back up its private key securely."
Write-Host 'TDE, RLS, real doctor logins, key backup and external digest verification are still team tasks.'
$password=$null;$b["Password"]=''
