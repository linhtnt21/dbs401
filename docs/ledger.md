# HospitalZT Ledger – hướng dẫn phần thành viên 3

## Phạm vi

Schema hiện bật updatable ledger và system versioning cho `Patients`, `Encounters`, `MedicalRecords`, `Prescriptions`, `PrescriptionItems`, `LabOrders`, `LabResults`. Các bảng history và ledger view được đặt tên theo hậu tố `History` và `LedgerView`.

## Kiểm tra cấu trúc

Sau khi setup thành công, mở SSMS bằng kết nối `tcp:127.0.0.1,14330`, chọn database `HospitalZT`, rồi chạy `sql/05_ledger_verify.sql`. Bảy dòng kết quả đầu cần có `LedgerType = UPDATABLE` cùng ledger view; truy vấn tiếp theo liệt kê history table và số dòng. Ledger view chứa metadata giao dịch để đối chiếu cập nhật.

## Kiểm thử cập nhật và history

Chỉ dùng hồ sơ giả lập trong lab. Chọn một bản ghi có sẵn; đọc giá trị và metadata trong ledger view, cập nhật một trường nghiệp vụ bằng một giá trị thử nghiệm, commit, rồi truy vấn lại view để thấy phiên bản mới. History temporal giữ phiên bản trước đó. Không xóa hay sửa trực tiếp history table: SQL Server quản lý các bảng này và thao tác trực tiếp phải bị từ chối. Ghi lại thông báo thực tế, không suy diễn nếu chưa chạy.

## Digest và xác minh

Sau khi giao dịch đã commit, chạy `EXEC sys.sp_generate_database_ledger_digest;`. Lưu toàn bộ JSON digest ở nơi lưu trữ được bảo vệ mà DBA có thể quản lý database không thể sửa. Bản digest chỉ trong cùng database hoặc Git không phải bản tin cậy độc lập. Khi kiểm chứng, truyền digest tin cậy vào `sys.sp_verify_database_ledger` theo cú pháp chú thích trong `sql/05_ledger_verify.sql` và lưu kết quả.

## Giới hạn và bàn giao

Ledger hỗ trợ phát hiện thay đổi khi so sánh với digest tin cậy; bản thân nó không thay thế backup và không ngăn mọi thao tác phá hủy. Script kiểm tra cấu trúc là read-only. Chưa có kết quả vận hành được ghi nhận cho tới khi chạy trên SQL Server thật. Phần C# đơn thuốc/xét nghiệm cần tích hợp trong project ứng dụng của nhóm; thư mục setup hiện tại chưa có source C#.
