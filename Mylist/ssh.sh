cat << 'EOF' > /etc/profile.d/custom-motd.sh && chmod +x /etc/profile.d/custom-motd.sh
#!/bin/bash

# 1. 交互式 Shell 检查 & 防止干扰非交互式任务 (稳健性第一)
case $- in
    *i*) ;;
    *) return ;;
esac
[ -n "$SUDO_USER" ] && return

# 2. 颜色定义 (WHITE 已改为粗体白，提升易读性)
GREEN='\033[1;32m'; BLUE='\033[1;34m'; CYAN='\033[1;36m'
YELLOW='\033[1;33m'; RED='\033[1;31m'; WHITE='\033[1;37m'; RESET='\033[0m'
IP_STR="" 

# 3. 核心信息采集
USER_NAME=$(whoami)
HOSTNAME=$(hostname)
OS_VER=$(grep "PRETTY_NAME" /etc/os-release | cut -d '"' -f 2)
CURRENT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
WEEKDAY_NUM=$(date '+%u')
WEEKDAY_CN=("星期一" "星期二" "星期三" "星期四" "星期五" "星期六" "星期日")
WEEKDAY=${WEEKDAY_CN[$((WEEKDAY_NUM-1))]}

# 系统状态采集
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | xargs)
MEM_INFO=$(free -h | awk '/^Mem:/ {print $3 " / " $2}')
DISK_INFO=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')
DISK_PERCENT=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
UPTIME=$(uptime -p | sed 's/up //')
LAST_APT_ACT=$(stat -c %y /var/log/apt/history.log 2>/dev/null | cut -d '.' -f1 || echo "Unknown")

# 获取登录 IP
if [[ -n "$SSH_CONNECTION" ]]; then
    LOGIN_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    IP_STR=" (${LOGIN_IP})"
fi

# 4. 输出界面 (使用 [#] 符号对齐，标签改为白色)
echo -e "${GREEN}欢迎回来, ${USER_NAME}!${RESET}${IP_STR}"
echo -e "${BLUE}--------------------------------------------------------------${RESET}"
echo -e "[#] ${WHITE}当前时间:${RESET}    ${CYAN}${CURRENT_DATE} (${WEEKDAY})${RESET}"
echo -e "[#] ${WHITE}系统负载:${RESET}    ${CYAN}${LOAD_AVG}${RESET}"
echo -e "[#] ${WHITE}运行时间:${RESET}    ${CYAN}${UPTIME}${RESET}"
echo -e "[#] ${WHITE}内存使用:${RESET}    ${CYAN}${MEM_INFO}${RESET}"
echo -e "[#] ${WHITE}磁盘使用:${RESET}    ${CYAN}${DISK_INFO}${RESET}"
echo -e "[#] ${WHITE}最近更新:${RESET}    ${CYAN}${LAST_APT_ACT}${RESET}"
echo -e "[#] ${WHITE}系统版本:${RESET}    ${CYAN}${OS_VER}${RESET}"
echo -e "${BLUE}--------------------------------------------------------------${RESET}"

# 5. Docker 状态监测 (区分总数与运行数，列表缩进对齐)
if command -v docker &> /dev/null && docker ps &> /dev/null; then
    RUNNING_COUNT=$(docker ps -q | wc -l)
    D_TOTAL_COUNT=$(docker ps -a -q | wc -l)
    
    echo -e "\n${YELLOW}[>] Docker 状态:${RESET}   共 ${D_TOTAL_COUNT} 个容器 (运行中: ${RUNNING_COUNT})"
    
    # 运行中的容器列表
    RUNNING_APPS=$(docker ps --format "{{.Names}}" | sort)
    [ -n "$RUNNING_APPS" ] && for app in $RUNNING_APPS; do echo -e "    ${GREEN}[+] $app 运行中${RESET}"; done
    
    # 已停止的容器列表 (逻辑折叠)
    EXITED_APPS=$(docker ps -a --filter "status=exited" --filter "status=created" --format "{{.Names}}" | sort)
    if [ -n "$EXITED_APPS" ]; then
        STOP_COUNT=$(echo "$EXITED_APPS" | wc -l)
        if [ "$STOP_COUNT" -le 5 ]; then
            for app in $EXITED_APPS; do echo -e "    ${RED}[-] $app 未运行${RESET}"; done
        else
            echo -e "    ${RED}[-] 另有 $STOP_COUNT 个容器未运行${RESET}"
        fi
    fi
fi

# 6. 最近登录记录 (兼容各系统格式)
if command -v last &> /dev/null; then
    echo -e "\n${YELLOW}[>] 最近登录记录:${RESET}"
    last -i -n 3 | grep -vE "reboot|wtmp|still" | head -n 3 | while read -r line; do
        [ -z "$line" ] && continue
        echo -e "    ${CYAN}${line}${RESET}"
    done
fi

# 7. 磁盘多级告警 (多档位反馈)
if [ -n "$DISK_PERCENT" ]; then
    if [ "$DISK_PERCENT" -ge 90 ]; then
        echo -e "\n${RED}[!] 严重警告：磁盘使用率已达到 ${DISK_PERCENT}%，请立即清理！${RESET}"
    elif [ "$DISK_PERCENT" -ge 75 ]; then
        echo -e "\n${YELLOW}[!] 警告：磁盘使用率已达到 ${DISK_PERCENT}%，建议清理${RESET}"
    fi
fi
echo ""
EOF

# 8. 生产环境无损部署 (备份原始文件至 /root/bak/)
mkdir -p /root/bak
for f in /etc/motd /etc/issue /etc/issue.net; do
    [ -f "$f" ] && [ ! -f "/root/bak/$(basename $f).orig" ] && cp "$f" "/root/bak/$(basename $f).orig"
    true > "$f"
done
[ -d /etc/update-motd.d ] && chmod -x /etc/update-motd.d/* 2>/dev/null || true

# 立即刷新效果
source /etc/profile.d/custom-motd.sh
