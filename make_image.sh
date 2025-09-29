#!/bin/bash

# 脚本名称：make_embedded_linux_image.sh
# 描述：从配置文件读取镜像总大小、各子镜像的偏移、大小（以16进制字节表示）和存放位置信息，生成嵌入式Linux镜像。
#       子镜像包括：BL2、FIP、Uboot、Kernel、DTB、ROOTFS、Work。
#       支持在指定偏移地址插入内容，覆盖原有数据，包括可选的 PFE 分区。
#       在生成镜像时计算子镜像的 CRC32 校验值，存储到 Image-Info 分区（通过 JFFS2 镜像）。
#       额外计算从 BL2 到 Work 分区（0x0 - 0x3810000）的整体 CRC32 值，命名为 BL2_TO_WORK。
#       记录镜像制作时间（东八区）到 image_version 文件。
# 假设：
#   - 配置文件格式为键值对，例如：
#     TOTAL_SIZE=0x4000000
#     BL2_OFFSET=0x0
#     BL2_SIZE=0xd0000
#     BL2_PATH=/path/to/bl2.bin
#     ROOTFS_OFFSET=0x14e0000
#     ROOTFS_SIZE=0x200000
#     ROOTFS_PATH=/path/to/rootfs.jffs2
#     WORK_OFFSET=0x3410000
#     WORK_SIZE=0x400000
#     WORK_PATH=/path/to/work.jffs2
#     PFE_OFFSET=0x33f0000
#     PFE_SIZE=0x20000
#     PFE_PATH=/path/to/pfe.bin
#     CUSTOM_INSERTS=insert1:0x5000:/path/to/insert.bin:0x1000
#   - 大小和偏移以16进制字节表示（以0x开头）
#   - 子镜像文件路径和插入内容文件路径可以是绝对或相对路径
#   - PFE 分区为可选，若未定义 PFE_OFFSET、PFE_SIZE、PFE_PATH，则不处理
# 使用方法：./make_embedded_linux_image.sh [-D|-R] <config_file>
#   -D: Debug 版本
#   -R: Release 版本
# 输出文件名：zk_s32g399a_YYYYMMDD_HHMMSS_debug.image 或 zk_s32g399a_YYYYMMDD_HHMMSS_release.image
# Image-Info 文本文件名：zk_s32g399a_YYYYMMDD_HHMMSS_{debug,release}_image_info.txt

# 检查参数
if [ $# -ne 2 ]; then
    echo "Usage: $0 [-D|-R] <config_file>"
    exit 1
fi

# 处理发行参数
case "$1" in
    -D)
        RELEASE_TYPE="debug"
        ;;
    -R)
        RELEASE_TYPE="release"
        ;;
    *)
        echo "Error: First argument must be -D (Debug) or -R (Release)!"
        exit 1
        ;;
esac

CONFIG_FILE="$2"

# 确保 crc32 和 mkfs.jffs2 工具可用
if ! command -v crc32 >/dev/null 2>&1; then
    echo "Error: crc32 tool not found. Please install libarchive or equivalent."
    exit 1
fi

if ! command -v mkfs.jffs2 >/dev/null 2>&1; then
    echo "Error: mkfs.jffs2 tool not found. Please install mtd-utils."
    exit 1
fi

# 读取配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file '$CONFIG_FILE' not found!"
    exit 1
fi

source "$CONFIG_FILE"

# 检查所需变量是否定义
required_vars=("TOTAL_SIZE")
sub_components=("BL2" "FIP" "UBOOT" "KERNEL" "DTB" "ROOTFS" "WORK")
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

# 检查 PFE 分区（可选）
if [ -n "$PFE_OFFSET" ] && [ -n "$PFE_SIZE" ] && [ -n "$PFE_PATH" ]; then
    if [ ! -f "$PFE_PATH" ]; then
        echo "Error: PFE file '$PFE_PATH' not found!"
        exit 1
    fi
    if ! [[ "$PFE_OFFSET" =~ ^0x[0-9a-fA-F]+$ && "$PFE_SIZE" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo "Error: PFE_OFFSET or PFE_SIZE must be valid hexadecimal numbers!"
        exit 1
    fi
    if [ -z "$CUSTOM_INSERTS" ]; then
        CUSTOM_INSERTS="pfe:$PFE_OFFSET:$PFE_PATH:$PFE_SIZE"
    else
        CUSTOM_INSERTS="$CUSTOM_INSERTS,pfe:$PFE_OFFSET:$PFE_PATH:$PFE_SIZE"
    fi
fi

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

# 强制使用东八区（Asia/Shanghai）时区
export TZ=Asia/Shanghai

# 获取当前日期和时间（东八区）用于文件名和 image_version
CURRENT_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
IMAGE_VERSION_TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S +0800")

# 生成输出文件名
OUTPUT_IMAGE="zk_s32g399a_${CURRENT_TIMESTAMP}_${RELEASE_TYPE}.image"
IMAGE_INFO_TXT="zk_s32g399a_${CURRENT_TIMESTAMP}_${RELEASE_TYPE}_image_info.txt"

# 生成 image_version 文件
IMAGE_VERSION_FILE="image_version.txt"
echo "Generated on: $IMAGE_VERSION_TIMESTAMP" > "$IMAGE_VERSION_FILE"
echo "Release Type: $RELEASE_TYPE" >> "$IMAGE_VERSION_FILE"

# 生成 CRC 校验文件
CRC_FILE="image_info_crc.txt"
echo "Generating CRC32 values for sub-images..."
> "$CRC_FILE"
for comp in "${sub_components[@]}"; do
    path_var="${comp}_PATH"
    file="${!path_var}"
    crc_value=$(crc32 "$file")
    echo "$comp=$crc_value" >> "$CRC_FILE"
    echo "  $comp ($file): CRC32=$crc_value"
done

# 如果 PFE 分区存在，计算其 CRC
if [ -n "$PFE_PATH" ]; then
    crc_value=$(crc32 "$PFE_PATH")
    echo "PFE=$crc_value" >> "$CRC_FILE"
    echo "  PFE ($PFE_PATH): CRC32=$crc_value"
fi

# 合并 image_version.txt 和 image_info_crc.txt 到 IMAGE_INFO_TXT
cat "$IMAGE_VERSION_FILE" "$CRC_FILE" > "$IMAGE_INFO_TXT"

# 创建 image_info 文件夹并复制 IMAGE_INFO_TXT
rm -rf image_info
mkdir -p image_info
cp "$IMAGE_INFO_TXT" image_info/

# 使用 mkfs.jffs2 生成 image_info.jffs2（填充到 1MB = 0x100000）
IMAGE_INFO_JFFS2="image_info.jffs2"
echo "Generating JFFS2 image for Image-Info partition..."
mkfs.jffs2 -d image_info/ -o "$IMAGE_INFO_JFFS2" -e 0x10000 --pad 0x100000 --verbose
if [ $? -ne 0 ]; then
    echo "Error: Failed to generate image_info.jffs2!"
    exit 1
fi

# 更新 CUSTOM_INSERTS，添加 image_info.jffs2
IMAGE_INFO_OFFSET="0x3f00000"  # 新 Image-Info 偏移
IMAGE_INFO_SIZE="0x100000"     # 1MB
if [ -n "$CUSTOM_INSERTS" ]; then
    CUSTOM_INSERTS="$CUSTOM_INSERTS,image_info:$IMAGE_INFO_OFFSET:$IMAGE_INFO_JFFS2:$IMAGE_INFO_SIZE"
else
    CUSTOM_INSERTS="image_info:$IMAGE_INFO_OFFSET:$IMAGE_INFO_JFFS2:$IMAGE_INFO_SIZE"
fi

echo "Generated $IMAGE_VERSION_FILE and $CRC_FILE with the following content:"
cat "$IMAGE_VERSION_FILE"
echo "---"
cat "$CRC_FILE"

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

# 处理自定义插入（包括 image_info.jffs2 和可选的 PFE）
if [ -n "$CUSTOM_INSERTS" ]; then
    IFS=',' read -r -a inserts <<< "$CUSTOM_INSERTS"
    for insert in "${inserts[@]}"; do
        IFS=':' read -r name offset path size <<< "$insert"
        write_custom_insert "$name" "$offset" "$path" "$size"
    done
fi

# 计算 BL2 到 Work 分区的 CRC32（0x0 - 0x3810000）
RESERVED_OFFSET="0x3810000"
reserved_offset_dec=$(hex_to_dec "$RESERVED_OFFSET")
TEMP_IMAGE="temp_bl2_to_work.bin"
echo "Generating CRC32 for data from BL2 to Work (0x0 - $RESERVED_OFFSET)..."
dd if="$OUTPUT_IMAGE" of="$TEMP_IMAGE" bs=1 count="$reserved_offset_dec" status=progress
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract data for BL2 to Work CRC!"
    rm -f "$TEMP_IMAGE"
    exit 1
fi
bl2_to_work_crc=$(crc32 "$TEMP_IMAGE")
echo "BL2_TO_WORK=$bl2_to_work_crc" >> "$CRC_FILE"
echo "  Data from BL2 to Work (0x0 - $RESERVED_OFFSET): CRC32=$bl2_to_work_crc"
rm -f "$TEMP_IMAGE"

# 重新生成 IMAGE_INFO_TXT 以包含新的 CRC
cat "$IMAGE_VERSION_FILE" "$CRC_FILE" > "$IMAGE_INFO_TXT"

# 重新创建 image_info 文件夹并复制 IMAGE_INFO_TXT
rm -rf image_info
mkdir -p image_info
cp "$IMAGE_INFO_TXT" image_info/

# 重新生成 image_info.jffs2 以包含更新后的 IMAGE_INFO_TXT
echo "Regenerating JFFS2 image for Image-Info partition with updated CRC..."
mkfs.jffs2 -d image_info/ -o "$IMAGE_INFO_JFFS2" -e 0x10000 --pad 0x100000 --verbose
if [ $? -ne 0 ]; then
    echo "Error: Failed to regenerate image_info.jffs2!"
    exit 1
fi

# 清理临时文件
rm -f "$IMAGE_VERSION_FILE" "$CRC_FILE" "$IMAGE_INFO_JFFS2"
rm -rf image_info

echo "Embedded Linux image created successfully: $OUTPUT_IMAGE"
echo "Image info text file retained locally: $IMAGE_INFO_TXT"