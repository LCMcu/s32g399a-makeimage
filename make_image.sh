#!/bin/bash

# 脚本名称：make_embedded_linux_image.sh
# 描述：从配置文件读取镜像总大小、各子镜像的偏移、大小（以16进制字节表示）和存放位置信息，生成嵌入式Linux镜像。
#       子镜像包括：BL2、FIP、Uboot、Kernel、DTB、ROOTFS、Work。
#       支持在指定偏移地址插入内容，覆盖原有数据（通过 CUSTOM_INSERTS）。
#       未配置的区域填充为 0。
#       在生成镜像时计算子镜像的 CRC32 校验值，存储到 Image-Info 分区（通过 JFFS2 镜像）。
#       额外计算 Image-Info 分区之前（0x0 - IMAGE_INFO_OFFSET）的整体 CRC32 值（ImageInfo_Before）。
#       记录镜像制作时间（东八区）到 image_version 文件。
#       将生成的镜像和 image_info 文本文件移动到以 zk_s32g399a_YYYYMMDD_HHMMSS_{debug,release} 命名的文件夹。
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
#     CUSTOM_INSERTS=insert1:0x5000:/path/to/insert.bin:0x1000
#   - 大小和偏移以16进制字节表示（以0x开头）
#   - 子镜像文件路径和插入内容文件路径可以是绝对或相对路径
# 使用方法：./make_embedded_linux_image.sh [-D|-R] <config_file>
#   -D: Debug 版本
#   -R: Release 版本
# 输出文件夹：zk_s32g399a_YYYYMMDD_HHMMSS_{debug,release}/
# 输出文件名：zk_s32g399a_YYYYMMDD_HHMMSS_{debug,release}.image
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

# 生成输出文件名和目标文件夹
OUTPUT_IMAGE="zk_s32g399a_${CURRENT_TIMESTAMP}_${RELEASE_TYPE}.image"
IMAGE_INFO_TXT="zk_s32g399a_${CURRENT_TIMESTAMP}_${RELEASE_TYPE}_image_info.txt"
OUTPUT_DIR="zk_s32g399a_${CURRENT_TIMESTAMP}_${RELEASE_TYPE}"

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

# 如果 CUSTOM_INSERTS 存在，计算其 CRC
if [ -n "$CUSTOM_INSERTS" ]; then
    IFS=',' read -r -a inserts <<< "$CUSTOM_INSERTS"
    for insert in "${inserts[@]}"; do
        IFS=':' read -r name offset path size <<< "$insert"
        crc_value=$(crc32 "$path")
        echo "$name=$crc_value" >> "$CRC_FILE"
        echo "  $name ($path): CRC32=$crc_value"
    done
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
IMAGE_INFO_OFFSET="0x3f00000"  # Image-Info 偏移
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

# 函数：填充未配置区域为 0
fill_unallocated_regions() {
    local total_size=$1
    local regions=()

    # 收集所有已配置的区域
    for comp in "${sub_components[@]}"; do
        offset_var="${comp}_OFFSET"
        size_var="${comp}_SIZE"
        offset_dec=$(hex_to_dec "${!offset_var}")
        size_dec=$(hex_to_dec "${!size_var}")
        regions+=("$offset_dec:$size_dec")
    done

    # 添加 CUSTOM_INSERTS 和 image_info.jffs2 的区域
    if [ -n "$CUSTOM_INSERTS" ]; then
        IFS=',' read -r -a inserts <<< "$CUSTOM_INSERTS"
        for insert in "${inserts[@]}"; do
            IFS=':' read -r name offset path size <<< "$insert"
            offset_dec=$(hex_to_dec "$offset")
            size_dec=$(hex_to_dec "$size")
            regions+=("$offset_dec:$size_dec")
        done
    fi

    # 按偏移量排序
    IFS=$'\n' sorted_regions=($(for r in "${regions[@]}"; do echo "$r"; done | sort -n -t ':' -k 1))
    
    # 检查并填充未分配区域
    local current_pos=0
    for region in "${sorted_regions[@]}"; do
        IFS=':' read -r offset size <<< "$region"
        if [ $current_pos -lt $offset ]; then
            local gap_size=$((offset - current_pos))
            echo "Filling unallocated region from $current_pos to $offset ($gap_size bytes) with zeros"
            dd if=/dev/zero of="$OUTPUT_IMAGE" bs=1 seek="$current_pos" count="$gap_size" conv=notrunc status=progress
            if [ $? -ne 0 ]; then
                echo "Error: Failed to fill unallocated region at $current_pos!"
                exit 1
            fi
        fi
        current_pos=$((offset + size))
    done

    # 检查镜像末尾是否需要填充
    if [ $current_pos -lt $total_size ]; then
        local gap_size=$((total_size - current_pos))
        echo "Filling unallocated region from $current_pos to $total_size ($gap_size bytes) with zeros"
        dd if=/dev/zero of="$OUTPUT_IMAGE" bs=1 seek="$current_pos" count="$gap_size" conv=notrunc status=progress
        if [ $? -ne 0 ]; then
            echo "Error: Failed to fill unallocated region at $current_pos!"
            exit 1
        fi
    fi
}

# 依次写入子镜像
for comp in "${sub_components[@]}"; do
    write_sub_image "$comp"
done

# 处理自定义插入（包括 image_info.jffs2）
if [ -n "$CUSTOM_INSERTS" ]; then
    IFS=',' read -r -a inserts <<< "$CUSTOM_INSERTS"
    for insert in "${inserts[@]}"; do
        IFS=':' read -r name offset path size <<< "$insert"
        write_custom_insert "$name" "$offset" "$path" "$size"
    done
fi

# 填充未配置区域为 0
echo "Filling unallocated regions with zeros..."
fill_unallocated_regions "$total_size_dec"

# 计算 Image-Info 分区之前的 CRC32（0x0 - IMAGE_INFO_OFFSET）
image_info_offset_dec=$(hex_to_dec "$IMAGE_INFO_OFFSET")
TEMP_IMAGE="temp_image_info.bin"
echo "Generating CRC32 for data before Image-Info partition (0x0 - $IMAGE_INFO_OFFSET)..."
dd if="$OUTPUT_IMAGE" of="$TEMP_IMAGE" bs=1 count="$image_info_offset_dec" status=progress
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract data for ImageInfo_Before CRC!"
    rm -f "$TEMP_IMAGE"
    exit 1
fi
image_info_crc=$(crc32 "$TEMP_IMAGE")
echo "ImageInfo_Before=$image_info_crc" >> "$CRC_FILE"
echo "  Data before Image-Info (0x0 - $IMAGE_INFO_OFFSET): CRC32=$image_info_crc"
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

# 重新写入 image_info.jffs2
write_custom_insert "image_info" "$IMAGE_INFO_OFFSET" "$IMAGE_INFO_JFFS2" "$IMAGE_INFO_SIZE"

# 清理临时文件
rm -f "$IMAGE_VERSION_FILE" "$CRC_FILE" "$IMAGE_INFO_JFFS2"
rm -rf image_info

# 创建目标输出文件夹
echo "Creating output directory: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
if [ $? -ne 0 ]; then
    echo "Error: Failed to create output directory '$OUTPUT_DIR'!"
    exit 1
fi

# 验证文件夹是否存在
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: Output directory '$OUTPUT_DIR' was not created!"
    exit 1
fi

# 移动生成的镜像和 image_info 文本文件到目标文件夹
echo "Moving $OUTPUT_IMAGE to $OUTPUT_DIR/"
mv "$OUTPUT_IMAGE" "$OUTPUT_DIR/"
if [ $? -ne 0 ]; then
    echo "Error: Failed to move $OUTPUT_IMAGE to $OUTPUT_DIR!"
    exit 1
fi
echo "Moving $IMAGE_INFO_TXT to $OUTPUT_DIR/"
mv "$IMAGE_INFO_TXT" "$OUTPUT_DIR/"
if [ $? -ne 0 ]; then
    echo "Error: Failed to move $IMAGE_INFO_TXT to $OUTPUT_DIR!"
    exit 1
fi

echo "Embedded Linux image created successfully: $OUTPUT_DIR/$OUTPUT_IMAGE"
echo "Image info text file moved to: $OUTPUT_DIR/$IMAGE_INFO_TXT"