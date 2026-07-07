# Command queue ops scripts

Bộ script quản lý hàng đợi `surreal-commands` (bảng `command` trong SurrealDB)
khi worker bị kẹt/tồn đọng job. Dùng cho instance chạy dạng single-container
(`ai.core.ainotebookapi`, supervisord quản lý `api` + `worker` + `frontend` +
`surrealdb` trong cùng container).

Không có API cancel/xoá job chính thức trong code hiện tại
(`api/command_service.py`: `list_command_jobs` / `cancel_command_job` chỉ là
stub, `DELETE /commands/jobs/{id}` không thực sự làm gì) — các script này
thao tác trực tiếp trên SurrealDB qua `docker exec` + `surreal sql`.

## Dùng

Một CLI duy nhất, `queue.sh`, với 4 lệnh con:

```bash
cd scripts/ops
./queue.sh status
./queue.sh delete-failed ["security token"]   # khong tham so = xoa het job failed
./queue.sh delete-orphaned                    # dọn job mồ côi do bug source-bị-xoá
./queue.sh stop-all                           # PHÁ HUỶ: dừng sạch, làm lại từ đầu
```

- **`status`** — xem tổng quan: số job theo status (`new`/`running`/
  `failed`/`completed`), theo loại job, và breakdown lỗi thường gặp (Bedrock
  credential, source bị xoá). Chạy trước khi xoá gì đó.
- **`delete-failed [pattern]`** — xoá job `failed`. Không tham số =
  xoá hết; có tham số = chỉ xoá job có `error_message` chứa chuỗi đó (ví dụ
  `"security token"` cho lỗi Bedrock, `"not found"` cho lỗi source bị xoá).
  An toàn — job failed đã hết retry, không có task nào đang chạy gắn với nó.
- **`delete-orphaned`** — xoá job `process_source` (mọi trạng thái
  new/running/failed) mà source tương ứng đã bị xoá khỏi DB. Đây là hệ quả
  của bug trong `api/routers/sources.py` (xem phần "Bug gốc" bên dưới).
- **`stop-all`** — **phá huỷ**: xoá hết job `new` + `running` rồi
  restart worker process để dừng hẳn các task đang chạy ngầm. Sẽ làm gián
  đoạn cả các job hợp lệ đang chạy cùng lúc. Chỉ dùng khi muốn xoá sạch hàng
  đợi và làm lại từ đầu.

Mỗi lệnh xoá đều in ra số lượng/danh sách sẽ bị xoá và hỏi xác nhận
(y/N) trước khi chạy `DELETE`.

## Cấu hình

Mặc định tự tìm container có **tên chứa `open_notebook`**. Nếu có nhiều
container khớp hoặc muốn chỉ định thủ công:

```bash
export ONB_CONTAINER=<ten-hoac-id-container>
```

Thông tin kết nối SurrealDB (user/pass/namespace/database) được đọc trực
tiếp từ biến môi trường của chính container đang chạy — không hardcode
trong script, nên vẫn đúng sau khi redeploy.

## Bug gốc (nguồn cơn của job "mồ côi")

`api/routers/sources.py` (`_create_source_async_path`): sau khi
`submit_command_job()` gửi job xử lý source đi (worker có thể nhận việc
ngay lập tức), code gọi thêm một lần `source.save()` nữa chỉ để gán
`source.command`. Nếu lần save thứ 2 này lỗi (SurrealDB v2 transaction
conflict — theo `open_notebook/AGENTS.md` đây là lỗi đã biết, có thể xảy
ra), except-block sẽ xoá luôn source vừa tạo — trong khi job xử lý nó có
thể đã được worker nhận. Worker sau đó gọi `Source.get()` trên một source
không còn tồn tại, ném `NotFoundError`; lỗi này không nằm trong danh sách
`stop_on` của retry config (`commands/source_commands.py`) nên bị coi là
lỗi tạm thời và retry tới 15 lần trước khi fail hẳn.

Chưa sửa trong code — `queue-delete-orphaned.sh` chỉ dọn triệu chứng, bug
vẫn có thể tái diễn cho tới khi code được sửa (đổi thứ tự: gán
`source.command` + save **trước** khi submit job, hoặc không xoá source khi
chỉ có lần save thứ 2 thất bại).
