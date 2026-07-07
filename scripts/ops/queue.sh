#!/usr/bin/env bash
# CLI quản lý hàng đợi surreal-commands (bảng `command` trong SurrealDB) cho
# instance chạy dạng single-container (ai.core.ainotebookapi, supervisord
# quản lý api + worker + frontend + surrealdb trong cùng container).
#
# Không có API cancel/xoá job chính thức trong code hiện tại
# (api/command_service.py: list_command_jobs / cancel_command_job chỉ là
# stub, DELETE /commands/jobs/{id} không thực sự làm gì) -- script này thao
# tác trực tiếp trên SurrealDB qua `docker exec` + `surreal sql`.
#
# Dùng:
#   ./queue.sh status
#   ./queue.sh delete-failed [từ-khoá-lỗi]
#   ./queue.sh delete-orphaned
#   ./queue.sh stop-all
#
# Container: mặc định tìm container có tên chứa "open_notebook". Ghi đè bằng
#   ONB_CONTAINER=<tên-hoặc-id-container> ./queue.sh ...
set -euo pipefail

find_container() {
  # Nếu ONB_CONTAINER được đặt thủ công, dùng đúng giá trị đó (tên hoặc id),
  # không tự động đoán/lọc gì cả -- tin tưởng người dùng.
  if [[ -n "${ONB_CONTAINER:-}" ]]; then
    echo "${ONB_CONTAINER}"
    return 0
  fi

  # Mặc định: tìm container có tên chứa "open_notebook". Tên này có thể khớp
  # nhiều container trên cùng host (ví dụ một deployment multi-container
  # khác trùng tên dự án). Chỉ container tự chứa SurrealDB (có sẵn lệnh
  # `surreal`, kết nối qua 127.0.0.1/localhost) mới dùng được với cách script
  # này thao tác (docker exec + surreal sql cục bộ).
  local pattern="open_notebook" candidates id has_surreal surreal_url
  candidates=$(docker ps --filter "name=${pattern}" --format '{{.ID}}')
  if [[ -z "$candidates" ]]; then
    echo "LỖI: không tìm thấy container khớp với '${pattern}'. Đặt ONB_CONTAINER=<tên-hoặc-id>." >&2
    exit 1
  fi
  while read -r id; do
    [[ -z "$id" ]] && continue
    has_surreal=$(docker exec "$id" sh -c 'command -v surreal' 2>/dev/null || true)
    surreal_url=$(docker exec "$id" sh -c 'echo $SURREAL_URL' 2>/dev/null || true)
    if [[ -n "$has_surreal" && ( "$surreal_url" == *"localhost"* || "$surreal_url" == *"127.0.0.1"* ) ]]; then
      echo "$id"
      return 0
    fi
  done <<< "$candidates"
  echo "LỖI: không container nào khớp '${pattern}' có sẵn SurrealDB cục bộ (lệnh 'surreal' + SURREAL_URL trỏ về localhost)." >&2
  echo "Các container khớp tên nhưng không dùng được:" >&2
  docker ps --filter "name=${pattern}" --format '  {{.ID}}  {{.Names}}  {{.Image}}' >&2
  echo "Đặt ONB_CONTAINER=<tên-hoặc-id> để chỉ định đúng container." >&2
  exit 1
}

CONTAINER="$(find_container)"
SURREAL_USER="$(docker exec "$CONTAINER" sh -c 'echo $SURREAL_USER')"
SURREAL_PASSWORD="$(docker exec "$CONTAINER" sh -c 'echo $SURREAL_PASSWORD')"
SURREAL_NAMESPACE="$(docker exec "$CONTAINER" sh -c 'echo $SURREAL_NAMESPACE')"
SURREAL_DATABASE="$(docker exec "$CONTAINER" sh -c 'echo $SURREAL_DATABASE')"

# sql "<một câu SurrealQL trên một dòng>" -- in kết quả JSON ra stdout,
# đã lọc bỏ banner chào mừng của "surreal sql" cho gọn.
sql() {
  docker exec -i \
    -e SURREAL_USER="$SURREAL_USER" \
    -e SURREAL_PASSWORD="$SURREAL_PASSWORD" \
    -e SURREAL_NAMESPACE="$SURREAL_NAMESPACE" \
    -e SURREAL_DATABASE="$SURREAL_DATABASE" \
    "$CONTAINER" sh -c \
    'surreal sql --conn ws://127.0.0.1:8000/rpc --user "$SURREAL_USER" --pass "$SURREAL_PASSWORD" --ns "$SURREAL_NAMESPACE" --db "$SURREAL_DATABASE" --pretty' \
    <<< "$1" 2>&1 \
    | sed -e '/^#/d' -e '/^-- Query/d' -e '/^[[:space:]]*$/d'
}

# sql_count "<câu SELECT count() ... GROUP ALL>" -- trả về đúng 1 số nguyên
# (0 nếu không có dòng nào khớp), tiện in ra thay vì phải đọc JSON thô.
sql_count() {
  local out num
  out="$(sql "$1")"
  num=$(printf '%s\n' "$out" | grep -oE 'count: [0-9]+' | grep -oE '[0-9]+' | head -1)
  echo "${num:-0}"
}

confirm() {
  local prompt="${1:-Xác nhận thực hiện? (y/N) }"
  local reply
  read -r -p "$prompt" reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

restart_worker() {
  echo "Đang restart worker trong container $CONTAINER..."
  docker exec "$CONTAINER" sh -c '
    for p in /proc/[0-9]*; do
      cmd=$(tr "\0" " " < "$p/cmdline" 2>/dev/null || true)
      case "$cmd" in
        *surreal-commands-worker*) kill -TERM "${p#/proc/}" 2>/dev/null || true ;;
      esac
    done
  '
  sleep 3
  echo "Worker process sau khi restart:"
  docker exec "$CONTAINER" sh -c '
    for p in /proc/[0-9]*; do
      cmd=$(tr "\0" " " < "$p/cmdline" 2>/dev/null || true)
      case "$cmd" in
        *surreal-commands-worker*) echo "  PID ${p#/proc/}: $cmd" ;;
      esac
    done
  '
}

cmd_status() {
  echo "== Tổng quan theo trạng thái =="
  sql "SELECT status, count() FROM command GROUP BY status;"

  echo
  echo "== Job 'new' (đang chờ worker nhận) theo loại =="
  sql "SELECT name, count() FROM command WHERE status='new' GROUP BY name;"

  echo
  echo "== Job 'running' (đang chạy) theo loại =="
  sql "SELECT name, count() FROM command WHERE status='running' GROUP BY name;"

  echo
  echo "== Job 'failed' -- phân loại theo nguyên nhân thường gặp =="
  echo "Lỗi Bedrock/AWS credential (security token không hợp lệ): $(sql_count "SELECT count() FROM command WHERE status='failed' AND string::contains(error_message,'security token') GROUP ALL;")"
  echo "Lỗi do source đã bị xoá (not found):                       $(sql_count "SELECT count() FROM command WHERE status='failed' AND string::contains(error_message,'not found') GROUP ALL;")"
  echo "Tổng số job failed:                                        $(sql_count "SELECT count() FROM command WHERE status='failed' GROUP ALL;")"

  echo
  echo "== Job 'process_source' đang new/running/failed nhưng source đã bị xoá (mồ côi) =="
  echo "Số lượng: $(sql_count "SELECT count() FROM command WHERE name='process_source' AND status IN ['new','running','failed'] AND (SELECT VALUE id FROM ONLY args.source_id) = NONE GROUP ALL;")"
}

cmd_delete_failed() {
  local pattern="${1:-}"
  local where count

  if [[ -n "$pattern" ]]; then
    where="status='failed' AND string::contains(error_message,'${pattern}')"
    echo "Phạm vi: job failed có chứa lỗi: \"$pattern\""
  else
    where="status='failed'"
    echo "Phạm vi: TOÀN BỘ job failed"
  fi

  count="$(sql_count "SELECT count() FROM command WHERE $where GROUP ALL;")"
  echo "Số job sẽ bị xoá: $count"

  if [[ "$count" -eq 0 ]]; then
    echo "Không có job nào để xoá."
    return 0
  fi

  if ! confirm "Xác nhận xoá $count job trên? (y/N) "; then
    echo "Đã huỷ."
    return 0
  fi

  sql "DELETE command WHERE $where;" >/dev/null

  echo "Đã xoá xong. Trạng thái hiện tại:"
  sql "SELECT status, count() FROM command GROUP BY status;"
}

cmd_delete_orphaned() {
  local where="name='process_source' AND status IN ['new','running','failed'] AND (SELECT VALUE id FROM ONLY args.source_id) = NONE"
  local count

  echo "Danh sách job mồ côi (source đã bị xoá):"
  sql "SELECT id, args.source_id, status FROM command WHERE $where;"

  count="$(sql_count "SELECT count() FROM command WHERE $where GROUP ALL;")"
  echo
  echo "Tổng số: $count"

  if [[ "$count" -eq 0 ]]; then
    echo "Không có job mồ côi nào để xoá."
    return 0
  fi

  if ! confirm "Xác nhận xoá $count job mồ côi trên? (y/N) "; then
    echo "Đã huỷ."
    return 0
  fi

  sql "DELETE command WHERE $where;" >/dev/null

  echo "Đã xoá xong. Trạng thái hiện tại:"
  sql "SELECT status, count() FROM command GROUP BY status;"
}

cmd_stop_all() {
  echo "Trạng thái hàng đợi hiện tại:"
  sql "SELECT status, count() FROM command GROUP BY status;"

  echo
  echo "!!! Thao tác này sẽ XOÁ TOÀN BỘ job 'new' + 'running' và RESTART WORKER !!!"
  echo "!!! Nguồn đang 'Processing...' sẽ KHÔNG được xử lý tiếp -- phải thêm lại từ đầu."
  echo "!!! Restart worker sẽ dừng CẢ các job hợp lệ đang chạy cùng lúc."
  if ! confirm "Bạn có chắc chắn muốn dừng hết? (y/N) "; then
    echo "Đã huỷ."
    return 0
  fi

  sql "DELETE command WHERE status IN ['new','running'];" >/dev/null
  restart_worker

  echo
  echo "Trạng thái hàng đợi sau khi dừng:"
  sql "SELECT status, count() FROM command GROUP BY status;"
}

usage() {
  cat <<'USAGE'
Dùng: queue.sh <lệnh> [tham số]

Lệnh:
  status                        Xem tổng quan hàng đợi (theo trạng thái/loại/lỗi)
  delete-failed [từ-khoá-lỗi]   Xoá job failed (không tham số = xoá hết;
                                 có tham số = lọc theo nội dung error_message)
  delete-orphaned                Xoá job process_source mồ côi (source đã bị xoá)
  stop-all                       PHÁ HUỶ: xoá hết new+running, restart worker

Container: mặc định tìm container có tên chứa "open_notebook".
Ghi đè: ONB_CONTAINER=<tên-hoặc-id> ./queue.sh <lệnh>
USAGE
}

main() {
  local sub="${1:-}"
  case "$sub" in
    status)          shift; cmd_status "$@" ;;
    delete-failed)   shift; cmd_delete_failed "$@" ;;
    delete-orphaned) shift; cmd_delete_orphaned "$@" ;;
    stop-all)        shift; cmd_stop_all "$@" ;;
    -h|--help|""|help) usage ;;
    *) echo "Lệnh không hợp lệ: $sub" >&2; usage; exit 1 ;;
  esac
}

main "$@"
