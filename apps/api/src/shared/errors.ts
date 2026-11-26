export interface ErrorSpec { status: 400 | 401 | 403 | 404 | 409 | 422 | 429 | 503; retryable: boolean; message: string }

// Stable domain error codes raised by the DB RPCs -> HTTP mapping (docs/12 section 2, docs/08).
const TABLE: Record<string, ErrorSpec> = {
  UNAUTHENTICATED: { status: 401, retryable: false, message: "Phiên đăng nhập không hợp lệ." },
  RATE_LIMITED: { status: 429, retryable: true, message: "Quá nhiều yêu cầu." },
  INVALID_AMOUNT: { status: 422, retryable: false, message: "Số tiền không hợp lệ." },
  VALIDATION_FAILED: { status: 400, retryable: false, message: "Dữ liệu không hợp lệ." },
  CATEGORY_MISMATCH: { status: 422, retryable: false, message: "Danh mục không phù hợp loại giao dịch." },
  ACCOUNT_ARCHIVED: { status: 422, retryable: false, message: "Tài khoản đã lưu trữ." },
  NOT_FOUND: { status: 404, retryable: false, message: "Không tìm thấy dữ liệu." },
  VERSION_CONFLICT: { status: 409, retryable: false, message: "Dữ liệu đã thay đổi, hãy tải lại." },
  DUPLICATE_KEY_MISMATCH: { status: 409, retryable: false, message: "Khóa idempotency đã dùng cho nội dung khác." },
  OWNER_NOT_BOUND: { status: 403, retryable: false, message: "Ứng dụng chưa được thiết lập." },
  DEVICE_REVOKED: { status: 403, retryable: false, message: "Thiết bị đã bị thu hồi." },
  IDENTITY_CONFLICT: { status: 403, retryable: false, message: "Danh tính không khớp." },
  SETUP_ALREADY_BOUND: { status: 409, retryable: false, message: "Ứng dụng đã có chủ sở hữu." },
  SETUP_LEASE_HELD: { status: 409, retryable: true, message: "Đang có phiên thiết lập khác." },
  SETUP_LEASE_INVALID: { status: 409, retryable: false, message: "Phiên thiết lập hết hạn." },
  INVITE_NOT_VERIFIED: { status: 403, retryable: false, message: "Email chưa được xác minh." },
  REASON_REQUIRED: { status: 422, retryable: false, message: "Cần nhập lý do." },
  INSUFFICIENT_PRINCIPAL: { status: 422, retryable: false, message: "Số tiền vượt quá số còn lại." },
  INSUFFICIENT_AVAILABLE: { status: 422, retryable: false, message: "Số dư khả dụng không đủ." },
  DEBT_LINKED: { status: 422, retryable: false, message: "Giao dịch gắn với công nợ, hãy sửa trong mục Công nợ." },
  BASELINE_UNKNOWN: { status: 422, retryable: false, message: "Tài khoản chưa biết số dư đầu kỳ." },
  INVALID_STATE: { status: 422, retryable: false, message: "Trạng thái không cho phép thao tác." },
  NOT_IMPLEMENTED: { status: 422, retryable: false, message: "Tính năng chưa được bật." },
  UNBALANCED_JOURNAL: { status: 422, retryable: false, message: "Bút toán không cân." },
};
const GENERIC: ErrorSpec = { status: 503, retryable: true, message: "Hệ thống tạm thời gián đoạn." };

export class DomainError extends Error {
  constructor(readonly code: string) { super(code); }
}
export function specFor(code: string): ErrorSpec { return TABLE[code] ?? GENERIC; }
export function isKnownCode(code: string): boolean { return code in TABLE; }
