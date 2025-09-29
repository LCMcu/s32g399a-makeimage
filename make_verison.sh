#!/bin/bash

# 默认配置文件路径
CONFIG_FILE="version.config"
# 输出文件
OUTPUT_FILE="image_version"

# 获取当前日期和时间
CURRENT_DATE=$(date +"%Y-%m-%d")
CURRENT_TIME=$(date +"%H:%M:%S %Z")
TIMESTAMP="Generated on: $CURRENT_DATE $CURRENT_TIME"

# 创建或清空输出文件
echo "$TIMESTAMP" > "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# 检查配置文件是否存在
if [ -f "$CONFIG_FILE" ]; then
    echo "Image Configuration:" >> "$OUTPUT_FILE"
    # 读取配置文件并追加内容
    while IFS= read -r line; do
        # 跳过空行
        [ -z "$line" ] && continue
        echo "$line" >> "$OUTPUT_FILE"
    done < "$CONFIG_FILE"
else
    echo "No config file found at $CONFIG_FILE. Only timestamp will be written."
fi

# 输出结果
echo "Generated $OUTPUT_FILE with the following content:"
cat "$OUTPUT_FILE"

# 检查文件大小
echo "Size of $OUTPUT_FILE: $(stat -f %z "$OUTPUT_FILE") bytes"