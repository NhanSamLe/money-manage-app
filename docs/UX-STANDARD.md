# Chuẩn UX/UI của MoMa (mobile)

Nguồn: yêu cầu của chủ sở hữu, bản thiết kế trong `design/`, và checklist `ux-ui.md` của supership-automation-agent (chỉ lấy phần áp dụng được cho app di động).

## Nhập liệu
- Mọi ô có **nhãn phía trên** và gợi ý `Nhập ...` bên trong. Quy tắc (độ dài, định dạng) không viết vào gợi ý.
- **Kiểm tra từng ô** ngay khi người dùng gõ hoặc rời ô (`LabeledField`, `MoneyField`), và kiểm tra lại toàn form khi bấm nút. Lỗi hiện ngay dưới ô, tối đa 3 dòng, không cắt chữ.
- Bộ kiểm tra dùng chung ở `core/validators.dart` (email, mật khẩu ≥ 8 ký tự có chữ và số, tên, mã 6-8 số, số tiền > 0). Ô tiền chỉ nhận chữ số và tự thêm dấu chấm nghìn nên không nhập sai được.
- Lỗi từ máy chủ, mạng hoặc không lường trước hiện bằng **hộp thoại** (`showErrorDialog`), không hiện inline.

## Nút (quy tắc di động, `ActionButtons`)
- 1 nút: một nút chính rộng hết chiều ngang.
- 2 nút: hai nút bằng nhau cạnh nhau, nút an toàn bên trái, nút chính bên phải.
- 3 nút: nút chính trên cùng, nút phụ bên dưới, nút thứ ba dạng chữ.
- Nút chính của form dài **dính đáy màn** (nằm trên bàn phím). Vùng bấm tối thiểu 44 px. Khi đang xử lý, mọi nút bị khóa để không gửi hai lần.

## Bộ lọc và lựa chọn
- Bộ lọc và chọn giá trị dùng **bottom sheet** (`showChoiceSheet`): tay nắm, tiêu đề giữa, danh sách có icon và dấu chọn.

## Bố cục
- Lề trái/phải 16, khoảng cách khối 12 đến 16, nút cạnh nhau ≥ 8, chip cách nhau 6. Không margin âm, không thẻ lồng thẻ, không hai hàng chip liền nhau.
- Chữ dài **xuống dòng**, không dùng dấu ba chấm cho thông tin chính. Số tiền co chữ trong ô thay vì tràn.
- Mỗi giá trị có nhãn rõ; giá trị trống ghi "Chưa biết", không hiện `null`, `0đ`, `NaN`.
- Mọi nút chỉ có icon có `tooltip`. Đủ trạng thái: đang tải, rỗng, lỗi, mất mạng.
