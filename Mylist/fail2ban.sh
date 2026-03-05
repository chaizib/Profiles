#!/bin/bash

# ===================================================
# Fail2Ban 一键部署脚本（Debian/Ubuntu专用）
# 功能：3次失败封禁3小时，日志限制3M/保留3天
# 作者：系统优化脚本
# ===================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 设置错误退出
set -e

# 显示banner
clear
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}   Fail2Ban 一键部署脚本（严厉版）     ${NC}"
echo -e "${GREEN}   Debian/Ubuntu 系统专用              ${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${YELLOW}开始时间：$(date)${NC}"
echo -e "${YELLOW}规则：3次失败 ➔ 封禁3小时${NC}"
echo -e "${YELLOW}日志：不超过3M，保留3天${NC}"
echo ""

# 检查root权限
if [ $EUID -ne 0 ]; then
    echo -e "${RED}错误：请使用root权限运行此脚本${NC}"
    echo "使用: sudo $0"
    exit 1
fi

# 检测系统
echo -e "${BLUE}[1/8] 检测系统类型...${NC}"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
    echo -e "${GREEN}    检测到系统：$OS $VERSION${NC}"
    
    # 检查是否为Debian/Ubuntu
    if [ "$OS" != "debian" ] && [ "$OS" != "ubuntu" ]; then
        echo -e "${RED}错误：此脚本仅支持 Debian 和 Ubuntu 系统${NC}"
        echo -e "${YELLOW}当前系统：$OS${NC}"
        exit 1
    fi
else
    echo -e "${RED}无法检测系统类型${NC}"
    exit 1
fi

# 修复软件源（针对Debian 11老系统）
echo -e "${BLUE}[2/8] 检查并修复软件源...${NC}"
if [ "$OS" == "debian" ] && [ "$VERSION" == "11" ]; then
    echo -e "${YELLOW}    检测到 Debian 11，修复软件源...${NC}"
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d) 2>/dev/null || true
    cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://deb.debian.org/debian-security bullseye-security main contrib non-free
deb http://archive.debian.org/debian bullseye-backports main contrib non-free
EOF
    echo -e "${GREEN}    软件源已修复${NC}"
else
    echo -e "${GREEN}    软件源无需修复${NC}"
fi

# 更新软件源
echo -e "${BLUE}[3/8] 更新软件源...${NC}"
apt update
echo -e "${GREEN}    软件源更新完成${NC}"

# 安装fail2ban
echo -e "${BLUE}[4/8] 安装 fail2ban...${NC}"
apt install fail2ban iptables rsyslog logrotate -y
echo -e "${GREEN}    fail2ban 安装完成${NC}"

# 检测SSH端口
echo -e "${BLUE}[5/8] 检测 SSH 端口...${NC}"
SSH_PORT=""

# 多种方法检测SSH端口
if command -v ss >/dev/null 2>&1; then
    SSH_PORT=$(ss -tnlp 2>/dev/null | grep -i sshd | grep -oP ':\K\d+' | head -1)
fi

if [ -z "$SSH_PORT" ] && command -v netstat >/dev/null 2>&1; then
    SSH_PORT=$(netstat -tnlp 2>/dev/null | grep -i sshd | awk '{print $4}' | grep -oP ':\K\d+' | head -1)
fi

if [ -z "$SSH_PORT" ]; then
    SSH_PORT=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
fi

if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
    echo -e "${YELLOW}    未检测到SSH端口，使用默认端口 22${NC}"
else
    echo -e "${GREEN}    检测到 SSH 端口: $SSH_PORT${NC}"
fi

# 停止fail2ban服务（如果正在运行）
systemctl stop fail2ban 2>/dev/null || true

# 创建严厉版配置
echo -e "${BLUE}[6/8] 写入 fail2ban 配置...${NC}"

# 创建主配置文件
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 3h
findtime = 10m
maxretry = 3

# 日志设置
loglevel = INFO
logtarget = /var/log/fail2ban.log

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 10800
EOF

echo -e "${GREEN}    fail2ban 配置已写入${NC}"

# 配置日志轮转
echo -e "${BLUE}[7/8] 配置日志轮转...${NC}"
cat > /etc/logrotate.d/fail2ban << 'EOF'
/var/log/fail2ban.log {
    size 3M                    # 超过3M就轮转
    rotate 3                    # 保留3个备份
    maxage 3                    # 最多保留3天
    compress                    # 压缩旧日志
    delaycompress               # 延迟压缩
    missingok                   # 日志缺失不报错
    notifempty                  # 空文件不轮转
    create 640 root adm         # 创建新文件的权限
    postrotate
        # 通知fail2ban重新打开日志文件
        fail2ban-client flushlogs > /dev/null 2>&1 || true
    endscript
}
EOF

echo -e "${GREEN}    日志轮转配置已写入${NC}"

# 立即应用日志轮转
logrotate -f /etc/logrotate.d/fail2ban 2>/dev/null || true
echo -e "${GREEN}    日志轮转已应用${NC}"

# 启动服务
echo -e "${BLUE}[8/8] 启动 fail2ban 服务...${NC}"
systemctl enable fail2ban
systemctl start fail2ban
sleep 3

# 检查服务状态
if systemctl is-active --quiet fail2ban; then
    echo -e "${GREEN}    fail2ban 服务启动成功${NC}"
else
    echo -e "${RED}    fail2ban 服务启动失败，检查日志...${NC}"
    journalctl -u fail2ban --no-pager -n 10
    exit 1
fi

# 重新加载配置
fail2ban-client reload 2>/dev/null || true

# 显示结果
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Fail2Ban 部署完成！${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}📊 当前配置：${NC}"
echo "   • 最大尝试次数: 3 次"
echo "   • 封禁时间: 3 小时 (10800秒)"
echo "   • 检测窗口: 10 分钟 (600秒)"
echo "   • SSH 端口: $SSH_PORT"
echo "   • 日志文件: /var/log/fail2ban.log"
echo "   • 日志限制: 不超过 3M，保留 3 天"
echo ""

# 显示服务状态
echo -e "${YELLOW}📊 服务状态：${NC}"
systemctl status fail2ban --no-pager | grep "Active:" | sed 's/^/   /'

# 显示防护状态
echo ""
echo -e "${YELLOW}📊 SSH 防护状态：${NC}"
if fail2ban-client status sshd >/dev/null 2>&1; then
    fail2ban-client status sshd | grep -E "Status|IP list|Total failed" | sed 's/^/   /'
else
    echo "   SSH 防护已启用（等待初始化）"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${YELLOW}📝 常用命令：${NC}"
echo "   • 查看状态：fail2ban-client status sshd"
echo "   • 查看封禁列表：fail2ban-client banned"
echo "   • 解封 IP：fail2ban-client set sshd unbanip <IP地址>"
echo "   • 手动封禁：fail2ban-client set sshd banip <IP地址>"
echo "   • 查看日志：tail -f /var/log/fail2ban.log"
echo "   • 测试配置：fail2ban-client reload"
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${YELLOW}完成时间：$(date)${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"