#!/bin/bash

# =================================================================
# 脚本名称: VPS 流量审计 Pro (V18.5 - 审计修正)
# 核心逻辑: 动态重置锚点 | 流量/时间双进度对标 | 熔断机制恢复
# 优先级: 稳健性第一 | 严格保留所有日志逻辑
# =================================================================

# --- 【强制内部时区】 ---
export TZ='Asia/Shanghai'

# --- 【1. 自定义统一配置区】 ---
TG_TOKEN="填入机器人token"
CHAT_ID="填入接收日报的账号ID"
HOSTNAME="Debee MO"          # 服务器显示名
TRAFFIC_RESET="27 00:00"        # 重置周期 (日 时:分)
INIT_USAGE_GB=7.33              # 初始对齐流量 (GB)
INTERFACE="eth0"                # 网卡名 (查看命令: ip addr)
TRAFFIC_QUOTA=1500               # 周期总配额 (单位: GB)
# ---------------------------------------

DATA_DIR="/root/505"
DATA_FILE="$DATA_DIR/.vps_monitor_data"
LOG_FILE="$DATA_DIR/vps_monitor.log"
LOCK_FILE="$DATA_DIR/.vps_lock"
export LC_ALL=C
mkdir -p "$DATA_DIR"

# 基础依赖检查
for cmd in curl awk date flock grep; do
    command -v $cmd &> /dev/null || exit 1
done

# --- 【2. 致命错误熔断预检 (V18.2 完整版) 】 ---
RESET_DAY=$(echo "$TRAFFIC_RESET" | awk '{print $1}')
RESET_TIME=$(echo "$TRAFFIC_RESET" | awk '{print $2}')
TEST_STAMP=$(date -d "2026-01-01 ${RESET_TIME}:00" +%s 2>/dev/null)
if [[ -z "$TEST_STAMP" ]]; then
    echo "$(date): [致命错误] TRAFFIC_RESET 时间格式无效: ${TRAFFIC_RESET}" >> "$LOG_FILE"
    exit 1
fi

# --- 【3. 手动重置模块 】 ---
if [[ "$1" == "--reset" ]]; then
    rm -f "$DATA_FILE"
    echo -e "\n\033[32m✨ [已重置] 流量账单已删除，下次运行将重新对齐。\033[0m"
    exit 0
fi

# --- 【4. 核心数据采集 】 ---
RAW_INFO=$(grep "$INTERFACE" /proc/net/dev)
[[ -z "$RAW_INFO" ]] && { echo "$(date): 错误 - 找不到网卡 $INTERFACE" >> "$LOG_FILE"; exit 1; }
CURRENT_RAW=$(echo "$RAW_INFO" | awk '{print $2 + $10}')
UPTIME_SEC=$(awk '{print $1}' /proc/uptime | cut -d. -f1)
BOOT_TIME=$(($(date +%s) - UPTIME_SEC))

# --- 【5. 账本读取与计算逻辑 】 ---
if [ ! -f "$DATA_FILE" ] || [ ! -s "$DATA_FILE" ]; then
    INIT_BYTES=$(awk "BEGIN {print $INIT_USAGE_GB * 1024^3}")
    echo "$INIT_BYTES $CURRENT_RAW 0 0 0 $INIT_BYTES $BOOT_TIME" > "$DATA_FILE"
fi
read LIFE_TOTAL LAST_RAW MONTH_BASE LAST_RESET_MARK LAST_REPORT_DATE DAILY_BASE LAST_BOOT_TIME < "$DATA_FILE"

# 5.1 重启检查 (已恢复 V18.2 日志)
HAS_REBOOTED=0
BOOT_DIFF=$((BOOT_TIME - LAST_BOOT_TIME))
[[ ${BOOT_DIFF#-} -gt 10 ]] && HAS_REBOOTED=1

# 5.2 增量计算
if [ "$HAS_REBOOTED" -eq 1 ]; then
    DELTA=0
    echo "$(date): [系统重启] 已建立新采样基准。" >> "$LOG_FILE"
else
    if awk "BEGIN {exit ($CURRENT_RAW >= $LAST_RAW ? 0 : 1)}"; then
        DELTA=$(awk "BEGIN {print $CURRENT_RAW - $LAST_RAW}")
    else
        DELTA=$CURRENT_RAW
    fi
fi

# 5.3 核心：动态重置判定 (已恢复 V18.2 日志)
LIFE_TOTAL=$(awk "BEGIN {print $LIFE_TOTAL + $DELTA}")
CUR_STAMP=$(date +%s)

calc_reset_point() {
    local year_month=$1
    local res=$(date -d "${year_month}-${RESET_DAY} ${RESET_TIME}:00" +%s 2>/dev/null)
    if [[ -z "$res" ]]; then
        res=$(date -d "${year_month}-01 +1 month -1 day ${RESET_TIME}:00" +%s)
    fi
    echo "$res"
}

CUR_MONTH_RESET=$(calc_reset_point "$(date +%Y-%m)")

if [[ "$CUR_STAMP" -ge "$CUR_MONTH_RESET" ]]; then
    NEXT_RESET_STAMP=$(calc_reset_point "$(date -d "$(date +%Y-%m-01) +1 month" +%Y-%m)")
    if [[ "$LAST_RESET_MARK" -lt "$CUR_MONTH_RESET" ]]; then
        MONTH_BASE=$LIFE_TOTAL
        LAST_RESET_MARK=$CUR_MONTH_RESET
        echo "$(date): [重置成功] 已跨越账期节点。" >> "$LOG_FILE"
    fi
else
    NEXT_RESET_STAMP=$CUR_MONTH_RESET
fi

# 5.4 计算百分比 (含除零保护)
DAYS_LEFT=$(( (NEXT_RESET_STAMP - CUR_STAMP) / 86400 + 1 ))
MTD_BYTES=$(awk "BEGIN {val=$LIFE_TOTAL - $MONTH_BASE; print (val<0 ? 0 : val)}")
MTD_GB=$(awk "BEGIN {printf \"%.2f\", $MTD_BYTES / 1024^3}")

REMAIN_GB=$(awk "BEGIN {printf \"%.2f\", $TRAFFIC_QUOTA - $MTD_GB}")
[[ $(awk "BEGIN {print ($REMAIN_GB < 0 ? 1 : 0)}") -eq 1 ]] && REMAIN_GB="0.00"

if [[ $(awk "BEGIN {print ($TRAFFIC_QUOTA > 0 ? 1 : 0)}") -eq 1 ]]; then
    USED_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($MTD_GB / $TRAFFIC_QUOTA) * 100}")
else
    USED_PERCENT="0.00"
fi
[[ $(awk "BEGIN {print ($USED_PERCENT > 100 ? 1 : 0)}") -eq 1 ]] && USED_PERCENT="100.00"
REMAIN_PERCENT=$(awk "BEGIN {printf \"%.2f\", 100 - $USED_PERCENT}")

# 5.5 【修改点】时间进度计算逻辑
# 确保起始锚点准确：若从未重置过(首次运行)，则推算上一个重置点作为周期起点
CALC_START_MARK=$LAST_RESET_MARK
if [[ "$CALC_START_MARK" -eq 0 ]]; then
    CALC_START_MARK=$(calc_reset_point "$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m)")
fi

TOTAL_CYCLE_SEC=$(awk "BEGIN {print $NEXT_RESET_STAMP - $CALC_START_MARK}")
ELAPSED_SEC=$(awk "BEGIN {print $CUR_STAMP - $CALC_START_MARK}")

if [[ $(awk "BEGIN {print ($TOTAL_CYCLE_SEC > 0 ? 1 : 0)}") -eq 1 ]]; then
    TIME_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($ELAPSED_SEC / $TOTAL_CYCLE_SEC) * 100}")
else
    TIME_PERCENT="0.00"
fi
# 时间百分比边界保护
[[ $(awk "BEGIN {print ($TIME_PERCENT > 100 ? 1 : 0)}") -eq 1 ]] && TIME_PERCENT="100.00"
[[ $(awk "BEGIN {print ($TIME_PERCENT < 0 ? 1 : 0)}") -eq 1 ]] && TIME_PERCENT="0.00"

DAILY_BYTES=$(awk "BEGIN {val=$LIFE_TOTAL - $DAILY_BASE; print (val<0 ? 0 : val)}")
REALTIME_DAILY_GB=$(awk "BEGIN {printf \"%.2f\", $DAILY_BYTES / 1024^3}")

# --- 【6. 推送模块 】 ---
ESCAPED_HOST=$(echo "$HOSTNAME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

if [[ "$1" == "--test" ]]; then
    echo -e "\n\033[34m🔍 [流量审计 V18.5 - 审计修正]\033[0m"
    echo "━━━━━━━━━━━━━━━━"
    echo "📅 流量日报 | ${HOSTNAME}"
    echo "⏳ 距离重置： ${DAYS_LEFT} 天 时间 ${TIME_PERCENT}%"
    echo "📊 昨日消耗： ${REALTIME_DAILY_GB} GB"
    echo "📈 周期累计： ${MTD_GB} GB | ${USED_PERCENT}%"
    echo "🚀 剩余可用： ${REMAIN_GB} GB (${REMAIN_PERCENT}%)"
    exit 0
fi

TODAY=$(date +%F)
if [[ "$1" == "--report" && "$LAST_REPORT_DATE" != "$TODAY" ]]; then
    MSG_TRAFFIC="📅 <b>流量日报 | ${ESCAPED_HOST}</b>
━━━━━━━━━━━━━━━━
⏳ <b>距离重置：</b> <code>${DAYS_LEFT} 天</code> 时间 <code>${TIME_PERCENT}%</code>
📊 <b>昨日消耗：</b> <code>${REALTIME_DAILY_GB} GB</code>
📈 <b>周期累计：</b> <code>${MTD_GB} GB | ${USED_PERCENT}%</code>
🚀 <b>剩余可用：</b> <b>${REMAIN_GB} GB (${REMAIN_PERCENT}%)</b>"
    
    RES_REP=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${MSG_TRAFFIC}" \
        --data-urlencode "parse_mode=HTML")
    
    if [[ $RES_REP == *"\"ok\":true"* ]]; then
        LAST_REPORT_DATE=$TODAY
        DAILY_BASE=$LIFE_TOTAL
    else
        echo "$(date): 日报推送失败: $RES_REP" >> "$LOG_FILE"
    fi
fi

# --- 【7. 持久化与锁 】 ---
(
    flock -x 9
    echo "$LIFE_TOTAL $CURRENT_RAW $MONTH_BASE $LAST_RESET_MARK $LAST_REPORT_DATE $DAILY_BASE $BOOT_TIME" > "$DATA_FILE"
    echo "$(date): MTD ${MTD_GB}GB, Today ${REALTIME_DAILY_GB}GB" >> "$LOG_FILE"
    tmp_log=$(tail -n 50 "$LOG_FILE")
    echo "$tmp_log" > "$LOG_FILE"
) 9>"$LOCK_FILE"

exit 0
