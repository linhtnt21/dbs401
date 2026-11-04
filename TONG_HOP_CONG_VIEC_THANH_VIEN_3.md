# Tổng hợp công việc – Thành viên 3 (Ledger và kiểm chứng)

**Dự án:** HospitalZT – DBS401  
**Ngày tổng hợp:** 03/11/2026

## Phạm vi được giao

Theo `HospitalZT_PhanCong_HuongDan.docx`, thành viên 3 phụ trách Ledger và kiểm chứng:

- Kiểm tra 7 bảng Ledger có thể cập nhật, bảng history và ledger view.
- Làm phần ứng dụng đơn thuốc, chi tiết đơn, chỉ định và kết quả xét nghiệm.
- Truy vấn lịch sử trước/sau cập nhật và metadata giao dịch.
- Xuất digest sau khi giao dịch commit, lưu bản gốc ở nơi DBA không thể sửa và xác minh bằng `sp_verify_database_ledger`.
- Chứng minh history không thể bị sửa/xóa trực tiếp và cập nhật hợp lệ vẫn xác minh được.

## Việc đã kiểm tra trong thư mục dự án

- Đọc README, script tạo database/bảng và script kiểm tra.
- Xác nhận schema khai báo Ledger cho đúng 7 bảng: `Patients`, `Encounters`, `MedicalRecords`, `Prescriptions`, `PrescriptionItems`, `LabOrders`, `LabResults`; mỗi bảng có history table và ledger view tương ứng.
- Xác nhận dự án dùng **SQL Server 2022 Developer trong Docker**, không dùng MySQL. `Setup.ps1` cũng tạo khóa Always Encrypted và nạp dữ liệu giả lập.
- Xác nhận các file bàn giao riêng cho thành viên 3 (`sql/05_ledger_verify.sql`, `docs/ledger.md`, phần ứng dụng) chưa có trong thư mục setup hiện tại.

## Trạng thái setup trên máy

**Chưa chạy setup và chưa xác minh được cơ sở dữ liệu.** Đã mở Docker Desktop qua giao diện; ứng dụng hiện báo lỗi khởi động Secrets Engine vì không thể đổi tên `C:\Users\nhutk\AppData\Local\docker-secrets-engine\engine.sock` thành `.stale` (tệp đang bị khóa/không truy cập được). Docker API vẫn không kết nối được. Vì vậy chưa thể chạy `Setup.ps1`, kết nối SQL Server, xuất digest thật hay chạy `sp_verify_database_ledger`. Không chọn Reset to factory defaults vì có thể xóa trạng thái Docker hiện có.

Dịch vụ `MySQL84` đang dừng. MySQL không phù hợp với schema và yêu cầu Ledger trong tài liệu phân công. Mật khẩu được cung cấp không được ghi vào tài liệu hoặc mã nguồn. Setup dự án yêu cầu mật khẩu `sa` riêng cho SQL Server; chỉ nhập trực tiếp tại dấu nhắc bảo mật khi chạy setup sau khi Docker Desktop đã sẵn sàng.

## Những việc còn lại để hoàn tất phần được giao

1. Khởi động Docker Desktop ở chế độ Linux containers.
2. Chạy `Setup.ps1` một lần từ thư mục này và lưu lại kết quả/ảnh minh chứng, không đăng nhập bí mật vào Git.
3. Kiểm tra 7 ledger view và các history table trên database thật.
4. Tạo/hoàn thiện `sql/05_ledger_verify.sql` và `docs/ledger.md`; truy vấn lịch sử kèm metadata giao dịch.
5. Thực hiện cập nhật hợp lệ, xuất digest sau commit, lưu digest bên ngoài quyền DBA và chạy `sp_verify_database_ledger` với digest tin cậy.
6. Kiểm thử rằng sửa/xóa history bị từ chối; ghi rõ kết quả thực tế và ảnh minh chứng.
7. Bàn giao phần C# đơn thuốc/xét nghiệm sau khi thống nhất cách kết nối Always Encrypted với thành viên 2.

## Kết luận

Phần phân công và cấu trúc Ledger đã được rà soát. Phần vận hành, kiểm thử Ledger và setup SQL Server **chưa thể đánh dấu hoàn thành** do Docker engine chưa chạy và chưa có kết quả thực thi trên database. Không có thao tác xóa hoặc ghi đè database/volume nào được thực hiện.
