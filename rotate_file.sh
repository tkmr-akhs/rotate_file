#!/usr/bin/env bash
#
# GNU/Linux (GNU date/df/find 前提) で動作する、
# 「空き容量」と「最終更新日時」を条件に SRC_DIR から DEST_DIR へ
# 古いファイルを移動するためのスクリプトです。
#
# 詳細な使い方は、以下の HELP_TEXT および `-h` 出力を参照してください。

set -uo pipefail

########################################
# ドキュメント / ヘルプテキスト
########################################
SCRIPT_NAME="$(basename "$0")"
read -r -d '' HELP_TEXT <<'EOF'
Usage: {{SCRIPT_NAME}} -s SRC_DIR -d DEST_DIR [-b BYTES|-p PERCENT|-m MTIME] [options]

概要:
  SRC_DIR にあるファイルのうち、以下の条件のいずれかを満たすものを
  最終更新日時が古い順に DEST_DIR へ移動します。

    (1) 最終更新日時 < -m で指定した閾値
    (2) 空き容量    < -b/-p で指定した閾値

必須:
  -s SRC_DIR       対象ディレクトリ
  -d DEST_DIR      移動先ディレクトリ
  少なくとも以下のどれかを指定してください:
    -b BYTES       空き容量閾値 (Bytes)
                   例: 5368709120 (空き容量がこのBytes未満なら条件成立)
    -p PERCENT     空き容量閾値 (総サイズに対する割合)
                   例: 20 (総サイズの20%をバイト換算し、空き容量がそれ未満なら条件成立)
    -m MTIME       最終更新日時閾値 (GNU date -d で解釈可能な文字列)
                   例: "2025-11-01" や "2025-11-01 00:00:00"
  ※ -b と -p は同時に指定できません

任意:
  -r FILE_REGEX    ファイル名(basename)に対する POSIX 拡張正規表現。
                   デフォルト: ^[^.].*  （.で始まらない名前）
  -v               デバッグ出力を有効にする
  -h               このヘルプを表示

出力:
  - 移動したファイルパスのみ stdout に1行ずつ出力されます。
  - INFO / DEBUG / ERROR はすべて stderr に出力されます。

注意:
  - -b/-p が指定されている場合、SRC_DIR と DEST_DIR が同一パーティション上にあると
    空き容量は増えないためエラーになります。
EOF

########################################
# 環境設定
########################################
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LANG=C

########################################
# ログ関数（全部 stderr）
########################################
DEBUG=0

log_info()  { echo "INFO: $*" >&2; }
log_error() { echo "ERROR: $*" >&2; }
debug_log() { [ "$DEBUG" -eq 1 ] && echo "DEBUG: $*" >&2; }

syntax_error() {
  # 構文・オプション指定ミス専用
  log_error "$*（詳細は -h を参照してください）"
  exit 1
}

usage() {
  # ヘルプは stdout にのみ出力
  printf '%s\n' "${HELP_TEXT//\{\{SCRIPT_NAME\}\}/$SCRIPT_NAME}"
}

########################################
# ユーティリティ
########################################
get_free_bytes()  { df --output=avail -B1 "$SRC_DIR" 2>/dev/null | awk 'NR==2{print $1}'; }
get_total_bytes() { df --output=size  -B1 "$SRC_DIR" 2>/dev/null | awk 'NR==2{print $1}'; }

########################################
# オプション処理
########################################
SRC_DIR=""
DEST_DIR=""
FILE_REGEX="^[^.].*"     # デフォルト: .で始まらないすべてのファイル名

MIN_FREE_BYTES=""        # -b: 空き容量閾値 (Bytes)
MIN_FREE_PCT=""          # -p: 空き容量閾値 (%)
TIME_THRESHOLD_EPOCH=""  # -m: mtime 閾値 (epoch秒)
TIME_RAW=""

while getopts ":s:d:b:p:m:r:vh" opt; do
  case "$opt" in
    s) SRC_DIR="$OPTARG" ;;
    d) DEST_DIR="$OPTARG" ;;
    b)
      if [ -n "$MIN_FREE_PCT" ]; then
        syntax_error "-b と -p は同時に指定できません"
      fi
      if ! printf '%s\n' "$OPTARG" | grep -Eq '^[0-9]+$'; then
        syntax_error "-b のバイト指定が不正です: $OPTARG"
      fi
      MIN_FREE_BYTES="$OPTARG"
      ;;
    p)
      if [ -n "$MIN_FREE_BYTES" ]; then
        syntax_error "-b と -p は同時に指定できません"
      fi
      if ! printf '%s\n' "$OPTARG" | grep -Eq '^[0-9]+$'; then
        syntax_error "-p の割合指定が不正です: $OPTARG"
      fi
      MIN_FREE_PCT="$OPTARG"
      ;;
    m)
      TIME_RAW="$OPTARG"
      if [ -z "$TIME_RAW" ]; then
        syntax_error "-m の値が空です"
      fi
      EPOCH="$(date -d "$TIME_RAW" +%s 2>/dev/null || true)"
      if ! printf '%s\n' "$EPOCH" | grep -Eq '^[0-9]+$'; then
        syntax_error "-m で指定された日時を解釈できません: $TIME_RAW"
      fi
      TIME_THRESHOLD_EPOCH="$EPOCH"
      debug_log "-m 解析結果: raw='${TIME_RAW}', epoch='${TIME_THRESHOLD_EPOCH}'"
      ;;
    r)
      FILE_REGEX="$OPTARG"
      ;;
    v)
      DEBUG=1
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      syntax_error "不明なオプションです: -$OPTARG"
      ;;
    :)
      syntax_error "オプション -$OPTARG には値が必要です"
      ;;
  esac
done

########################################
# 必須チェック
########################################
if [ -z "$SRC_DIR" ] || [ -z "$DEST_DIR" ]; then
  syntax_error "-s SRC_DIR と -d DEST_DIR は必須です"
fi

if [ -z "$MIN_FREE_BYTES" ] && [ -z "$MIN_FREE_PCT" ] && [ -z "$TIME_THRESHOLD_EPOCH" ]; then
  syntax_error "-b, -p, -m のいずれかを指定してください"
fi

########################################
# ディレクトリチェック
########################################
if [ ! -d "$SRC_DIR" ]; then
  log_error "SRC_DIR '$SRC_DIR' が存在しません"
  exit 1
fi

if [ ! -d "$DEST_DIR" ]; then
  log_error "DEST_DIR '$DEST_DIR' が存在しません"
  exit 1
fi

# 同一ディレクトリチェック
if [ "$SRC_DIR" -ef "$DEST_DIR" ]; then
  log_error "SRC_DIR と DEST_DIR が同じディレクトリです"
  exit 1
fi

########################################
# %指定があれば Bytes に変換（DEBUG 出力）
########################################
if [ -n "$MIN_FREE_PCT" ]; then
  TOTAL_BYTES="$(get_total_bytes || true)"
  if ! printf '%s\n' "$TOTAL_BYTES" | grep -Eq '^[0-9]+$'; then
    log_error "ファイルシステム総サイズの取得に失敗しました (SRC_DIR: $SRC_DIR)"
    exit 1
  fi
  MIN_FREE_BYTES=$(( TOTAL_BYTES * MIN_FREE_PCT / 100 ))
  debug_log "空き容量閾値 ${MIN_FREE_PCT}% → ${MIN_FREE_BYTES} Bytes (総サイズ: ${TOTAL_BYTES} Bytes)"
fi

########################################
# -b/-p 指定がある場合のみパーティションチェック & 初期空き容量計算
########################################
NEED_BYTES=0
if [ -n "$MIN_FREE_BYTES" ]; then
  SRC_FS=$(df -P "$SRC_DIR" 2>/dev/null | awk 'NR==2{print $1}')
  DEST_FS=$(df -P "$DEST_DIR" 2>/dev/null | awk 'NR==2{print $1}')

  if [ -z "$SRC_FS" ] || [ -z "$DEST_FS" ]; then
    log_error "パーティション情報の取得に失敗しました (SRC_DIR='$SRC_DIR', DEST_DIR='$DEST_DIR')"
    exit 1
  fi

  if [ "$SRC_FS" = "$DEST_FS" ]; then
    log_error "-b/-p が指定されていますが、SRC_DIR と DEST_DIR は同じパーティション上にあります (${SRC_FS})"
    log_error "空き容量を増やす目的であれば、異なるパーティションを指定してください"
    exit 1
  fi

  FREE_INITIAL="$(get_free_bytes || true)"
  if ! printf '%s\n' "$FREE_INITIAL" | grep -Eq '^[0-9]+$'; then
    log_error "初期空き容量の取得に失敗しました (SRC_DIR: $SRC_DIR)"
    exit 1
  fi

  NEED_BYTES=$(( MIN_FREE_BYTES - FREE_INITIAL ))
  debug_log "初期空き容量: ${FREE_INITIAL} Bytes, 閾値: ${MIN_FREE_BYTES} Bytes, 追加で必要な容量: ${NEED_BYTES} Bytes"

  if [ "$NEED_BYTES" -le 0 ]; then
    log_info "すでに空き容量が閾値以上のため、ファイル移動は行いません"
    exit 0
  fi
fi

########################################
# ファイル一覧取得（古い順）
# FILE_REGEX は basename 用 → '.*/$FILE_REGEX' としてフルパスにマッチさせる
########################################
EFFECTIVE_REGEX=".*/${FILE_REGEX}"

mapfile -t CANDIDATES < <(
  find "$SRC_DIR" \
    -maxdepth 1 \
    -type f \
    -regextype posix-extended \
    -regex "$EFFECTIVE_REGEX" \
    -printf '%T@ %s %p\n' 2>/dev/null \
  | sort -n
)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  log_info "対象ファイルがありません (FILE_REGEX='${FILE_REGEX}')"
  exit 0
fi

log_info "処理開始: SRC='${SRC_DIR}', DEST='${DEST_DIR}', FILE_REGEX='${FILE_REGEX}'"

########################################
# メインループ
########################################
for entry in "${CANDIDATES[@]}"; do
  # entry: "<mtime> <size> <path>"
  ts="${entry%% *}"
  rest="${entry#* }"
  size="${rest%% *}"
  file="${rest#* }"

  ts_sec="${ts%%.*}"
  [ -z "$ts_sec" ] && ts_sec="$ts"

  older=false
  space_low=false

  # mtime 閾値チェック
  if [ -n "$TIME_THRESHOLD_EPOCH" ] && [ "$ts_sec" -lt "$TIME_THRESHOLD_EPOCH" ]; then
    older=true
  fi

  # 空き容量閾値チェック（-b/-p 指定時のみ）
  # NEED_BYTES > 0 の間は「まだ容量が足りない」→ space_low=true
  if [ -n "$MIN_FREE_BYTES" ] && [ "$NEED_BYTES" -gt 0 ]; then
    space_low=true
  fi

  # 前提:
  #  - ファイルは mtime 昇順
  #  - このスクリプトでファイルを移動しない限り空き容量は変わらない
  # ここで older=false かつ space_low=false になったら、
  # 以降のファイルはすべて条件を満たさないため break で打ち切る。
  if [ "$older" = false ] && [ "$space_low" = false ]; then
    debug_log "条件を満たさないファイル '$file' に到達したため以降の処理を打ち切り (ts_sec=${ts_sec}, NEED_BYTES=${NEED_BYTES})"
    break
  fi

  if mv -- "$file" "$DEST_DIR/"; then
    if [ -n "$MIN_FREE_BYTES" ]; then
      # このファイルサイズ分だけ空き容量が増えるとみなす
      NEED_BYTES=$(( NEED_BYTES - size ))
      # 推定現在空き容量（ブロックサイズ等による誤差は許容）
      EST_FREE=$(( MIN_FREE_BYTES - NEED_BYTES ))
      log_info "移動: $file (older=${older}, space_low=${space_low}, size=${size} Bytes, 推定空き容量=${EST_FREE} Bytes, 閾値=${MIN_FREE_BYTES} Bytes)"
    else
      log_info "移動: $file (older=${older}, size=${size} Bytes)"
    fi
    # xargs 等のために「移動したファイル名だけ」を stdout に出す
    printf '%s\n' "$file"
  else
    log_error "移動失敗: $file"
  fi
done

log_info "処理完了"
exit 0
