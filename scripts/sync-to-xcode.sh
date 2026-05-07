#!/bin/bash
# 自动同步 Sources/ 下的修改到 Xcode 项目目录

SOURCES_DIR="${PROJECT_ROOT}/Sources"
XCODE_DIR="${PROJECT_ROOT}/app_dock/app_dock"
FILE_PATH="$1"

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

# 只处理 Sources 目录下的文件
if [[ "$FILE_PATH" != "$SOURCES_DIR/"* ]]; then
    exit 0
fi

# 只处理 .swift 文件
if [[ "$FILE_PATH" != *.swift ]]; then
    exit 0
fi

# 获取相对于 Sources 的路径
REL_PATH="${FILE_PATH#$SOURCES_DIR/}"
DEST_PATH="$XCODE_DIR/$REL_PATH"
DEST_DIR=$(dirname "$DEST_PATH")

# 确保目标目录存在
mkdir -p "$DEST_DIR"

# 复制文件
cp "$FILE_PATH" "$DEST_PATH"
echo "[sync] $REL_PATH -> Xcode project"
