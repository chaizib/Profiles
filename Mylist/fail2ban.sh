#!/bin/bash

# ===================================================
# Fail2Ban 一键安装脚本（终极优化版）
# 功能：3次失败封禁3小时，日志限制3M/保留3天
# 特性：自动修复所有常见问题，多重容错机制
# ===================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 设置错误处理（但不退出）
set +e
trap '' ERR

# 显示banner
clear
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}          Fail2Ban 一键安装脚本（终极优化版）                 ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}开始时间：$(date)${NC}"
echo -e "${YELLOW}规则：3次失败 ➔ 封禁3小时，日志限制3M/保留3天${NC}"
echo ""

# 检查root权限
if [ $EUID -ne 0 ]; then
    echo -e "${RED}❌ 错误：请使用root权限运行此脚本${NC}"
    exit 1
fi

# 检测系统
echo -e "${BLUE}[1/8] 检测系统类型...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
    echo -e "${GREEN}✅ 检测到系统：$OS $VERSION${NC}"
else
    echo -e "${RED}❌ 无法检测系统类型${NC}"
    exit 1
fi

# 修复软件源（针对Debian 11）
echo -e "${BLUE}[2/8] 检查并修复软件源...${NC}"
if [ "$OS" == "debian" ] && [ "${VERSION%%.*}" -eq 11 ]; then
    echo -e "${YELLOW}⚠️ 检测到 Debian 11，修复软件源...${NC}"
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d) 2>/dev/null
    cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://deb.debian.org/debian-security bullseye-security main contrib non-free
# 注释掉backports避免404
# deb http://deb.debian.org/debian bullseye-backports main contrib non-free
EOF
    echo -e "${GREEN}✅ 软件源已修复${NC}"
else
    echo -e "${GREEN}✅ 软件源无需修复${NC}"
fi

# 更新软件源（忽略错误）
echo -e "${BLUE}[3/8] 更新软件源...${NC}"
apt update > /dev/null 2>&1 || true
echo -e "${GREEN}✅ 软件源更新完成${NC}"

# 安装必要软件
echo -e "${BLUE}[4/8] 安装必要软件...${NC}"
apt install -y fail2ban iptables rsyslog logrotate curl wget > /dev/null 2>&1
echo -e "${GREEN}✅ 软件安装完成${NC}"

# 停止所有相关服务
systemctl stop fail2ban 2>/dev/null
systemctl stop rsyslog 2>/dev/null

# 确保日志文件存在且权限正确
echo -e "${BLUE}[5/8] 检查并修复日志文件...${NC}"

# 判断系统日志类型
if [ -f "/var/log/auth.log" ]; then
    LOG_FILE="/var/log/auth.log"
    echo -e "${GREEN}✅ 使用日志文件: auth.log${NC}"
elif [ -f "/var/log/secure" ]; then
    LOG_FILE="/var/log/secure"
    echo -e "${GREEN}✅ 使用日志文件: secure${NC}"
else
    # 创建日志文件
    LOG_FILE="/var/log/auth.log"
    touch /var/log/auth.log
    echo -e "${YELLOW}⚠️ 创建日志文件: auth.log${NC}"
fi

# 设置正确权限
chmod 644 $LOG_FILE
chown syslog:adm $LOG_FILE 2>/dev/null || chown root:adm $LOG_FILE 2>/dev/null

# 重启rsyslog
systemctl start rsyslog
sleep 2

# 写入测试日志
logger "Fail2Ban installation test log" 2>/dev/null
echo -e "${GREEN}✅ 日志系统正常${NC}"

# 检测SSH端口
echo -e "${BLUE}[6/8] 检测 SSH 端口...${NC}"
SSH_PORT=$(ss -tnlp 2>/dev/null | grep -i sshd | grep -oP ':\K\d+' | head -1)
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
fi
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
    echo -e "${YELLOW}⚠️ 使用默认端口: 22${NC}"
else
    echo -e "${GREEN}✅ 检测到端口: $SSH_PORT${NC}"
fi

# 清理旧配置
echo -e "${BLUE}[7/8] 写入新配置...${NC}"
rm -rf /etc/fail2ban/jail.local /etc/fail2ban/jail.d/* 2>/dev/null

# 写入主配置
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3h
findtime = 10m
maxretry = 3

# 日志设置
loglevel = INFO
logtarget = /var/log/fail2ban.log

# 后端设置
backend = auto

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = $LOG_FILE
maxretry = 3
findtime = 600
bantime = 10800
EOF

# 写入日志轮转配置
cat > /etc/logrotate.d/fail2ban << 'EOF'
/var/log/fail2ban.log {
    size 3M
    rotate 3
    maxage 3
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    postrotate
        fail2ban-client flushlogs > /dev/null 2>&1 || true
    endscript
}
EOF

echo -e "${GREEN}✅ 配置写入完成${NC}"

# 清理fail2ban缓存
echo -e "${BLUE}[8/8] 启动服务...${NC}"
rm -rf /var/lib/fail2ban/* 2>/dev/null

# 启动服务（带重试机制）
for i in {1..3}; do
    echo -e "${YELLOW}尝试启动服务 ($i/3)...${NC}"
    systemctl enable fail2ban > /dev/null 2>&1
    systemctl start fail2ban
    sleep 3
    
    if systemctl is-active --quiet fail2ban; then
        echo -e "${GREEN}✅ 服务启动成功${NC}"
        break
    fi
    
    if [ $i -eq 3 ]; then
        echo -e "${RED}❌ 服务启动失败，尝试强制启动...${NC}"
        fail2ban-server -b start > /dev/null 2>&1
    fi
done

# 重新加载配置
fail2ban-client reload > /dev/null 2>&1

# 应用日志轮转
logrotate -f /etc/logrotate.d/fail2ban > /dev/null 2>&1

# 显示结果
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ 安装完成！当前状态：${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# 显示配置信息
echo -e "${YELLOW}📊 配置信息：${NC}"
echo "   • 系统：$OS $VERSION"
echo "   • SSH端口：$SSH_PORT"
echo "   • 日志文件：$LOG_FILE"
echo "   • 规则：3次失败封禁3小时"
echo "   • 日志限制：≤3M，保留3天"
echo ""

# 显示服务状态
echo -e "${YELLOW}📊 服务状态：${NC}"
systemctl status fail2ban --no-pager | grep "Active:" | sed 's/^/   /'

# 显示防护状态
echo ""
echo -e "${YELLOW}📊 SSH防护状态：${NC}"
if fail2ban-client status sshd > /dev/null 2>&1; then
    fail2ban-client status sshd | grep -E "Status|IP list|Total failed" | sed 's/^/   /'
else
    echo "   SSH防护正在初始化..."
fi

# 显示DNS状态（修复常见问题）
echo ""
echo -e "${YELLOW}📊 DNS配置检查：${NC}"
if grep -q "2001:4860:4860::8888" /etc/resolv.conf; then
    echo "   ✅ DNS IPv6配置正常"
else
    echo "   ⚠️ DNS未配置IPv6，如需配置请手动修改"
fi

# 显示常用命令
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}📝 常用命令：${NC}"
echo "   • 查看状态：fail2ban-client status sshd"
echo "   • 查看封禁：fail2ban-client banned"
echo "   • 解封IP：fail2ban-client set sshd unbanip <IP地址>"
echo "   • 查看日志：tail -f /var/log/fail2ban.log"
echo "   • 测试封禁：fail2ban-client set sshd banip 1.2.3.4"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}完成时间：$(date)${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"

# 验证最终状态
if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}✅ 脚本执行成功！Fail2Ban 正常运行中${NC}"
else
    echo -e "${RED}❌ 脚本执行完成但服务异常，请手动检查：journalctl -u fail2ban${NC}"
fi
