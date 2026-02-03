#!/bin/bash

if [ $# -ne 5 ]; then
  echo "Usage: $0 <prefix> <suffix> <start> <finish> <size>"
  echo "  <start>  : 起点（日数前）"
  echo "  <finish> : 終点（日数前）"
  echo "  <size>   : 各ファイルのサイズ（バイト）"
  exit 1
fi

PREFIX="$1"
SUFFIX="$2"
START="$3"
FINISH="$4"
SIZE="$5"

NOW_TIME=$(date +%H:%M:%S)

for i in $(seq "$START" "$FINISH"); do
  DATE=$(date -d "$i day ago" +%Y%m%d)
  FILE="${PREFIX}-${DATE}${SUFFIX}"
  : > "$FILE"
  fallocate -l "$SIZE" "$FILE"
  touch -m -d "$DATE $NOW_TIME" "$FILE"
done
