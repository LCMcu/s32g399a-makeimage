#!/bin/bash

# 脚本名称：make_embedded_linux_image.sh
# 描述：从配置文件读取镜像总大小、各子镜像的偏移、大小（以16进制字节表示）和存放位置信息，生成嵌入式Linux镜像。
#       子镜像包括：BL2、FIP、Uboot、Kernel、DTB、Rootfs。
#       支持在指定偏移地址插入内容，覆盖原有数据。
# 假设：
#   - 配置文件格式为键值对，例如：
#     TOTAL_SIZE=0x100000000
#     BL2_OFFSET=0x0
#     BL2_SIZE=0x100000
#     BL2_PATH=/path/to/bl2.bin
#     CUSTOM_INSERTS=insert1:0x5000:/path/to/insert.bin:0x1000,insert2:0x6000:/path/to/another.bin:0x2000
#     ... (以此类推)
#   - 大小和偏移以16进制字节表示（以0x开头）
#   - 子镜像文件路径和插入内容文件路径可以是绝对或相对路径
# 使用方法：./make_embedded_linux_image.sh config.ini output_image.bin

# 检查参数
if [ $# -ne 2 ]; then
    echo "Usage: $0 <config_file> <output_image>"
    exit 1
fi

CONFIG_FILE="$1"
OUTPUT_IMAGE="$2"

# 读取配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file '$CONFIG_FILE' not found!"
    exit 1
fi

source "$CONFIG_FILE"

# 检查所需变量是否定义
required_vars=("TOTAL_SIZE")
sub_components=("BL2" "FIP" "UBOOT" "KERNEL" "DTB" "ROOTFS")
for comp in "${sub_components[@]}"; do
    required_vars+=("${comp}_OFFSET" "${comp}_SIZE" "${comp}_PATH")
done

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Missing variable '$var' in config file!"
        exit 1
    fi
done

# 检查子镜像文件是否存在
for comp in "${sub_components[@]}"; do
    path_var="${comp}_PATH"
    file="${!path_var}"
    if [ ! -f "$file" ]; then
        echo "Error: Sub-image file '$file' for $comp not found!"
        exit 1
    fi
done

# 验证大小和偏移是否为有效的16进制数
for var in "${required_vars[@]}"; do
    if [[ "$var" == *_SIZE || "$var" == *_OFFSET || "$var" == TOTAL_SIZE ]]; then
        if ! [[ "${!var}" =~ ^0x[0-9a-fA-F]+$ ]]; then
            echo "Error: $var ('${!var}') must be a valid hexadecimal number (e.g., 0x1000)!"
            exit 1
        fi
    fi
done

# 检查 CUSTOM_INSERTS（可选）
if [ -n "$CUSTOM_INSERTS" ]; then
    IFS=',' read -r -a inserts <<< "$CUSTOM_INSERTS"
    for insert in "${inserts[@]}"; do
        IFS=':' read -r name offset path size <<< "$insert"
        if [ -z "$name" ] || [ -z "$offset" ] || [ -z "$path" ] || [ -z "$size" ]; then
            echo "Error: Invalid CUSTOM_INSERTS format for '$insert'. Expected: name:offset:path:size"
            exit 1
        fi
        if ! [[ "$offset" =~ ^0x[0-9a-fA-F]+$ && "$size" =~ ^0x[0-9a-fA-F]+$ ]]; then
            echo "Error: Offset or size in '$insert' must be valid hexadecimal numbers!"
            exit 1
        fi
        if [ ! -f "$path" ]; then
            echo "Error: Insert file '$path' for '$name' not found!"
            exit 1
        fi
    done
fi

# 函数：将16进制转换为十进制
hex_to_dec() {
    local hex_value="$1"
    # 移除0x前缀并转换为十进制
    echo $((16#${hex_value#0x}))
}

# 创建初始镜像文件（零填充到总大小）
total_size_dec=$(hex_to_dec "$TOTAL_SIZE")
echo "Creating initial image file: $OUTPUT_IMAGE with size $TOTAL_SIZE ($total_size_dec bytes)"
dd if=/dev/zero of="$OUTPUT_IMAGE" bs=1 count=0 seek="$total_size_dec" status=progress
if [ $? -ne 0 ]; then
    echo "Error: Failed to create initial image!"
    exit 1
fi

# 函数：将子镜像写入指定偏移
write_sub_image() {
    local sub_name="$1"
    local offset_var="${sub_name}_OFFSET"
    local size_var="${sub_name}_SIZE"
    local path_var="${sub_name}_PATH"
    local offset_hex="${!offset_var}"
    local size_hex="${!size_var}"
    local file="${!path_var}"
    local offset_dec=$(hex_to_dec "$offset_hex")
    local size_dec=$(hex_to_dec "$size_hex")

    echo "Writing $sub_name from $file to offset $offset_hex ($offset_dec bytes) with size $size_hex ($size_dec bytes)"
    dd if="$file" of="$OUTPUT_IMAGE" bs=1 seek="$offset_dec" count="$size_dec" conv=notrunc status=progress
    if [ $? -ne 0 ]; then
        echo "Error: Failed to write $sub_name!"
        exit 1
    fi
}

# 函数：插入内容到指定偏移
write_custom_insert() {
    local name="$1"
    local offset_hex="$2"
    local file="$3"
    local size_hex="$4"
    local offset_dec=$(hex_to_dec "$offset_hex")
    local size_dec=$(hex_to_dec "$size_hex")

    echo "Inserting $name from $file to offset $offset_hex ($offset_dec bytes) with size $size_hex ($size_dec bytes)"
    dd if="$file" of="$OUTPUT_IMAGE" bs=1 seek="$offset_dec" count="$size_dec" conv=notrunc status=progress
    if [ $? -ne 0 ]; then
        echo "Error: Failed to insert $name!"
        exit 1
    fi
}

# 依次写入子镜像
for comp in "${sub_components[@]}"; do
    write_sub_image "$comp"
done

# 处理自定义插入（如果有）
if [ -n "$CUSTOM_INSERTS" ]; then
    IFS=',' read -r -a inserts <<< "$CUSTOM_INSERTS"
    for insert in "${inserts[@]}"; do
        IFS=':' read -r name offset path size <<< "$insert"
        write_custom_insert "$name" "$offset" "$path" "$size"
    done
fi

echo "Embedded Linux image created successfully: $OUTPUT_IMAGE"