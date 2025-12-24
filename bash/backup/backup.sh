#!/bin/bash
set -euo pipefail

# =========================================================
# 变动触发全量压缩备份（最终最终版：无 at 依赖）
#
# 特性：
# 1) 检测目录内“文件变化”（只看文件：相对路径 + size + mtime）
#    - 变化：打包整个目录为加密 zip，上传到启用后端（七牛 / WebDAV）
#    - 未变化：若某后端缺少该版本，则补传该后端
# 2) 文件未变化补传时：优先复用上次生成的 zip（不重打包）
# 3) 每个目录独立 state：DEST_DIR/<DIR_KEY>/.state/
# 4) 清理：本地 + 七牛 + WebDAV（按 RETENTION_HOURS）
#    - 七牛/WebDAV 清理都跳过本次刚上传的文件（O(1)）
#
# 配置文件：
# - 默认：脚本同目录 backup.conf
# - 或：./backup.sh /path/to/backup.conf
#
# 配置里支持相对脚本目录写法：
#   DEST_DIR="./backup_out"
#   PASSWORD_FILE="./password"
#   WEBDAV_PASS_FILE="./webdav_pass"
# =========================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/backup.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "配置文件不存在：$CONFIG_FILE"
  echo "请在脚本同目录创建 backup.conf，或运行：$0 /path/to/backup.conf"
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# -----------------------
# 默认值兜底
# -----------------------
: "${SOURCE_DIRS:=()}"
: "${DEST_DIR:=./backup_out}"
: "${PASSWORD_FILE:=./password}"

: "${ENABLE_QINIU:=0}"
: "${ENABLE_WEBDAV:=0}"

: "${ONLY_BACKUP_WHEN_CHANGED:=1}"
: "${UPLOAD_MISSING_BACKENDS_WHEN_UNCHANGED:=1}"

: "${RETENTION_HOURS:=24}"
: "${TIMEZONE:=Asia/Shanghai}"

: "${QINIU_BUCKET:=}"
: "${QINIU_DIR:=backup}"

: "${WEBDAV_BASE_URL:=}"
: "${WEBDAV_USER:=}"
: "${WEBDAV_PASS_FILE:=./webdav_pass}"
: "${WEBDAV_DIR:=backup}"

: "${HOSTNAME_OVERRIDE:=}"

# -----------------------
# 把 ./xxx 变成 “脚本目录/xxx”（兼容 cron 工作目录为 /）
# -----------------------
resolve_path() {
  local p="$1"
  if [[ "$p" == ./* ]]; then
    echo "$SCRIPT_DIR/${p#./}"
  else
    echo "$p"
  fi
}

DEST_DIR="$(resolve_path "$DEST_DIR")"
PASSWORD_FILE="$(resolve_path "$PASSWORD_FILE")"
WEBDAV_PASS_FILE="$(resolve_path "$WEBDAV_PASS_FILE")"

# =========================================================
# 工具函数
# =========================================================
log() { echo "[$(date)] $*"; }
sanitize_tag() { echo "$1" | sed 's/[^A-Za-z0-9._-]/_/g'; }

read_file_or_die() {
  local f="$1" msg="$2"
  local v
  v="$(cat "$f" 2>/dev/null || true)"
  if [ -z "${v:-}" ]; then
    echo "$msg"
    exit 1
  fi
  echo "$v"
}

urlencode() {
  local s="$1" out="" i c hex
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  echo "$out"
}

encode_rel_path() {
  local rel="$1" encoded=""
  IFS='/' read -ra segs <<< "$rel"
  for seg in "${segs[@]}"; do
    [ -z "$seg" ] && continue
    if [ -z "$encoded" ]; then
      encoded="$(urlencode "$seg")"
    else
      encoded="$encoded/$(urlencode "$seg")"
    fi
  done
  echo "$encoded"
}

qiniu_time_to_local() {
  local qiniu_ts=$1
  local utc_ts
  utc_ts=$(echo "$qiniu_ts" | cut -c1-10)
  TZ=$TIMEZONE date -d "@$utc_ts" "+%Y-%m-%d %H:%M:%S"
}

# =========================================================
# WebDAV 操作
# =========================================================
webdav_mkcol() {
  local rel="$1"
  local enc
  enc="$(encode_rel_path "$rel")"
  curl -fsS -u "$WEBDAV_USER:$WEBDAV_PASS" -X MKCOL "${WEBDAV_BASE_URL}/${enc}/" >/dev/null 2>&1 || true
}

webdav_ensure_dirs() {
  local rel="$1"
  local IFS='/'
  read -ra parts <<< "$rel"
  local path=""
  for part in "${parts[@]}"; do
    [ -z "$part" ] && continue
    if [ -z "$path" ]; then path="$part"; else path="$path/$part"; fi
    webdav_mkcol "$path"
  done
}

webdav_put() {
  local local_file="$1"
  local remote_rel="$2"
  local enc
  enc="$(encode_rel_path "$remote_rel")"
  # 增强兼容性：禁用 Expect: 100-continue
  curl -fsS -u "$WEBDAV_USER:$WEBDAV_PASS" -H "Expect:" -T "$local_file" "${WEBDAV_BASE_URL}/${enc}" >/dev/null
}

webdav_delete() {
  local remote_rel="$1"
  local enc
  enc="$(encode_rel_path "$remote_rel")"
  curl -fsS -u "$WEBDAV_USER:$WEBDAV_PASS" -X DELETE "${WEBDAV_BASE_URL}/${enc}" >/dev/null || true
}

# 列目录 depth=1，输出：filename<TAB>lastmod（仅 *.zip）
webdav_list_zip_with_lastmod() {
  local remote_dir_rel="$1"
  local enc
  enc="$(encode_rel_path "$remote_dir_rel")"
  local url="${WEBDAV_BASE_URL}/${enc}"
  [[ "$url" != */ ]] && url="$url/"

  local xml
  xml="$(curl -fsS -u "$WEBDAV_USER:$WEBDAV_PASS" -X PROPFIND -H "Depth: 1" "$url" 2>/dev/null || true)"
  [ -z "$xml" ] && return 0

  if command -v xmllint >/dev/null 2>&1; then
    echo "$xml" | xmllint --xpath '//*[local-name()="response"]' - 2>/dev/null \
      | sed 's#</[^>]*response[^>]*>#\n#g' \
      | while read -r chunk; do
          [ -z "$chunk" ] && continue
          href="$(echo "$chunk" | xmllint --xpath 'string(//*[local-name()="href"][1])' - 2>/dev/null || true)"
          lm="$(echo "$chunk"   | xmllint --xpath 'string(//*[local-name()="getlastmodified"][1])' - 2>/dev/null || true)"
          [ -z "$href" ] && continue
          name="$(basename "$href")"
          [[ "$name" != *.zip ]] && continue
          printf "%s\t%s\n" "$name" "$lm"
        done
  else
    echo "$xml" | tr '\n' ' ' | sed 's#</[^>]*response>#\n#g' \
      | while read -r line; do
          href="$(echo "$line" | sed -n 's/.*<[^>]*href[^>]*>\([^<]*\)<\/[^>]*href>.*/\1/p')"
          lm="$(echo "$line"   | sed -n 's/.*<[^>]*getlastmodified[^>]*>\([^<]*\)<\/[^>]*getlastmodified>.*/\1/p')"
          [ -z "$href" ] && continue
          name="$(basename "$href")"
          [[ "$name" != *.zip ]] && continue
          printf "%s\t%s\n" "$name" "$lm"
        done
  fi
}

# =========================================================
# 检查工具 & 参数
# =========================================================
for tool in zip find date sed hostname cmp sort sha1sum awk cut; do
  command -v "$tool" >/dev/null 2>&1 || { echo "缺少 $tool，退出"; exit 1; }
done
if [ "$ENABLE_QINIU" -eq 1 ]; then
  command -v qshell >/dev/null 2>&1 || { echo "启用了七牛，但缺少 qshell"; exit 1; }
fi
if [ "$ENABLE_WEBDAV" -eq 1 ]; then
  command -v curl >/dev/null 2>&1 || { echo "启用了WebDAV，但缺少 curl"; exit 1; }
fi

if [ "${#SOURCE_DIRS[@]}" -eq 0 ]; then
  echo "SOURCE_DIRS 为空：请在配置文件中填写要备份的目录"
  exit 1
fi

PASSWORD="$(read_file_or_die "$PASSWORD_FILE" "zip 密码文件为空：$PASSWORD_FILE")"

WEBDAV_PASS=""
if [ "$ENABLE_WEBDAV" -eq 1 ]; then
  [ -n "${WEBDAV_BASE_URL:-}" ] || { echo "WEBDAV_BASE_URL 为空"; exit 1; }
  [ -n "${WEBDAV_USER:-}" ] || { echo "WEBDAV_USER 为空"; exit 1; }
  WEBDAV_BASE_URL="${WEBDAV_BASE_URL%/}" # 防止出现双斜杠
  WEBDAV_PASS="$(read_file_or_die "$WEBDAV_PASS_FILE" "WebDAV 密码文件为空：$WEBDAV_PASS_FILE")"
fi

if [ "$ENABLE_QINIU" -eq 1 ]; then
  [ -n "${QINIU_BUCKET:-}" ] || { echo "QINIU_BUCKET 为空"; exit 1; }
fi

mkdir -p "$DEST_DIR"

HOSTNAME_TAG="$(sanitize_tag "${HOSTNAME_OVERRIDE:-}")"
if [ -z "$HOSTNAME_TAG" ]; then
  HOSTNAME_TAG="$(sanitize_tag "$(hostname -s 2>/dev/null || hostname)")"
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# 远端清理：用 O(1) 集合跳过本次刚上传
declare -A QINIU_UPLOADED_SET=()
declare -A WEBDAV_UPLOADED_SET=()

# =========================================================
# 主流程：每个目录独立 state（DEST_DIR/<DIR_KEY>/.state）
# =========================================================
for SOURCE_DIR in "${SOURCE_DIRS[@]}"; do
  SOURCE_DIR="${SOURCE_DIR%/}"
  [ -d "$SOURCE_DIR" ] || { log "跳过：目录不存在 $SOURCE_DIR"; continue; }

  DIR_NAME="$(basename "$SOURCE_DIR")"
  PARENT_DIR="$(dirname "$SOURCE_DIR")"

  DIR_HASH="$(printf "%s" "$SOURCE_DIR" | sha1sum | awk '{print $1}' | cut -c1-8)"
  DIR_KEY="${DIR_NAME}-${DIR_HASH}"

  OUT_DIR="$DEST_DIR/$DIR_KEY"
  STATE_DIR="$OUT_DIR/.state"
  mkdir -p "$OUT_DIR" "$STATE_DIR"

  build_manifest() { (cd "$1" && TZ=UTC find . -type f -printf '%P\t%s\t%T@\n' | sort); }

  # 只生成一次 manifest：返回 hash；返回码：0=变化/首次，1=未变化
  dir_has_changed_and_hash() {
    local src="$1" key="$2"
    local old="$STATE_DIR/${key}.manifest"
    local new="$STATE_DIR/${key}.manifest.new"
    build_manifest "$src" > "$new"

    local new_hash
    new_hash="$(sha1sum "$new" | awk '{print $1}')"

    if [ ! -f "$old" ]; then
      mv -f "$new" "$old"
      echo "$new_hash"
      return 0
    fi

    if cmp -s "$old" "$new"; then
      rm -f "$new"
      echo "$new_hash"
      return 1
    else
      mv -f "$new" "$old"
      echo "$new_hash"
      return 0
    fi
  }

  backend_has_uploaded() {
    local dirkey="$1" backend="$2" hash="$3"
    local f="$STATE_DIR/${dirkey}.${backend}.uploaded"
    [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$hash" ]
  }
  mark_backend_uploaded() { echo "$3" > "$STATE_DIR/${1}.${2}.uploaded"; }

  save_last_zip() {
    echo "$2" > "$STATE_DIR/${1}.last_hash"
    echo "$3" > "$STATE_DIR/${1}.last_zip"
  }
  load_last_zip_if_match() {
    local hf="$STATE_DIR/${1}.last_hash"
    local zf="$STATE_DIR/${1}.last_zip"
    [ -f "$hf" ] || return 1
    [ -f "$zf" ] || return 1
    local last_hash last_zip
    last_hash="$(cat "$hf" 2>/dev/null || true)"
    last_zip="$(cat "$zf" 2>/dev/null || true)"
    [ "$last_hash" = "$2" ] || return 1
    [ -f "$last_zip" ] || return 1
    echo "$last_zip"
    return 0
  }

  rc=0
  CUR_HASH="$(dir_has_changed_and_hash "$SOURCE_DIR" "$DIR_KEY")" || rc=$?

  changed=1
  if [ "${ONLY_BACKUP_WHEN_CHANGED:-1}" -eq 1 ]; then
    if [ "$rc" -eq 0 ]; then
      changed=1
      log "检测到文件变化：$DIR_KEY"
    else
      changed=0
      log "无文件变化：$DIR_KEY"
    fi
  fi

  need_qiniu=0
  need_webdav=0
  if [ "$ENABLE_QINIU" -eq 1 ] && ! backend_has_uploaded "$DIR_KEY" "qiniu" "$CUR_HASH"; then
    need_qiniu=1
  fi
  if [ "$ENABLE_WEBDAV" -eq 1 ] && ! backend_has_uploaded "$DIR_KEY" "webdav" "$CUR_HASH"; then
    need_webdav=1
  fi

  if [ "$changed" -eq 0 ]; then
    if [ "${UPLOAD_MISSING_BACKENDS_WHEN_UNCHANGED:-1}" -eq 0 ]; then
      log "文件未变且不补传缺失后端：跳过 $DIR_KEY"
      continue
    fi
    if [ "$need_qiniu" -eq 0 ] && [ "$need_webdav" -eq 0 ]; then
      log "文件未变且两端都有该版本：跳过 $DIR_KEY"
      continue
    fi
    log "文件未变但存在缺失后端：将补传（qiniu=$need_qiniu webdav=$need_webdav）"
  fi

  ZIP_TO_USE=""
  if [ "$changed" -eq 0 ] && { [ "$need_qiniu" -eq 1 ] || [ "$need_webdav" -eq 1 ]; }; then
    if ZIP_TO_USE="$(load_last_zip_if_match "$DIR_KEY" "$CUR_HASH")"; then
      log "复用上次zip用于补传：$ZIP_TO_USE"
    else
      log "未找到可复用zip（可能被清理/首次补传），兜底重新打包一次"
    fi
  fi

  if [ -z "$ZIP_TO_USE" ]; then
    ARCHIVE_NAME="${DIR_KEY}_${TIMESTAMP}.zip"
    LOCAL_ZIP_PATH="$OUT_DIR/$ARCHIVE_NAME"
    log "打包：$SOURCE_DIR -> $LOCAL_ZIP_PATH"
    (cd "$PARENT_DIR" && zip -erP "$PASSWORD" "$LOCAL_ZIP_PATH" "$DIR_NAME")
    ZIP_TO_USE="$LOCAL_ZIP_PATH"
    save_last_zip "$DIR_KEY" "$CUR_HASH" "$ZIP_TO_USE"
  fi

  ARCHIVE_BASENAME="$(basename "$ZIP_TO_USE")"

  # 七牛上传（3次重试）
  if [ "$ENABLE_QINIU" -eq 1 ] && { [ "$changed" -eq 1 ] || [ "$need_qiniu" -eq 1 ]; }; then
    QINIU_KEY="${QINIU_DIR}/${HOSTNAME_TAG}/${DIR_KEY}/${ARCHIVE_BASENAME}"
    uploaded=0
    for i in {1..3}; do
      if qshell fput "$QINIU_BUCKET" "$QINIU_KEY" "$ZIP_TO_USE" >/dev/null; then
        log "七牛上传成功（第$i次）：$QINIU_KEY"
        uploaded=1
        break
      fi
    done
    [ "$uploaded" -eq 1 ] || { echo "七牛上传失败：$QINIU_KEY"; exit 1; }
    QINIU_UPLOADED_SET["$QINIU_KEY"]=1
    mark_backend_uploaded "$DIR_KEY" "qiniu" "$CUR_HASH"
  fi

  # WebDAV 上传（3次重试）
  if [ "$ENABLE_WEBDAV" -eq 1 ] && { [ "$changed" -eq 1 ] || [ "$need_webdav" -eq 1 ]; }; then
    WEBDAV_REL="${WEBDAV_DIR}/${HOSTNAME_TAG}/${DIR_KEY}/${ARCHIVE_BASENAME}"
    webdav_ensure_dirs "${WEBDAV_DIR}/${HOSTNAME_TAG}/${DIR_KEY}"

    uploaded=0
    for i in {1..3}; do
      if webdav_put "$ZIP_TO_USE" "$WEBDAV_REL"; then
        log "WebDAV 上传成功（第$i次）：$WEBDAV_REL"
        uploaded=1
        break
      fi
    done
    [ "$uploaded" -eq 1 ] || { echo "WebDAV 上传失败：$WEBDAV_REL"; exit 1; }

    WEBDAV_UPLOADED_SET["$WEBDAV_REL"]=1
    mark_backend_uploaded "$DIR_KEY" "webdav" "$CUR_HASH"
  fi
done

# =========================================================
# 远端清理：七牛
# =========================================================
if [ "$ENABLE_QINIU" -eq 1 ]; then
  now_ts="$(date +%s)"
  cutoff_ts=$(( now_ts - RETENTION_HOURS*3600 ))

  qshell listbucket "$QINIU_BUCKET" | sed '1,3d' | while IFS=$'\t' read -r key type mime_size put_time; do
    [[ $key != "${QINIU_DIR}/${HOSTNAME_TAG}/"*"/"*.zip ]] && continue
    [[ -n "${QINIU_UPLOADED_SET[$key]+x}" ]] && continue

    file_local_time="$(qiniu_time_to_local "$put_time")"
    file_ts="$(date -d "$file_local_time" +%s 2>/dev/null || true)"
    [ -n "${file_ts:-}" ] || continue

    if [ "$file_ts" -lt "$cutoff_ts" ]; then
      if qshell delete "$QINIU_BUCKET" "$key" >/dev/null; then
        age_h=$(( (now_ts - file_ts) / 3600 ))
        log "已删除七牛过期文件：$key（${age_h}h）"
      fi
    fi
  done
fi

# =========================================================
# 远端清理：WebDAV
# =========================================================
if [ "$ENABLE_WEBDAV" -eq 1 ]; then
  now_ts="$(date +%s)"
  cutoff_ts=$(( now_ts - RETENTION_HOURS*3600 ))

  mapfile -t UNIQUE_DIR_KEYS < <(
    for SOURCE_DIR in "${SOURCE_DIRS[@]}"; do
      SOURCE_DIR="${SOURCE_DIR%/}"
      [ -d "$SOURCE_DIR" ] || continue
      DIR_NAME="$(basename "$SOURCE_DIR")"
      DIR_HASH="$(printf "%s" "$SOURCE_DIR" | sha1sum | awk '{print $1}' | cut -c1-8)"
      echo "${DIR_NAME}-${DIR_HASH}"
    done | awk '!seen[$0]++'
  )

  for DIR_KEY in "${UNIQUE_DIR_KEYS[@]}"; do
    remote_dir_rel="${WEBDAV_DIR}/${HOSTNAME_TAG}/${DIR_KEY}/"

    while IFS=$'\t' read -r name lastmod; do
      [ -z "${name:-}" ] && continue
      [ -z "${lastmod:-}" ] && continue
      [[ "$name" != *.zip ]] && continue

      remote_rel="${WEBDAV_DIR}/${HOSTNAME_TAG}/${DIR_KEY}/${name}"
      [[ -n "${WEBDAV_UPLOADED_SET[$remote_rel]+x}" ]] && continue

      file_ts="$(TZ=$TIMEZONE date -d "$lastmod" +%s 2>/dev/null || true)"
      [ -n "${file_ts:-}" ] || continue

      if [ "$file_ts" -lt "$cutoff_ts" ]; then
        webdav_delete "$remote_rel"
        age_h=$(( (now_ts - file_ts) / 3600 ))
        log "已删除 WebDAV 过期文件：$remote_rel（${age_h}h）"
      fi
    done < <(webdav_list_zip_with_lastmod "$remote_dir_rel" || true)
  done
fi

# =========================================================
# 本地清理（按 RETENTION_HOURS）
# =========================================================
find "$DEST_DIR" -type f -name "*.zip" -mmin +$((RETENTION_HOURS*60)) -delete && \
  log "本地过期文件清理完成"

unset PASSWORD
unset WEBDAV_PASS
echo -e "\n[$(date)] \e[32m所有操作完成，保留时长：${RETENTION_HOURS}小时\e[0m"
