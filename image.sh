#!/bin/bash

# =====================================================================
# 二次元图片下载器 v5.0
# 功能：多线程下载二次元图片，支持多种API格式，智能解析JSON响应
# 特点：
#   - 集成 Python 通用 JSON 解析器
#   - 支持自定义记录字段
#   - 多线程下载
#   - 代理支持
#   - 分组管理
#   - 自动重试机制
# =====================================================================

# -------------------------------
# 全局变量配置
# -------------------------------
VERSION="5.0"                                 # 脚本版本
DOWNLOAD_INTERRUPTED=0                        # 下载中断标志

# 平台检测和文件路径
if [ -n "$TERMUX_VERSION" ]; then             # Termux 安卓环境
    BASE_DIR="/storage/emulated/0"
else                                          # 标准 Linux 环境
    BASE_DIR="$HOME/.downloader"
    mkdir -p "$BASE_DIR"
fi

# 文件路径定义
API_FILE="$BASE_DIR/api_list.txt"             # API 列表文件
CONFIG_FILE="$BASE_DIR/downloader_config.txt" # 配置文件
DEFAULT_SAVE_DIR="$BASE_DIR/downloads/"       # 默认保存目录
URL_LOG_FILE="$BASE_DIR/downloaded_urls.log"  # 下载记录文件
PYTHON_PARSER="$BASE_DIR/json_parser.py"      # Python 解析器路径

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m' # 重置颜色

# -------------------------------
# 信号处理函数
# -------------------------------

# 下载中断处理
interrupt_download() {
    DOWNLOAD_INTERRUPTED=1
    echo -e "\n${RED}下载中断请求已接收，正在停止所有下载任务...${NC}"
    echo -e "${YELLOW}注意：正在进行的下载将继续完成${NC}"
}

# -------------------------------
# 初始化函数
# -------------------------------

# 初始化 API 文件
initialize_api_file() {
    [ ! -f "$API_FILE" ] && touch "$API_FILE"
}

# 清理临时文件
clean_temp_files() {
    find /tmp -name 'downloading_*' -mmin "+$LOG_RETENTION" -delete
}

# 初始化 Python 解析器
initialize_python_parser() {
    # 检查 Python 解析器是否存在，不存在则创建
    if [ ! -f "$PYTHON_PARSER" ]; then
        cat << 'PYTHON_SCRIPT' > "$PYTHON_PARSER"
#!/usr/bin/env python3
"""
通用 JSON 解析器 - 适配所有 API 格式
支持复杂嵌套结构、数组索引和动态字段提取
"""
import sys
import json
import re
import logging
from typing import Any, Dict, List, Optional, Union

# 配置日志
logging.basicConfig(level=logging.ERROR, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def extract_value(data: Any, path: str) -> str:
    """
    根据路径表达式从嵌套数据结构中提取值
    
    支持格式:
      - 点分隔路径: user.profile.name
      - 数组索引: images[0].url
      - 通配符: images[*].url (返回第一个匹配项)
      - 多级嵌套: data.attributes.image.large.url
    
    返回字符串表示，对于复杂类型返回 JSON 字符串
    """
    if not path or not data:
        return ""
    
    try:
        # 分割路径为多个部分
        parts = re.split(r'\.|\[', path)
        parts = [p.replace(']', '') for p in parts if p]
        
        current = data
        
        for part in parts:
            # 处理数组索引
            if ']' in part:
                part = part.replace(']', '')
            
            # 处理通配符 *
            if part == '*':
                if isinstance(current, list) and len(current) > 0:
                    current = current[0]
                    continue
                elif isinstance(current, dict) and len(current) > 0:
                    current = next(iter(current.values()))
                    continue
                else:
                    return ""
            
            # 处理数组索引 [n]
            if re.match(r'^\d+$', part):
                index = int(part)
                if isinstance(current, list) and 0 <= index < len(current):
                    current = current[index]
                else:
                    return ""
            # 处理字典键
            elif isinstance(current, dict) and part in current:
                current = current[part]
            # 尝试数字索引
            elif isinstance(current, list) and re.match(r'^\d+$', part):
                index = int(part)
                if 0 <= index < len(current):
                    current = current[index]
                else:
                    return ""
            else:
                # 尝试不区分大小写匹配
                found = False
                if isinstance(current, dict):
                    for key in current.keys():
                        if key.lower() == part.lower():
                            current = current[key]
                            found = True
                            break
                if not found:
                    return ""
        
        # 转换结果为字符串
        if current is None:
            return ""
        elif isinstance(current, (str, int, float, bool)):
            return str(current)
        elif isinstance(current, (list, dict)):
            return json.dumps(current, ensure_ascii=False)
        else:
            return str(current)
    
    except Exception as e:
        logger.error(f"提取值错误: {path} - {str(e)}")
        return ""

def find_image_url(data: Any, image_key: str) -> str:
    """智能查找图片 URL，支持多种常见格式"""
    # 1. 使用用户指定的键路径
    if image_key:
        url = extract_value(data, image_key)
        if url and url.startswith(('http://', 'https://')):
            return url
    
    # 2. 尝试常见图片 URL 字段
    common_image_keys = [
        'url', 'image_url', 'image', 'src', 'link',
        'image.url', 'images[0].url', 'data.url',
        'large_url', 'medium_url', 'small_url',
        'original_url', 'high_resolution_url',
        'file_url', 'image_urls.large', 'urls.regular',
        'imageUrl', 'pictureUrl', 'imagePath',
        'img_url', 'image_src', 'img_src'
    ]
    
    for key in common_image_keys:
        url = extract_value(data, key)
        if url and url.startswith(('http://', 'https://')):
            return url
    
    # 3. 深度搜索可能的 URL
    def deep_search(obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if isinstance(v, str) and v.startswith(('http://', 'https://')) and any(ext in v for ext in ['.jpg', '.jpeg', '.png', '.gif', '.webp']):
                    return v
                result = deep_search(v)
                if result:
                    return result
        elif isinstance(obj, list):
            for item in obj:
                result = deep_search(item)
                if result:
                    return result
        return None
    
    url = deep_search(data)
    return url if url else ""

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 json_parser.py '<json_data>' '<image_key>' [<custom_keys>]")
        sys.exit(1)
    
    # 获取参数
    json_data = sys.argv[1]
    image_key = sys.argv[2]
    custom_keys = sys.argv[3].split(';') if len(sys.argv) > 3 else []
    
    try:
        # 解析 JSON 数据
        data = json.loads(json_data)
        
        # 查找图片 URL
        image_url = find_image_url(data, image_key)
        
        # 提取自定义字段
        custom_fields = {}
        for key in custom_keys:
            if key:
                value = extract_value(data, key)
                custom_fields[key] = value
        
        # 构建结果
        result = {
            "image_url": image_url,
            "custom_fields": custom_fields
        }
        
        # 输出 JSON 格式的结果
        print(json.dumps(result, ensure_ascii=False))
    
    except json.JSONDecodeError as e:
        logger.error(f"JSON 解析错误: {str(e)}")
        print('{"error": "Invalid JSON format"}')
        sys.exit(1)
    except Exception as e:
        logger.error(f"未知错误: {str(e)}")
        print('{"error": "Unexpected error"}')
        sys.exit(1)

if __name__ == "__main__":
    main()
PYTHON_SCRIPT
        chmod +x "$PYTHON_PARSER"
        echo -e "${GREEN}Python 解析器已初始化${NC}"
    fi
}

# 检查系统依赖
check_dependencies() {
    local missing=()
    
    # 检查 Python3
    if ! command -v python3 &>/dev/null; then
        missing+=("Python3")
    fi
    
    # 检查 curl
    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}警告：缺少以下依赖: ${missing[*]}${NC}"
        echo -e "${YELLOW}部分功能可能受限，建议安装:${NC}"
        
        if [[ -n "$TERMUX_VERSION" ]]; then
            echo -e "${CYAN}在 Termux 中安装: pkg install ${missing[*]}${NC}"
        else
            if command -v apt &>/dev/null; then
                echo -e "${CYAN}在 Debian/Ubuntu 中安装: sudo apt install ${missing[*]}${NC}"
            elif command -v yum &>/dev/null; then
                echo -e "${CYAN}在 CentOS/RHEL 中安装: sudo yum install ${missing[*]}${NC}"
            elif command -v dnf &>/dev/null; then
                echo -e "${CYAN}在 Fedora 中安装: sudo dnf install ${missing[*]}${NC}"
            else
                echo -e "${CYAN}请手动安装: ${missing[*]}${NC}"
            fi
        fi
        read -p "按回车键继续..." 
    fi
}

# -------------------------------
# 配置管理函数
# -------------------------------

# 加载配置
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        # 默认配置
        SAVE_DIR="$DEFAULT_SAVE_DIR"
        THREAD_COUNT=4
        LOG_RETENTION=24
        AUTO_RETRY="yes"
        PROXY_URL=""
        LOG_URLS="yes"
        printf "SAVE_DIR=\"%s\"\nTHREAD_COUNT=%d\nLOG_RETENTION=%d\nAUTO_RETRY=\"%s\"\nPROXY_URL=\"%s\"\nLOG_URLS=\"%s\"\n" \
            "$SAVE_DIR" "$THREAD_COUNT" "$LOG_RETENTION" "$AUTO_RETRY" "$PROXY_URL" "$LOG_URLS" > "$CONFIG_FILE"
    fi
    mkdir -p "$SAVE_DIR"
    clean_temp_files
}

# 更新配置
update_config() {
    printf "SAVE_DIR=\"%s\"\nTHREAD_COUNT=%d\nLOG_RETENTION=%d\nAUTO_RETRY=\"%s\"\nPROXY_URL=\"%s\"\nLOG_URLS=\"%s\"\n" \
        "$SAVE_DIR" "$THREAD_COUNT" "$LOG_RETENTION" "$AUTO_RETRY" "$PROXY_URL" "$LOG_URLS" > "$CONFIG_FILE"
}

# 设置代理
set_proxy() {
    echo -e "当前代理设置: ${BLUE}${PROXY_URL:-无}${NC}"
    read -p "请输入新的代理URL (格式: http://proxy:port 或 socks5://proxy:port，留空表示不使用代理): " new_proxy
    if [ -n "$new_proxy" ]; then
        # 验证代理格式
        if [[ "$new_proxy" =~ ^(http|socks5)://.+:[0-9]+$ ]]; then
            PROXY_URL="$new_proxy"
            echo -e "${GREEN}代理已设置为: $PROXY_URL${NC}"
        else
            echo -e "${RED}错误：无效的代理格式！请使用 http://proxy:port 或 socks5://proxy:port 格式${NC}"
            return 1
        fi
    else
        PROXY_URL=""
        echo -e "${GREEN}已禁用代理${NC}"
    fi
    update_config
}

# 设置 URL 记录
set_url_logging() {
    echo -e "当前URL记录设置: ${BLUE}$LOG_URLS${NC}"
    read -p "是否记录下载图片的原始URL？(yes/no): " new_log
    new_log="${new_log,,}"
    [[ "$new_log" != "yes" && "$new_log" != "no" ]] && { 
        echo -e "${RED}错误：无效选择！请输入 yes 或 no。${NC}"; 
        return 1; 
    }
    LOG_URLS="$new_log"
    update_config
    echo -e "${GREEN}URL记录已更新为: $LOG_URLS${NC}"
}

# 设置保存目录
set_save_directory() {
    echo -e "当前保存目录: ${BLUE}$SAVE_DIR${NC}"
    read -p "请输入新的保存目录路径: " new_dir
    new_dir="${new_dir%/}/"
    if mkdir -p "$new_dir" 2>/dev/null; then
        SAVE_DIR="$new_dir"
        update_config
        echo -e "${GREEN}保存目录已更新为: $SAVE_DIR${NC}"
    else
        echo -e "${RED}错误：无法创建目录 '$new_dir'！请检查权限或路径是否正确。${NC}"
        return 1
    fi
}

# 设置线程数
set_thread_count() {
    local cpu_cores=$(nproc 2>/dev/null || echo 4)
    local max_threads=$((cpu_cores + 2))
    echo -e "当前线程数: ${BLUE}$THREAD_COUNT${NC}"
    echo -e "推荐线程数: ${BLUE}$cpu_cores${NC} (基于 CPU 核心数: $cpu_cores)"
    read -p "请输入新的线程数 (1-$max_threads): " new_count
    [[ ! "$new_count" =~ ^[0-9]+$ ]] && { echo -e "${RED}错误：无效的线程数！请输入数字。${NC}"; return 1; }
    ((new_count < 1 || new_count > max_threads)) && { echo -e "${RED}错误：线程数必须在 1-$max_threads 之间！${NC}"; return 1; }
    THREAD_COUNT=$new_count
    update_config
    echo -e "${GREEN}线程数已更新为: $THREAD_COUNT${NC}"
}

# 设置日志保留时间
set_log_retention() {
    echo -e "当前日志保留时间: ${BLUE}$LOG_RETENTION 小时${NC}"
    read -p "请输入新的保留时间 (1-168 小时): " new_retention
    [[ ! "$new_retention" =~ ^[0-9]+$ ]] && { echo -e "${RED}错误：无效的保留时间！请输入数字。${NC}"; return 1; }
    ((new_retention < 1 || new_retention > 168)) && { echo -e "${RED}错误：保留时间必须在 1-168 小时之间！${NC}"; return 1; }
    LOG_RETENTION=$new_retention
    update_config
    echo -e "${GREEN}日志保留时间已更新为: $LOG_RETENTION 小时${NC}"
}

# 设置自动重试
set_auto_retry() {
    echo -e "当前自动重试设置: ${BLUE}$AUTO_RETRY${NC}"
    read -p "是否启用自动重试？(yes/no): " new_retry
    new_retry="${new_retry,,}"
    [[ "$new_retry" != "yes" && "$new_retry" != "no" ]] && { echo -e "${RED}错误：无效选择！请输入 yes 或 no。${NC}"; return 1; }
    AUTO_RETRY="$new_retry"
    update_config
    echo -e "${GREEN}自动重试已更新为: $AUTO_RETRY${NC}"
}

# -------------------------------
# 分组管理函数
# -------------------------------

# 获取所有分组
get_all_groups() {
    declare -A group_map
    while IFS='|' read -r _ _ _ _ _ group; do
        [[ -z "$group" ]] && group="默认"
        group_map["$group"]=1
    done < "$API_FILE"
    
    # 如果没有分组，添加默认分组
    [[ ${#group_map[@]} -eq 0 ]] && group_map["默认"]=1
    
    # 按字母顺序排序分组
    for group in "${!group_map[@]}"; do
        echo "$group"
    done | sort
}

# 分组管理菜单
group_management_menu() {
    while true; do
        clear
        echo -e "${PURPLE}========================================\n      分组管理\n========================================${NC}"
        
        # 获取所有分组
        declare -a groups
        mapfile -t groups < <(get_all_groups)
        
        # 统计每个分组的API数量
        declare -A group_counts
        while IFS='|' read -r _ _ _ _ _ group; do
            [[ -z "$group" ]] && group="默认"
            ((group_counts[$group]++))
        done < "$API_FILE"
        
        # 显示分组列表
        echo -e "${CYAN}当前分组列表：${NC}"
        local i=1
        for group in "${groups[@]}"; do
            count=${group_counts[$group]:-0}
            printf "%2d. %-20s (API 数量: %d)\n" "$i" "$group" "$count"
            ((i++))
        done
        
        echo -e "${PURPLE}========================================${NC}"
        echo -e "${YELLOW}1. 添加分组\n2. 重命名分组\n3. 删除分组\n0. 返回设置菜单${NC}"
        read -p "请选择操作: " choice
        
        case $choice in
            1) # 添加分组
                echo -e "${YELLOW}添加新分组${NC}"
                read -p "请输入新分组名称: " new_group
                [[ -z "$new_group" ]] && { echo -e "${RED}错误：分组名称不能为空！${NC}"; sleep 1; continue; }
                
                # 检查分组是否已存在
                for group in "${groups[@]}"; do
                    if [[ "$group" == "$new_group" ]]; then
                        echo -e "${RED}错误：分组 '$new_group' 已存在！${NC}"
                        sleep 1
                        continue 2
                    fi
                done
                
                # 添加新分组
                echo -e "${GREEN}已添加分组: $new_group${NC}"
                sleep 1
                ;;
                
            2) # 重命名分组
                if [[ ${#groups[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}没有可用的分组！${NC}"
                    sleep 1
                    continue
                fi
                
                echo -e "${YELLOW}重命名分组${NC}"
                read -p "请输入要重命名的分组编号 (1-${#groups[@]}): " group_num
                [[ ! "$group_num" =~ ^[0-9]+$ || "$group_num" -lt 1 || "$group_num" -gt ${#groups[@]} ]] && { 
                    echo -e "${RED}错误：无效的分组编号！${NC}"
                    sleep 1
                    continue
                }
                
                old_group="${groups[$((group_num-1))]}"
                echo -e "当前分组名称: ${BLUE}$old_group${NC}"
                read -p "请输入新的分组名称: " new_group
                [[ -z "$new_group" ]] && { echo -e "${RED}错误：分组名称不能为空！${NC}"; sleep 1; continue; }
                
                # 检查新分组名是否已存在
                for group in "${groups[@]}"; do
                    if [[ "$group" == "$new_group" ]]; then
                        echo -e "${RED}错误：分组 '$new_group' 已存在！${NC}"
                        sleep 1
                        continue 2
                    fi
                done
                
                # 重命名分组
                temp_file=$(mktemp)
                while IFS='|' read -r name url return_type json_key record_keys group; do
                    [[ "$group" == "$old_group" ]] && group="$new_group"
                    printf "%s|%s|%s|%s|%s|%s\n" "$name" "$url" "$return_type" "$json_key" "$record_keys" "$group"
                done < "$API_FILE" > "$temp_file"
                
                mv "$temp_file" "$API_FILE"
                echo -e "${GREEN}分组 '$old_group' 已重命名为 '$new_group'${NC}"
                sleep 1
                ;;
                
            3) # 删除分组
                if [[ ${#groups[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}没有可用的分组！${NC}"
                    sleep 1
                    continue
                fi
                
                echo -e "${YELLOW}删除分组${NC}"
                read -p "请输入要删除的分组编号 (1-${#groups[@]}): " group_num
                [[ ! "$group_num" =~ ^[0-9]+$ || "$group_num" -lt 1 || "$group_num" -gt ${#groups[@]} ]] && { 
                    echo -e "${RED}错误：无效的分组编号！${NC}"
                    sleep 1
                    continue
                }
                
                group_to_delete="${groups[$((group_num-1))]}"
                read -p "确认删除分组 '$group_to_delete' 及其下所有 API？(y/n): " confirm
                [[ ! "$confirm" =~ ^[Yy]$ ]] && { 
                    echo -e "${YELLOW}操作已取消${NC}"
                    sleep 1
                    continue
                }
                
                # 移动API到默认分组
                temp_file=$(mktemp)
                while IFS='|' read -r name url return_type json_key record_keys group; do
                    [[ "$group" == "$group_to_delete" ]] && group="默认"
                    printf "%s|%s|%s|%s|%s|%s\n" "$name" "$url" "$return_type" "$json_key" "$record_keys" "$group"
                done < "$API_FILE" > "$temp_file"
                
                mv "$temp_file" "$API_FILE"
                echo -e "${GREEN}分组 '$group_to_delete' 及其下所有 API 已被删除！${NC}"
                sleep 1
                ;;
                
            0) return 0;;
            *) echo -e "${RED}错误：无效选择！请输入 0-3。${NC}"; sleep 1;;
        esac
    done
}

# -------------------------------
# 设置菜单
# -------------------------------

settings_menu() {
    while true; do
        clear
        echo -e "${PURPLE}========================================\n      设置菜单\n========================================${NC}"
        echo -e "${CYAN}保存目录: ${BLUE}$SAVE_DIR${NC}"
        echo -e "${CYAN}线程数: ${BLUE}$THREAD_COUNT${NC}"
        echo -e "${CYAN}日志保留时间: ${BLUE}$LOG_RETENTION 小时${NC}"
        echo -e "${CYAN}自动重试: ${BLUE}$AUTO_RETRY${NC}"
        echo -e "${CYAN}代理设置: ${BLUE}${PROXY_URL:-无}${NC}"
        echo -e "${CYAN}URL记录: ${BLUE}$LOG_URLS${NC}"
        echo -e "${PURPLE}========================================${NC}"
        echo -e "${YELLOW}1. 设置保存目录\n2. 设置线程数\n3. 设置日志保留时间\n4. 设置自动重试\n5. 设置代理\n6. 设置URL记录\n7. 分组管理\n0. 返回主菜单${NC}"
        read -p "请选择操作: " choice
        case $choice in
            1) set_save_directory; read -p "按回车键返回...";;
            2) set_thread_count; read -p "按回车键返回...";;
            3) set_log_retention; read -p "按回车键返回...";;
            4) set_auto_retry; read -p "按回车键返回...";;
            5) set_proxy; read -p "按回车键返回...";;
            6) set_url_logging; read -p "按回车键返回...";;
            7) group_management_menu;;
            0) return 0;;
            *) echo -e "${RED}错误：无效选择！请输入 0-7。${NC}"; sleep 1;;
        esac
    done
}

# -------------------------------
# API 管理函数
# -------------------------------

# 生成 UUID 文件名
generate_uuid_filename() {
    command -v uuidgen &>/dev/null && uuidgen | tr -d '-' || tr -dc 'a-f0-9' </dev/urandom | fold -w 32 | head -n 1
}

# 列出所有 API
list_apis() {
    echo -e "${PURPLE}当前 API 列表：${NC}"
    [ ! -f "$API_FILE" ] && { echo -e "${RED}错误：API 文件不存在！请添加或导入 API。${NC}"; return 1; }
    if [ ! -s "$API_FILE" ]; then
        echo -e "${YELLOW}API 列表为空！请通过 '添加 API' 或 '导入 API 配置' 添加 API。${NC}"
        return 1
    fi
    
    # 按分组组织 API
    declare -A group_apis
    while IFS='|' read -r name url return_type json_key record_keys group; do
        [[ -z "$group" ]] && group="默认"
        group_apis["$group"]+="$name|$url|$return_type|$json_key|$record_keys|$group"$'\n'
    done < "$API_FILE"
    
    # 显示分组 API
    local group_count=0
    local api_count=0
    
    # 获取所有分组
    declare -a groups
    mapfile -t groups < <(get_all_groups)
    
    for group in "${groups[@]}"; do
        [[ -z "${group_apis[$group]}" ]] && continue
        
        group_count=$((group_count+1))
        echo -e "\n${CYAN}=== 分组: $group ===${NC}"
        
        local i=1
        while IFS='|' read -r name url return_type json_key record_keys; do
            [[ -z "$name" ]] && continue
            printf "%2d. %s - %s (返回类型: %s" "$i" "$name" "$url" "$return_type"
            [[ "$return_type" = "json" ]] && printf ", JSON键: %s" "$json_key"
            echo -e ")"
            
            # 显示记录键
            if [[ -n "$record_keys" ]]; then
                IFS=';' read -ra keys <<< "$record_keys"
                echo -e "   ${PURPLE}记录键: ${keys[*]}${NC}"
            fi
            
            i=$((i+1))
            api_count=$((api_count+1))
        done <<< "${group_apis[$group]}"
    done
    
    echo -e "\n${PURPLE}总计: ${api_count} 个 API (在 ${group_count} 个分组中)${NC}"
}

# 添加 API
add_api() {
    echo -e "${YELLOW}添加新 API${NC}"
    read -p "请输入 API 名称: " name
    [[ -z "$name" ]] && { echo -e "${RED}错误：API 名称不能为空！请输入有效名称。${NC}"; return 1; }
    read -p "请输入 API URL (以 http:// 或 https:// 开头): " url
    [[ ! "$url" =~ ^https?:// ]] && { echo -e "${RED}错误：无效的 URL 格式！请输入以 http:// 或 https:// 开头的 URL。${NC}"; return 1; }
    read -p "请输入 API 返回类型 (json/text/image，建议: json): " return_type
    return_type="${return_type,,}"
    if [[ "$return_type" == "json" ]]; then
        read -p "请输入 JSON 中的图片 URL 键名 (如: images[0].url): " json_key
        [[ -z "$json_key" ]] && { echo -e "${RED}错误：JSON 键名不能为空！请输入有效键名。${NC}"; return 1; }
    elif [[ "$return_type" == "text" || "$return_type" == "image" ]]; then
        json_key=""
    else
        echo -e "${RED}错误：无效的返回类型！请输入 json、text 或 image。${NC}"
        return 1
    fi
    
    # 获取现有分组
    declare -a groups
    mapfile -t groups < <(get_all_groups)
    
    echo -e "${CYAN}可用分组: ${groups[*]}${NC}"
    read -p "请输入分组名称 (默认为'默认'): " group
    group="${group:-默认}"
    
    # 检查分组是否存在
    local found=0
    for g in "${groups[@]}"; do
        [[ "$g" == "$group" ]] && found=1
    done
    
    [[ $found -eq 0 ]] && echo -e "${YELLOW}注意：新分组 '$group' 将被创建${NC}"
    
    # 自定义记录设置
    echo -e "${YELLOW}--- 自定义记录设置 ---${NC}"
    echo -e "格式说明: 输入JSON键路径 (如: artist.name, pictures[0].width)"
    echo -e "输入 'done' 完成设置，留空跳过"
    local record_keys=()
    while true; do
        read -p "请输入要记录的JSON键名: " key
        [[ -z "$key" ]] && break
        [[ "$key" == "done" ]] && break
        record_keys+=("$key")
        echo -e "${GREEN}已添加记录键: $key${NC}"
    done
    
    # 转换记录键数组为字符串
    local record_keys_str=$(IFS=';'; echo "${record_keys[*]}")
    
    printf "%s|%s|%s|%s|%s|%s\n" "$name" "$url" "$return_type" "$json_key" "$record_keys_str" "$group" >> "$API_FILE"
    echo -e "${GREEN}已添加 API: $name (分组: $group)${NC}"
    
    # 显示记录设置摘要
    if [[ ${#record_keys[@]} -gt 0 ]]; then
        echo -e "${CYAN}自定义记录键: ${record_keys[*]}${NC}"
    else
        echo -e "${YELLOW}未设置自定义记录${NC}"
    fi
}

# 修改 API
modify_api() {
    list_apis
    local total_apis=$(wc -l < "$API_FILE")
    [[ "$total_apis" -eq 0 ]] && { echo -e "${RED}错误：没有可用的 API！请添加或导入 API。${NC}"; return 1; }
    read -p "请输入要修改的 API 编号 (1-$total_apis): " api_num
    [[ ! "$api_num" =~ ^[0-9]+$ || "$api_num" -lt 1 || "$api_num" -gt "$total_apis" ]] && { echo -e "${RED}错误：无效的编号！请输入 1-$total_apis 的数字。${NC}"; return 1; }
    local api_line=$(awk -F'|' -v n="$api_num" 'NR==n {print $0}' "$API_FILE")
    IFS='|' read -r old_name old_url old_return_type old_json_key old_record_keys old_group <<< "$api_line"
    echo -e "${YELLOW}修改 API: $old_name${NC}"
    echo -e "当前名称: ${BLUE}$old_name${NC}"
    read -p "请输入新名称（回车保留原名称）: " name
    name="${name:-$old_name}"
    echo -e "当前 URL: ${BLUE}$old_url${NC}"
    read -p "请输入新 URL（回车保留原 URL）: " url
    url="${url:-$old_url}"
    [[ ! "$url" =~ ^https?:// ]] && { echo -e "${RED}错误：无效的 URL 格式！请输入以 http:// 或 https:// 开头的 URL。${NC}"; return 1; }
    echo -e "当前返回类型: ${BLUE}$old_return_type${NC}"
    read -p "请输入新返回类型 (json/text/image，回车保留原类型): " return_type
    return_type="${return_type:-$old_return_type}"
    return_type="${return_type,,}"
    if [[ "$return_type" == "json" ]]; then
        echo -e "当前 JSON 键名: ${BLUE}${old_json_key:-无}${NC}"
        read -p "请输入新 JSON 键名（回车保留原键名）: " json_key
        json_key="${json_key:-$old_json_key}"
        [[ -z "$json_key" ]] && { echo -e "${RED}错误：JSON 键名不能为空！请输入有效键名。${NC}"; return 1; }
    elif [[ "$return_type" == "text" || "$return_type" == "image" ]]; then
        json_key=""
    else
        echo -e "${RED}错误：无效的返回类型！请输入 json、text 或 image。${NC}"
        return 1
    fi
    
    # 获取现有分组
    declare -a groups
    mapfile -t groups < <(get_all_groups)
    
    echo -e "当前分组: ${BLUE}${old_group:-默认}${NC}"
    echo -e "${CYAN}可用分组: ${groups[*]}${NC}"
    read -p "请输入新分组名称（回车保留原分组）: " group
    group="${group:-$old_group}"
    group="${group:-默认}"
    
    # 修改记录设置
    echo -e "${YELLOW}--- 修改记录设置 ---${NC}"
    echo -e "当前记录键: ${BLUE}${old_record_keys:-无}${NC}"
    
    # 获取当前记录键
    IFS=';' read -ra old_keys <<< "$old_record_keys"
    
    echo -e "选择操作:"
    echo -e "  1. 添加新键"
    echo -e "  2. 删除现有键"
    echo -e "  3. 保留当前设置"
    echo -e "  4. 清除所有记录键"
    read -p "请选择操作 (1-4): " record_choice
    
    declare -a new_keys
    case $record_choice in
        1) # 添加新键
            new_keys=("${old_keys[@]}")
            while true; do
                read -p "请输入要添加的新键名 (留空结束): " new_key
                [[ -z "$new_key" ]] && break
                new_keys+=("$new_key")
                echo -e "${GREEN}已添加: $new_key${NC}"
            done
            ;;
        2) # 删除现有键
            if [[ ${#old_keys[@]} -eq 0 ]]; then
                echo -e "${YELLOW}没有可删除的记录键${NC}"
                new_keys=("${old_keys[@]}")
            else
                echo -e "${CYAN}当前记录键:${NC}"
                for i in "${!old_keys[@]}"; do
                    echo "  $((i+1)). ${old_keys[$i]}"
                done
                read -p "请输入要删除的键编号 (用逗号分隔): " remove_indexes
                
                IFS=',' read -ra indexes <<< "$remove_indexes"
                for idx in "${indexes[@]}"; do
                    idx=$((idx-1))
                    if [[ $idx -ge 0 && $idx -lt ${#old_keys[@]} ]]; then
                        echo -e "${YELLOW}已删除: ${old_keys[$idx]}${NC}"
                        unset 'old_keys[$idx]'
                    fi
                done
                new_keys=("${old_keys[@]}")
            fi
            ;;
        3) # 保留当前设置
            new_keys=("${old_keys[@]}")
            ;;
        4) # 清除所有记录键
            new_keys=()
            echo -e "${YELLOW}已清除所有记录键${NC}"
            ;;
        *) # 无效选择
            echo -e "${RED}错误：无效选择，保留当前记录设置${NC}"
            new_keys=("${old_keys[@]}")
            ;;
    esac
    
    # 转换新键数组为字符串
    local record_keys_str=$(IFS=';'; echo "${new_keys[*]}")
    
    # 更新 API 文件
    sed -i "${api_num}d" "$API_FILE"
    printf "%s|%s|%s|%s|%s|%s\n" "$name" "$url" "$return_type" "$json_key" "$record_keys_str" "$group" >> "$API_FILE"
    echo -e "${GREEN}已修改 API: $name (分组: $group)${NC}"
    
    # 显示新记录设置
    if [[ ${#new_keys[@]} -gt 0 ]]; then
        echo -e "${CYAN}新记录键: ${new_keys[*]}${NC}"
    else
        echo -e "${YELLOW}未设置自定义记录${NC}"
    fi
}

# 删除 API
delete_api() {
    list_apis
    local total_apis=$(wc -l < "$API_FILE")
    [[ "$total_apis" -eq 0 ]] && { echo -e "${RED}错误：没有可用的 API！请添加或导入 API。${NC}"; return 1; }
    read -p "请输入要删除的 API 编号 (1-$total_apis): " api_num
    [[ ! "$api_num" =~ ^[0-9]+$ || "$api_num" -lt 1 || "$api_num" -gt "$total_apis" ]] && { echo -e "${RED}错误：无效的编号！请输入 1-$total_apis 的数字。${NC}"; return 1; }
    local api_name=$(awk -F'|' -v n="$api_num" 'NR==n {print $1}' "$API_FILE")
    read -p "确认删除 API $api_name？(y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}操作已取消${NC}"; return 0; }
    sed -i "${api_num}d" "$API_FILE"
    echo -e "${GREEN}已删除 API: $api_name${NC}"
}

# 导入 API
import_apis() {
    echo -e "${YELLOW}导入 API 配置${NC}"
    read -p "请输入导入文件路径: " import_file
    [[ ! -f "$import_file" ]] && { echo -e "${RED}错误：文件 '$import_file' 不存在！请检查路径是否正确。${NC}"; return 1; }
    local count=0
    while IFS='|' read -r name url return_type json_key record_keys group; do
        [[ -z "$name" || -z "$url" ]] && continue
        [[ ! "$url" =~ ^https?:// ]] && continue
        [[ "$return_type" != "json" && "$return_type" != "text" && "$return_type" != "image" ]] && continue
        [[ "$return_type" == "json" && -z "$json_key" ]] && continue
        group="${group:-默认}"
        record_keys="${record_keys:-}"
        ((count++))
    done < "$import_file"
    [[ $count -eq 0 ]] && { echo -e "${RED}错误：导入文件中没有有效的 API 配置！请检查文件格式。${NC}"; return 1; }
    read -p "确认导入 $count 个 API？(y/n): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}操作已取消${NC}"; return 0; }
    while IFS='|' read -r name url return_type json_key record_keys group; do
        [[ -z "$name" || -z "$url" ]] && continue
        [[ ! "$url" =~ ^https?:// ]] && continue
        [[ "$return_type" != "json" && "$return_type" != "text" && "$return_type" != "image" ]] && continue
        [[ "$return_type" == "json" && -z "$json_key" ]] && continue
        group="${group:-默认}"
        record_keys="${record_keys:-}"
        printf "%s|%s|%s|%s|%s|%s\n" "$name" "$url" "$return_type" "$json_key" "$record_keys" "$group" >> "$API_FILE"
    done < "$import_file"
    echo -e "${GREEN}成功导入 $count 个 API！${NC}"
}

# 导出 API
export_apis() {
    echo -e "${YELLOW}导出 API 配置${NC}"
    read -p "请输入导出文件路径（默认: $BASE_DIR/api_export.txt）: " export_file
    export_file="${export_file:-$BASE_DIR/api_export.txt}"
    cp "$API_FILE" "$export_file" 2>/dev/null
    [[ $? -eq 0 ]] && echo -e "${GREEN}API 列表已导出到: $export_file${NC}" || { echo -e "${RED}错误：无法导出到 '$export_file'！请检查路径或权限。${NC}"; return 1; }
}

# -------------------------------
# JSON 解析函数 (使用 Python)
# -------------------------------

# 使用 Python 解析 JSON
parse_json_with_python() {
    local json_data="$1"
    local json_key="$2"
    local record_keys_str="$3"
    
    # 转义 JSON 数据中的特殊字符
    json_data=$(echo "$json_data" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    
    # 检查 Python 解析器是否存在
    if ! command -v python3 &>/dev/null; then
        echo -e "${RED}错误：Python3 未安装，无法使用增强的 JSON 解析功能${NC}" >&2
        return 1
    fi
    
    # 运行 Python 解析器
    local python_output=$(python3 "$PYTHON_PARSER" "$json_data" "$json_key" "$record_keys_str" 2>/dev/null)
    
    if [[ $? -ne 0 || -z "$python_output" ]]; then
        echo -e "${RED}Python 解析失败！尝试使用内置解析器${NC}" >&2
        return 1
    fi
    
    # 提取结果
    echo "$python_output"
}

# 简单 JSON 解析器 (备用)
simple_parse_json() {
    local json_data="$1"
    local key_path="$2"
    
    # 使用 jq 优先（如果可用）
    if command -v jq &>/dev/null; then
        local jq_path=$(echo "$key_path" | sed 's/\./ /g')
        echo "$json_data" | jq -r ".${jq_path}" 2>/dev/null
        return $?
    fi
    
    # 纯 Bash 解析器
    IFS='.' read -ra key_parts <<< "$key_path"
    local value=$(echo "$json_data" | grep -o "\"${key_parts[0]}\":\"[^\"]*" | cut -d'"' -f4)
    [ -n "$value" ] && echo "$value" || echo ""
}

# -------------------------------
# 下载函数
# -------------------------------

# 下载单张图片
download_single_image() {
    local api_line="$1" save_dir="$2" worker_id="$3"
    mkdir -p "$save_dir"
    IFS='|' read -r name url return_type json_key record_keys_str group <<< "$api_line"
    
    # 检查下载中断标志
    if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
        echo -e "${YELLOW}[Worker $worker_id] 下载被中断${NC}" >&2
        return 1
    fi
    
    # 构建 curl 代理参数
    local curl_proxy=""
    if [[ -n "$PROXY_URL" ]]; then
        curl_proxy="--proxy $PROXY_URL"
        echo -e "${CYAN}[Worker $worker_id] 使用代理: $PROXY_URL${NC}" >&2
    fi
    
    # 获取图片 URL
    local image_url=""
    local custom_records=""
    
    if [[ "$return_type" == "json" ]]; then
        # 获取 JSON 数据
        local json_data=$(curl -sL -m 10 $curl_proxy "$url")
        [[ -z "$json_data" ]] && { 
            echo -e "${RED}[Worker $worker_id] 错误：无法获取 JSON 数据！${NC}" >&2 
            return 1 
        }
        
        # 使用 Python 解析器
        local parser_output=$(parse_json_with_python "$json_data" "$json_key" "$record_keys_str")
        
        if [[ $? -eq 0 ]]; then
            # 提取图片 URL
            image_url=$(echo "$parser_output" | grep -o '"image_url":"[^"]*' | cut -d'"' -f4)
            
            # 提取自定义字段
            if [[ "$LOG_URLS" == "yes" && -n "$record_keys_str" ]]; then
                IFS=';' read -ra record_keys <<< "$record_keys_str"
                for key in "${record_keys[@]}"; do
                    value=$(echo "$parser_output" | grep -o "\"$key\":\"[^\"]*" | cut -d'"' -f4)
                    [[ -z "$value" ]] && value=""
                    # 简化复杂 JSON 值
                    if [[ "$value" =~ ^\{.*\}$ ]] || [[ "$value" =~ ^\[.*\]$ ]]; then
                        value=$(echo "$value" | tr -d '\n' | sed 's/  */ /g')
                    fi
                    custom_records+="|$key=$value"
                done
            fi
        else
            # 回退到简单解析器
            echo -e "${YELLOW}[Worker $worker_id] 使用内置 JSON 解析器${NC}" >&2
            image_url=$(simple_parse_json "$json_data" "$json_key")
        fi
        
        [[ -z "$image_url" ]] && { 
            echo -e "${RED}[Worker $worker_id] 错误：无法提取图片 URL！${NC}" >&2 
            return 1 
        }
        
    elif [[ "$return_type" == "text" ]]; then
        # 从文本响应获取图片 URL
        image_url=$(curl -sL -m 10 $curl_proxy "$url")
        [[ -z "$image_url" ]] && { 
            echo -e "${RED}[Worker $worker_id] 错误：无法获取图片 URL！${NC}" >&2 
            return 1 
        }
        
    elif [[ "$return_type" == "image" ]]; then
        # 直接使用 API URL
        image_url="$url"
    else
        echo -e "${RED}[Worker $worker_id] 错误：未知的返回类型！${NC}" >&2
        return 1
    fi
    
    # 检测图片格式
    local extension="jpg"  # 默认值
    
    # 1. 尝试从 URL 中提取扩展名
    if [[ "$image_url" =~ \.(jpe?g|png|gif|webp|bmp|svg)([?#]|$) ]]; then
        extension="${BASH_REMATCH[1]}"
        extension="${extension/jpeg/jpg}"  # 统一 jpeg 为 jpg
        echo -e "${CYAN}[Worker $worker_id] 从 URL 检测到格式: $extension${NC}" >&2
    else
        # 2. 尝试获取 Content-Type
        local mime_type=$(curl -sIL -m 5 $curl_proxy "$image_url" | grep -i '^content-type:' | tail -1 | cut -d'/' -f2 | cut -d';' -f1 | tr -d '[:space:]')
        [[ -n "$mime_type" ]] && mime_type="${mime_type,,}"
        
        case "$mime_type" in
            jpeg) extension="jpg";;
            png) extension="png";;
            gif) extension="gif";;
            webp) extension="webp";;
            bmp) extension="bmp";;
            svg+xml) extension="svg";;
            *) extension="jpg";;  # 未知类型使用默认
        esac
        
        if [[ -n "$mime_type" ]]; then
            echo -e "${CYAN}[Worker $worker_id] 从 Content-Type 检测到格式: $mime_type -> .$extension${NC}" >&2
        else
            echo -e "${YELLOW}[Worker $worker_id] 警告：无法检测图片格式，使用默认 .jpg${NC}" >&2
        fi
    fi
    
    # 下载图片
    echo -e "${YELLOW}[Worker $worker_id] 下载: ${BLUE}$name${NC} (格式: $extension)"
    local filename="image_$(generate_uuid_filename).$extension"
    local temp_file="$save_dir$filename.part"
    
    # 增强的重试机制
    local max_retries=3
    local retry_delay=2
    local retry_count=0
    local success=0
    
    while [[ $retry_count -lt $max_retries && $success -eq 0 ]]; do
        # 检查中断标志
        if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
            echo -e "${YELLOW}[Worker $worker_id] 下载被中断，停止重试${NC}" >&2
            # 重命名部分文件为完整文件
            if [[ -f "$temp_file" ]]; then
                mv "$temp_file" "$save_dir$filename"
                local file_size=$(stat -c%s "$save_dir$filename" 2>/dev/null)
                if [[ -n "$file_size" && "$file_size" -gt 0 ]]; then
                    echo -e "${YELLOW}[Worker $worker_id] 保留已下载的部分文件: $save_dir$filename (大小: $((file_size/1024)) KB)${NC}" >&2
                    # 记录 URL
                    if [[ "$LOG_URLS" == "yes" ]]; then
                        echo "$filename|$image_url$custom_records" >> "$URL_LOG_FILE"
                        echo -e "${CYAN}[Worker $worker_id] 已记录图片信息${NC}" >&2
                    fi
                    return 0
                else
                    rm -f "$save_dir$filename" 2>/dev/null
                fi
            fi
            return 1
        fi
        
        # 下载到临时文件
        curl -s -L -m 20 --retry 2 $curl_proxy -o "$temp_file" "$image_url"
        
        # 检查下载中断标志
        if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
            echo -e "${YELLOW}[Worker $worker_id] 下载被中断，完成当前文件${NC}" >&2
            # 重命名部分文件为完整文件
            if [[ -f "$temp_file" ]]; then
                mv "$temp_file" "$save_dir$filename"
                local file_size=$(stat -c%s "$save_dir$filename" 2>/dev/null)
                if [[ -n "$file_size" && "$file_size" -gt 0 ]]; then
                    echo -e "${YELLOW}[Worker $worker_id] 保留已下载的部分文件: $save_dir$filename (大小: $((file_size/1024)) KB)${NC}" >&2
                    # 记录 URL
                    if [[ "$LOG_URLS" == "yes" ]]; then
                        echo "$filename|$image_url$custom_records" >> "$URL_LOG_FILE"
                        echo -e "${CYAN}[Worker $worker_id] 已记录图片信息${NC}" >&2
                    fi
                    return 0
                else
                    rm -f "$save_dir$filename" 2>/dev/null
                fi
            fi
            return 1
        fi
        
        # 验证文件有效性
        local file_size=$(stat -c%s "$temp_file" 2>/dev/null)
        if [[ -z "$file_size" || "$file_size" -lt 1024 ]]; then
            echo -e "${YELLOW}[Worker $worker_id] 错误：下载文件过小 ($file_size 字节)，重试中...${NC}" >&2 
            rm -f "$temp_file" 2>/dev/null
            ((retry_count++))
            sleep $retry_delay
            continue
        fi
        
        # 检测 HTML 内容
        if head -c 100 "$temp_file" | grep -q -E '<!DOCTYPE html>|<html>|<head>'; then
            echo -e "${YELLOW}[Worker $worker_id] 警告：检测到 HTML 内容（可能是错误页面），重试中...${NC}" >&2 
            rm -f "$temp_file" 2>/dev/null
            ((retry_count++))
            sleep $retry_delay
            continue
        fi
        
        # 检测二进制文件签名
        if [[ "$extension" != "svg" ]]; then
            if ! file "$temp_file" | grep -q -E 'image|bitmap|icon|SVG'; then
                echo -e "${YELLOW}[Worker $worker_id] 警告：文件签名不匹配，重试中...${NC}" >&2 
                rm -f "$temp_file" 2>/dev/null
                ((retry_count++))
                sleep $retry_delay
                continue
            fi
        fi
        
        # 验证通过，重命名为最终文件名
        mv "$temp_file" "$save_dir$filename"
        success=1
    done
    
    if [[ $success -eq 1 ]]; then
        local file_size=$(stat -c%s "$save_dir$filename" 2>/dev/null)
        echo -e "${GREEN}[Worker $worker_id] 下载完成: ${BLUE}$save_dir$filename${NC} (大小: $((file_size/1024)) KB)"
        
        # 记录图片信息
        if [[ "$LOG_URLS" == "yes" ]]; then
            echo "$filename|$image_url$custom_records" >> "$URL_LOG_FILE"
            echo -e "${CYAN}[Worker $worker_id] 已记录图片信息${NC}" >&2
            
            # 在控制台显示记录信息
            if [[ -n "$custom_records" ]]; then
                echo -e "${PURPLE}记录信息:${NC}"
                IFS='|' read -ra parts <<< "$custom_records"
                for part in "${parts[@]:1}"; do  # 跳过第一个空元素
                    echo "  $part"
                done
            fi
        fi
        
        return 0
    else
        echo -e "${RED}[Worker $worker_id] 下载失败: ${BLUE}$image_url${NC} (重试 $max_retries 次后失败)" >&2 
        rm -f "$temp_file" 2>/dev/null
        rm -f "$save_dir$filename" 2>/dev/null
        return 1
    fi
}

# 多线程下载单个 API
download_images_multithread() {
    # 重置中断标志
    DOWNLOAD_INTERRUPTED=0
    # 注册中断处理
    trap interrupt_download SIGINT
    
    local api_line="$1" download_times="$2" save_dir="$SAVE_DIR"
    local start_time=$(date +%s)
    IFS='|' read -r name _ <<< "$api_line"
    
    echo -e "${PURPLE}☆ 开始多线程下载 API: $name (线程数: $THREAD_COUNT, 总次数: $download_times) ☆${NC}"
    echo -e "${YELLOW}提示: 按 Ctrl+C 可中断下载${NC}"
    local success_count=0 failed_count=0
    local active_jobs=0 index=0
    declare -A pids
    
    # 创建任务队列
    for ((i = 0; i < download_times; i++)); do
        # 检查中断标志
        if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
            echo -e "${YELLOW}用户中断，停止启动新任务。${NC}"
            break
        fi
        
        while true; do
            # 检查中断标志
            if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
                break 2
            fi
            
            # 检查是否有空闲线程
            if (( active_jobs < THREAD_COUNT )); then
                # 启动新任务
                ((index++))
                download_single_image "$api_line" "$save_dir" $index &
                pids[$index]=$!
                ((active_jobs++))
                echo -e "${CYAN}启动任务 $index/$download_times (活动任务: $active_jobs)${NC}"
                break
            fi
            
            # 等待任何任务完成
            for pid_index in "${!pids[@]}"; do
                if ! kill -0 "${pids[$pid_index]}" 2>/dev/null; then
                    # 任务已完成
                    wait "${pids[$pid_index]}" 2>/dev/null
                    if [[ $? -eq 0 ]]; then
                        ((success_count++))
                    else
                        ((failed_count++))
                    fi
                    unset pids[$pid_index]
                    ((active_jobs--))
                    
                    # 显示进度
                    local total_completed=$((success_count + failed_count))
                    local progress=$((total_completed * 100 / download_times))
                    echo -e "${YELLOW}进度: $total_completed/$download_times ($progress%) 成功: $success_count 失败: $failed_count${NC}"
                fi
            done
            
            # 短暂休眠避免 CPU 占用过高
            sleep 0.1
        done
    done
    
    # 等待所有剩余任务完成
    for pid_index in "${!pids[@]}"; do
        # 检查中断标志
        if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
            echo -e "${YELLOW}下载中断，等待当前任务完成...${NC}"
            # 等待进程完成而不杀死它
            wait "${pids[$pid_index]}" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                ((success_count++))
            else
                ((failed_count++))
            fi
            continue
        fi
        
        wait "${pids[$pid_index]}" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            ((success_count++))
        else
            ((failed_count++))
        fi
    done
    
    # 重置信号处理
    trap - SIGINT
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    
    if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
        echo -e "${RED}☆ 下载被中断！已下载: $success_count, 失败: $failed_count, 耗时: $elapsed 秒 ☆${NC}"
        # 重置中断标志
        DOWNLOAD_INTERRUPTED=0
        return 1
    else
        echo -e "${GREEN}☆ 所有图片下载完成！成功: $success_count, 失败: $failed_count, 耗时: $elapsed 秒 ☆${NC}"
    fi
    
    # 自动重试
    if [[ "$AUTO_RETRY" == "yes" && $failed_count -gt 0 ]]; then
        echo -e "${YELLOW}自动重试失败任务...${NC}"
        download_images_multithread "$api_line" "$failed_count" "$save_dir"
    fi
}

# 多 API 下载
download_multi_apis() {
    # 重置中断标志
    DOWNLOAD_INTERRUPTED=0
    # 注册中断处理
    trap interrupt_download SIGINT
    
    list_apis
    local total_apis=$(wc -l < "$API_FILE")
    [[ "$total_apis" -eq 0 ]] && { 
        trap - SIGINT
        echo -e "${RED}错误：没有可用的 API！请添加或导入 API。${NC}"; 
        return 1; 
    }
    
    read -p "请输入要使用的 API 编号（用逗号分隔，如 1,3,5）: " api_nums
    IFS=',' read -ra api_num_array <<< "$api_nums"
    local valid_apis=()
    
    # 验证 API 编号
    for num in "${api_num_array[@]}"; do
        num=$(echo "$num" | tr -d ' ')
        [[ ! "$num" =~ ^[0-9]+$ || "$num" -lt 1 || "$num" -gt "$total_apis" ]] && { 
            trap - SIGINT
            echo -e "${RED}错误：无效的编号 $num！请输入 1-$total_apis 的数字。${NC}"; 
            return 1; 
        }
        valid_apis+=("$num")
    done
    
    [[ ${#valid_apis[@]} -eq 0 ]] && { 
        trap - SIGINT
        echo -e "${RED}错误：未选择有效的 API！请重新输入编号。${NC}"; 
        return 1; 
    }
    
    read -p "请输入总下载次数: " download_times
    [[ ! "$download_times" =~ ^[0-9]+$ || "$download_times" -lt 1 ]] && { 
        trap - SIGINT
        echo -e "${RED}错误：无效的下载次数！请输入大于 0 的数字。${NC}"; 
        return 1; 
    }
    
    local start_time=$(date +%s)
    echo -e "${PURPLE}☆ 开始多 API 下载 (API 数量: ${#valid_apis[@]}, 线程数: $THREAD_COUNT, 总次数: $download_times) ☆${NC}"
    echo -e "${YELLOW}提示: 按 Ctrl+C 可中断下载${NC}"
    local success_count=0
    
    # 计算每个 API 的下载次数
    local per_api=$(( (download_times + ${#valid_apis[@]} - 1) / ${#valid_apis[@]} ))
    
    # 从每个 API 下载
    for num in "${valid_apis[@]}"; do
        # 检查中断标志
        if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
            echo -e "${YELLOW}用户中断，停止多 API 下载。${NC}"
            break
        fi
        
        local api_line=$(awk -F'|' -v n="$num" 'NR==n {print $0}' "$API_FILE")
        IFS='|' read -r name _ <<< "$api_line"
        echo -e "${YELLOW}下载 API: $name (目标: $per_api 次)${NC}"
        download_images_multithread "$api_line" "$per_api" "$SAVE_DIR"
        success_count=$((success_count + per_api))
    done
    
    # 重置信号处理
    trap - SIGINT
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    
    if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
        echo -e "${RED}☆ 下载被中断！已下载: $success_count, 耗时: $elapsed 秒 ☆${NC}"
        # 重置中断标志
        DOWNLOAD_INTERRUPTED=0
        return 1
    else
        echo -e "${GREEN}☆ 所有图片下载完成！成功: $success_count, 耗时: $elapsed 秒 ☆${NC}"
    fi
}

# 按分组下载
download_by_group() {
    # 重置中断标志
    DOWNLOAD_INTERRUPTED=0
    # 注册中断处理
    trap interrupt_download SIGINT
    
    list_apis
    local total_apis=$(wc -l < "$API_FILE")
    [[ "$total_apis" -eq 0 ]] && { 
        trap - SIGINT
        echo -e "${RED}错误：没有可用的 API！请添加或导入 API。${NC}"; 
        return 1; 
    }
    
    read -p "请输入要下载的分组（用逗号分隔，如 动漫,风景）: " groups
    IFS=',' read -ra group_array <<< "$groups"
    local valid_apis=()
    
    # 查找选定分组中的 API
    for group in "${group_array[@]}"; do
        group=$(echo "$group" | tr -d ' ')
        while IFS='|' read -r name url return_type json_key record_keys api_group; do
            [[ "$api_group" == "$group" ]] && valid_apis+=("$name|$url|$return_type|$json_key|$record_keys|$api_group")
        done < "$API_FILE"
    done
    
    [[ ${#valid_apis[@]} -eq 0 ]] && { 
        trap - SIGINT
        echo -e "${RED}错误：未找到匹配的分组！请检查分组名称。${NC}"; 
        return 1; 
    }
    
    read -p "请输入总下载次数: " download_times
    [[ ! "$download_times" =~ ^[0-9]+$ || "$download_times" -lt 1 ]] && { 
        trap - SIGINT
        echo -e "${RED}错误：无效的下载次数！请输入大于 0 的数字。${NC}"; 
        return 1; 
    }
    
    local start_time=$(date +%s)
    echo -e "${PURPLE}☆ 开始按分组下载 (分组: $groups, API 数量: ${#valid_apis[@]}, 总次数: $download_times) ☆${NC}"
    echo -e "${YELLOW}提示: 按 Ctrl+C 可中断下载${NC}"
    local success_count=0
    
    # 计算每个 API 的下载次数
    local per_api=$(( (download_times + ${#valid_apis[@]} - 1) / ${#valid_apis[@]} ))
    
    # 从分组中的每个 API 下载
    for api_line in "${valid_apis[@]}"; do
        # 检查中断标志
        if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
            echo -e "${YELLOW}用户中断，停止分组下载。${NC}"
            break
        fi
        
        IFS='|' read -r name _ <<< "$api_line"
        echo -e "${YELLOW}下载 API: $name (目标: $per_api 次)${NC}"
        download_images_multithread "$api_line" "$per_api" "$SAVE_DIR"
        success_count=$((success_count + per_api))
    done
    
    # 重置信号处理
    trap - SIGINT
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    
    if [[ $DOWNLOAD_INTERRUPTED -eq 1 ]]; then
        echo -e "${RED}☆ 下载被中断！已下载: $success_count, 耗时: $elapsed 秒 ☆${NC}"
        # 重置中断标志
        DOWNLOAD_INTERRUPTED=0
        return 1
    else
        echo -e "${GREEN}☆ 所有图片下载完成！成功: $success_count, 耗时: $elapsed 秒 ☆${NC}"
    fi
}

# -------------------------------
# 记录设置函数
# -------------------------------

# 显示记录设置
show_record_settings() {
    list_apis
    local total_apis=$(wc -l < "$API_FILE")
    [[ "$total_apis" -eq 0 ]] && { 
        echo -e "${RED}错误：没有可用的 API！请添加或导入 API。${NC}"; 
        return 1; 
    }
    
    read -p "请输入要查看的 API 编号 (1-$total_apis): " api_num
    [[ ! "$api_num" =~ ^[0-9]+$ || "$api_num" -lt 1 || "$api_num" -gt "$total_apis" ]] && { 
        echo -e "${RED}错误：无效的编号！请输入 1-$total_apis 的数字。${NC}"; 
        return 1; 
    }
    
    local api_line=$(awk -F'|' -v n="$api_num" 'NR==n {print $0}' "$API_FILE")
    IFS='|' read -r name url return_type json_key record_keys_str group <<< "$api_line"
    
    echo -e "\n${PURPLE}===== ${name} 记录设置 =====${NC}"
    echo -e "${CYAN}API 名称: ${BLUE}$name${NC}"
    echo -e "${CYAN}分组: ${BLUE}$group${NC}"
    echo -e "${CYAN}返回类型: ${BLUE}$return_type${NC}"
    
    if [[ -n "$record_keys_str" ]]; then
        IFS=';' read -ra record_keys <<< "$record_keys_str"
        echo -e "${CYAN}自定义记录键:${NC}"
        local i=1
        for key in "${record_keys[@]}"; do
            echo "  $i. $key"
            ((i++))
        done
    else
        echo -e "${YELLOW}未设置自定义记录${NC}"
    fi
    
    read -p "按回车键返回..."
}

# -------------------------------
# 主界面函数
# -------------------------------

# 显示头部信息
show_header() {
    clear
    echo -e "${PURPLE}========================================\n      二次元图片下载器 v$VERSION\n========================================${NC}"
    echo -e "${CYAN}保存目录: ${BLUE}$SAVE_DIR${NC}\n${CYAN}线程数: ${BLUE}$THREAD_COUNT${NC}\n${CYAN}代理设置: ${BLUE}${PROXY_URL:-无}${NC}\n${CYAN}URL记录: ${BLUE}$LOG_URLS${NC}\n${PURPLE}========================================${NC}"
}

# 主菜单
main_menu() {
    load_config
    initialize_api_file
    initialize_python_parser
    check_dependencies
    touch "$URL_LOG_FILE"  # 确保日志文件存在
    
    while true; do
        show_header
        echo -e "${YELLOW}1. 查看 API 列表\n2. 添加 API\n3. 修改 API\n4. 删除 API\n5. 设置\n6. 下载单 API 图片\n7. 下载多 API 图片\n8. 按分组下载\n9. 导入 API 配置\n10. 导出 API 配置\n11. 查看/修改记录设置\n0. 退出${NC}\n${PURPLE}========================================${NC}"
        read -p "请选择操作: " choice
        case $choice in
            1) list_apis; read -p "按回车键返回...";;
            2) add_api; read -p "按回车键返回...";;
            3) modify_api; read -p "按回车键返回...";;
            4) delete_api; read -p "按回车键返回...";;
            5) settings_menu;;
            6)
                list_apis
                local total_apis=$(wc -l < "$API_FILE")
                [[ "$total_apis" -eq 0 ]] && { echo -e "${RED}错误：没有可用的 API！请添加或导入 API。${NC}"; read -p "按回车键返回..."; continue; }
                read -p "请输入要使用的 API 编号 (1-$total_apis): " api_num
                [[ ! "$api_num" =~ ^[0-9]+$ || "$api_num" -lt 1 || "$api_num" -gt "$total_apis" ]] && { echo -e "${RED}错误：无效的编号！请输入 1-$total_apis 的数字。${NC}"; read -p "按回车键返回..."; continue; }
                read -p "请输入下载次数: " download_times
                [[ ! "$download_times" =~ ^[0-9]+$ || "$download_times" -lt 1 ]] && { echo -e "${RED}错误：无效的下载次数！请输入大于 0 的数字。${NC}"; read -p "按回车键返回..."; continue; }
                local api_line=$(awk -F'|' -v n="$api_num" 'NR==n {print $0}' "$API_FILE")
                download_images_multithread "$api_line" "$download_times"
                read -p "按回车键返回...";;
            7)
                download_multi_apis
                read -p "按回车键返回...";;
            8)
                download_by_group
                read -p "按回车键返回...";;
            9) import_apis; read -p "按回车键返回...";;
            10) export_apis; read -p "按回车键返回...";;
            11) show_record_settings;;
            0) echo -e "${GREEN}退出程序${NC}"; exit 0;;
            *) echo -e "${RED}错误：无效选择！请输入 0-11。${NC}"; sleep 1;;
        esac
    done
}

# =====================================================================
# 脚本入口点
# =====================================================================
main_menu