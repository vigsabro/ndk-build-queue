#!/bin/bash
set -e

# !!! ВАЖНО: замени строку ниже на свой домен PythonAnywhere перед загрузкой !!!
BOT_DOMAIN="yourname.pythonanywhere.com"

FILE=$(git diff --name-only HEAD~1 HEAD -- uploads/ | head -n1)
if [ -z "$FILE" ]; then
  FILE=$(git show --name-only --pretty="" HEAD -- uploads/ | head -n1)
fi
BASENAME=$(basename "$FILE")
CHATID=$(echo "$BASENAME" | cut -d'_' -f1)
NDK_VER=$(echo "$BASENAME" | cut -d'_' -f3 | sed 's/\.zip$//')
if [ "$NDK_VER" != "r16b" ] && [ "$NDK_VER" != "r21e" ] && [ "$NDK_VER" != "r25c" ]; then
  NDK_VER="r25c"
fi

send_message() {
  curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d chat_id="$CHATID" -d text="$1" > /dev/null
}

report_result() {
  # $1 = success | failed, $2 = file_id (опционально), $3 = file_name (опционально)
  curl -s -X POST "https://$BOT_DOMAIN/build_result" \
    -d chat_id="$CHATID" -d status="$1" -d type="jni" \
    -d file_id="${2:-}" -d file_name="${3:-}" > /dev/null || true
}

# Удаляем обработанный zip из репозитория (Contents API, атомарно, без git push/pull).
# [skip ci] в сообщении коммита не даёт этому же удалению повторно запустить сборку.
cleanup_repo_file() {
  BLOB_SHA=$(git rev-parse "HEAD:$FILE" 2>/dev/null || true)
  if [ -n "$BLOB_SHA" ]; then
    curl -s -X DELETE \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/contents/$FILE" \
      -d "{\"message\":\"cleanup: remove processed jni upload [skip ci]\",\"sha\":\"$BLOB_SHA\",\"branch\":\"builds\"}" \
      > /dev/null || true
  fi
}
trap cleanup_repo_file EXIT

fail() {
  send_message "$1"
  report_result "failed"
  exit 1
}

START_TS=$(date +%s)

send_message "1️⃣ Файл успешно загружен. Ваша задача добавлена в очередь."

case "$NDK_VER" in
  r16b)
    NDK_URL="https://dl.google.com/android/repository/android-ndk-r16b-linux-x86_64.zip"
    NDK_DIR="$HOME/android-ndk-r16b"
    NDK_LABEL="NDK r16b"
    ;;
  r21e)
    NDK_URL="https://dl.google.com/android/repository/android-ndk-r21e-linux-x86_64.zip"
    NDK_DIR="$HOME/android-ndk-r21e"
    NDK_LABEL="NDK r21e"
    ;;
  *)
    NDK_URL="https://dl.google.com/android/repository/android-ndk-r25c-linux.zip"
    NDK_DIR="$HOME/android-ndk-r25c"
    NDK_LABEL="NDK r25c"
    ;;
esac

if ! curl -fsSL -o ndk.zip "$NDK_URL"; then
  fail "Не удалось скачать $NDK_LABEL."
fi
unzip -q ndk.zip -d "$HOME"

mkdir -p project
if ! unzip -q "$FILE" -d project; then
  fail "Не удалось распаковать архив."
fi

if [ ! -f project/jni/Android.mk ]; then
  fail "В архиве не найдена папка jni/Android.mk."
fi

# Определяем архитектуры из Application.mk: если указаны обе - собираем обе,
# если только одна - собираем только её. Если Application.mk отсутствует или
# ни одна из известных ABI не найдена - собираем обе по умолчанию.
APP_MK="project/jni/Application.mk"
ABIS=""
if [ -f "$APP_MK" ]; then
  grep -q "arm64-v8a" "$APP_MK" && ABIS="$ABIS arm64-v8a"
  grep -q "armeabi-v7a" "$APP_MK" && ABIS="$ABIS armeabi-v7a"
fi
ABIS=$(echo "$ABIS" | xargs)
if [ -z "$ABIS" ]; then
  ABIS="arm64-v8a armeabi-v7a"
fi

cd project
BUILD_LOG=$(mktemp)
if ! "$NDK_DIR/ndk-build" -j"$(nproc)" NDK_PROJECT_PATH=. APP_BUILD_SCRIPT=jni/Android.mk APP_ABI="$ABIS" > "$BUILD_LOG" 2>&1; then
  cd ..
  TAIL=$(tail -c 1500 "$BUILD_LOG")
  fail $'Ошибка компиляции. Лог сборки:\n\n'"$TAIL"
fi
cd ..

cd project/libs
zip -rq ../../build_libs.zip .
cd ../..

END_TS=$(date +%s)
DURATION=$((END_TS - START_TS))
MM=$((DURATION / 60))
SS=$((DURATION % 60))

send_message "✅ Компиляция завершена!
📦 Архитектуры: $(echo "$ABIS" | tr ' ' ',')
⚙️ NDK: $NDK_LABEL
⏱️ Время сборки: ${MM}м ${SS}с"

SEND_RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" \
  -F chat_id="$CHATID" -F document=@build_libs.zip)

# Достаём file_id только что отправленного документа, чтобы потом его можно
# было переслать другим через кнопку "Поделиться результатом" (inline mode).
RESULT_FILE_ID=$(echo "$SEND_RESPONSE" | jq -r '.result.document.file_id // empty')

report_result "success" "$RESULT_FILE_ID" "build_libs.zip"
