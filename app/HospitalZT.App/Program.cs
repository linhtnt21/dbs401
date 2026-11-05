using System.Data;
using Microsoft.Data.SqlClient;

var connectionString = Environment.GetEnvironmentVariable("HOSPITALZT_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
    Console.Error.WriteLine("Set HOSPITALZT_CONNECTION_STRING in PowerShell, then run again.");
    return;
}

Console.WriteLine("Enter a valid EncounterId/DepartmentId pair and synthetic demo text.");
Console.Write("EncounterId: ");
if (!int.TryParse(Console.ReadLine(), out var encounterId))
{
    Console.Error.WriteLine("EncounterId must be a number.");
    return;
}

Console.Write("DepartmentId: ");
if (!int.TryParse(Console.ReadLine(), out var departmentId))
{
    Console.Error.WriteLine("DepartmentId must be a number.");
    return;
}

Console.Write("Tên xét nghiệm (TestName): ");
var testName = Console.ReadLine()?.Trim() ?? "";
Console.Write("Chỉ định (ClinicalIndication): ");
var indication = Console.ReadLine()?.Trim() ?? "";
if (string.IsNullOrWhiteSpace(testName) || testName.Length > 100 ||
    string.IsNullOrWhiteSpace(indication) || indication.Length > 500)
{
    Console.Error.WriteLine("Tên xét nghiệm cần 1-100 ký tự; chỉ định cần 1-500 ký tự.");
    return;
}

try
{
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();

    // Find a medical record belonging to the exact encounter/department entered.
    int recordId;
    await using (var lookup = connection.CreateCommand())
    {
        lookup.CommandText = @"
            SELECT TOP (1) RecordId
            FROM dbo.MedicalRecords
            WHERE EncounterId = @EncounterId AND DepartmentId = @DepartmentId
            ORDER BY RecordId;";
        lookup.Parameters.Add("@EncounterId", SqlDbType.Int).Value = encounterId;
        lookup.Parameters.Add("@DepartmentId", SqlDbType.Int).Value = departmentId;

        await using var reader = await lookup.ExecuteReaderAsync();
        if (!await reader.ReadAsync())
            throw new InvalidOperationException("No MedicalRecords row matches that EncounterId/DepartmentId pair. Check dbo.Encounters and try again.");
        recordId = reader.GetInt32(0);
    }

    using var transaction = connection.BeginTransaction();
    try
    {
        var prescriptionId = await InsertIdAsync(connection, transaction, @"
            INSERT dbo.Prescriptions (RecordId, DepartmentId, Instructions)
            OUTPUT INSERTED.PrescriptionId
            VALUES (@RecordId, @DepartmentId, @Instructions);",
            parameters =>
            {
                parameters.Add("@RecordId", SqlDbType.Int).Value = recordId;
                parameters.Add("@DepartmentId", SqlDbType.Int).Value = departmentId;
                parameters.Add("@Instructions", SqlDbType.NVarChar, 500).Value = "Demo instructions only";
            });

        var prescriptionItemId = await InsertIdAsync(connection, transaction, @"
            INSERT dbo.PrescriptionItems
                (PrescriptionId, DepartmentId, MedicationName, Dosage, Frequency, Duration, Quantity)
            OUTPUT INSERTED.PrescriptionItemId
            VALUES
                (@PrescriptionId, @DepartmentId, @MedicationName, @Dosage, @Frequency, @Duration, @Quantity);",
            parameters =>
            {
                parameters.Add("@PrescriptionId", SqlDbType.Int).Value = prescriptionId;
                parameters.Add("@DepartmentId", SqlDbType.Int).Value = departmentId;
                parameters.Add("@MedicationName", SqlDbType.NVarChar, 100).Value = "Demo medication";
                parameters.Add("@Dosage", SqlDbType.NVarChar, 100).Value = "1 tablet";
                parameters.Add("@Frequency", SqlDbType.NVarChar, 100).Value = "Once daily";
                parameters.Add("@Duration", SqlDbType.NVarChar, 100).Value = "3 days";
                parameters.Add("@Quantity", SqlDbType.Int).Value = 3;
            });

        var labOrderId = await InsertIdAsync(connection, transaction, @"
            INSERT dbo.LabOrders (EncounterId, DepartmentId, TestName, ClinicalIndication)
            OUTPUT INSERTED.LabOrderId
            VALUES (@EncounterId, @DepartmentId, @TestName, @ClinicalIndication);",
            parameters =>
            {
                parameters.Add("@EncounterId", SqlDbType.Int).Value = encounterId;
                parameters.Add("@DepartmentId", SqlDbType.Int).Value = departmentId;
                parameters.Add("@TestName", SqlDbType.NVarChar, 100).Value = testName;
                parameters.Add("@ClinicalIndication", SqlDbType.NVarChar, 500).Value = indication;
            });

        var labResultId = await InsertIdAsync(connection, transaction, @"
            INSERT dbo.LabResults
                (LabOrderId, DepartmentId, ResultValue, ReferenceRange, Conclusion)
            OUTPUT INSERTED.LabResultId
            VALUES (@LabOrderId, @DepartmentId, @ResultValue, @ReferenceRange, @Conclusion);",
            parameters =>
            {
                parameters.Add("@LabOrderId", SqlDbType.Int).Value = labOrderId;
                parameters.Add("@DepartmentId", SqlDbType.Int).Value = departmentId;
                parameters.Add("@ResultValue", SqlDbType.NVarChar, 200).Value = "Demo value";
                parameters.Add("@ReferenceRange", SqlDbType.NVarChar, 100).Value = "Demo range";
                parameters.Add("@Conclusion", SqlDbType.NVarChar, 1000).Value = "Demo result only";
            });

        transaction.Commit();

        await using var readBack = connection.CreateCommand();
        readBack.CommandText = @"
            SELECT o.TestName, o.ClinicalIndication,
                   r.ResultValue, r.ReferenceRange, r.Conclusion
            FROM dbo.LabOrders AS o
            INNER JOIN dbo.LabResults AS r
                ON r.LabOrderId = o.LabOrderId
               AND r.DepartmentId = o.DepartmentId
            WHERE o.LabOrderId = @LabOrderId;";
        readBack.Parameters.Add("@LabOrderId", SqlDbType.Int).Value = labOrderId;

        await using var readBackReader = await readBack.ExecuteReaderAsync();
        if (!await readBackReader.ReadAsync())
            throw new InvalidOperationException("The lab result was saved, but read-back returned no row.");

        Console.WriteLine("Demo transaction committed successfully.");
        Console.WriteLine($"EncounterId={encounterId}; DepartmentId={departmentId}; RecordId={recordId}");
        Console.WriteLine($"PrescriptionId={prescriptionId}; PrescriptionItemId={prescriptionItemId}");
        Console.WriteLine($"LabOrderId={labOrderId}; LabResultId={labResultId}");
        Console.WriteLine("Lab result read back successfully through the Always Encrypted connection:");
        Console.WriteLine($"TestName={readBackReader.GetString(0)}; ClinicalIndication={readBackReader.GetString(1)}");
        Console.WriteLine($"ResultValue={readBackReader.GetString(2)}; ReferenceRange={readBackReader.GetString(3)}; Conclusion={readBackReader.GetString(4)}");
        Console.WriteLine("All clinical text above is synthetic demo data.");
    }
    catch
    {
        transaction.Rollback();
        throw;
    }
}
catch (Exception ex)
{
    Console.Error.WriteLine($"Demo failed: {ex.Message}");
    Environment.ExitCode = 1;
}

static async Task<int> InsertIdAsync(
    SqlConnection connection,
    SqlTransaction transaction,
    string sql,
    Action<SqlParameterCollection> addParameters)
{
    await using var command = connection.CreateCommand();
    command.Transaction = transaction;
    command.CommandText = sql;
    addParameters(command.Parameters);

    var result = await command.ExecuteScalarAsync();
    if (result is null || result is DBNull)
        throw new InvalidOperationException("The insert did not return an identity value.");

    return Convert.ToInt32(result);
}

