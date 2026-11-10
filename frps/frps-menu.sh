#!/usr/bin/env bash
# ============================================================
# frps 管理菜单
#
# 作用：给固定版本的 frps 安装脚本套一个数字菜单
# 依赖：固定好的安装脚本，放在 /etc/frps-menu/install-frps.sh
# 说明：安装 / 卸载 / 升级 三件事仍然交给那份安装脚本完成，
#       它的内容一个字节都没改。只有"改端口、改密码"这类
#       小改动由本菜单直接改配置文件，并带自动回滚。
# ============================================================

INSTALLER="/etc/frps-menu/install-frps.sh"
CONF="/usr/local/frps/frps.toml"
INIT="/etc/init.d/frps"
BIN="/usr/local/frps/frps"

RED='\033[1;31m'
GRN='\033[1;32m'
YEL='\033[1;33m'
CYA='\033[1;36m'
END='\033[0m'

# ---------- 基础检查 ----------
need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}需要用 root 身份运行。${END}"
        exit 1
    fi
}

check_env() {
    if [ ! -s "$INSTALLER" ]; then
        echo -e "${RED}找不到固定版本的安装脚本：${INSTALLER}${END}"
        echo "请先把那份脚本放到这个位置，再运行本菜单。"
        exit 1
    fi
}

is_installed() {
    [ -s "$BIN" ] || [ -s "$INIT" ]
}

is_running() {
    pgrep -x frps >/dev/null 2>&1
}

pause() {
    echo ""
    read -r -p "按回车返回..." _
}

# ---------- 读写配置 ----------
conf_get() {
    [ -r "$CONF" ] || return 1
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONF" 2>/dev/null \
        | head -n1 \
        | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/^"//' -e 's/"[[:space:]]*$//' \
              -e "s/^'//" -e "s/'[[:space:]]*$//"
}

conf_set() {
    # $1=键名  $2=值  $3=1 表示加双引号
    local key="$1" val="$2" quote="$3" esc out
    esc=$(printf '%s' "$key" | sed 's/\./\\./g')
    # 值里的特殊字符做转义，避免替换出错
    out=$(printf '%s' "$val" | sed -e 's/[&|\\]/\\&/g')
    if [ "$quote" = "1" ]; then
        out="\"$out\""
    fi
    if grep -qE "^[[:space:]]*${esc}[[:space:]]*=" "$CONF"; then
        sed -i -E "s|^[[:space:]]*${esc}[[:space:]]*=.*|${key} = ${out}|" "$CONF"
    else
        printf '%s = %s\n' "$key" "$out" >> "$CONF"
    fi
}

backup_conf() {
    local bak="${CONF}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -f "$CONF" "$bak" && echo "$bak"
}

# 重启并检查；起不来就自动恢复上一份
apply_and_verify() {
    local bak="$1"
    [ -x "$INIT" ] || { echo -e "${RED}找不到服务控制脚本。${END}"; return 1; }
    "$INIT" restart >/dev/null 2>&1
    sleep 3
    if is_running; then
        echo -e "${GRN}已生效，服务正常运行。${END}"
        return 0
    fi
    echo -e "${RED}新设置起不来，正在恢复刚才的配置...${END}"
    cp -f "$bak" "$CONF"
    "$INIT" restart >/dev/null 2>&1
    sleep 2
    if is_running; then
        echo -e "${YEL}已恢复到修改前的状态，服务正常。${END}"
    else
        echo -e "${RED}恢复后仍未起来，请把这份信息告诉我：${END}"
        echo "配置文件：$CONF"
        echo "备份文件：$bak"
    fi
    return 1
}

public_ip() {
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip="(取不到，用你服务器的公网 IP)"
    echo "$ip"
}

rand_pwd() {
    # 12 位，去掉容易看错的字符
    tr -dc 'A-Za-z2-9' < /dev/urandom 2>/dev/null | head -c 12
}

# ---------- 查看信息 ----------
show_info() {
    echo ""
    echo -e "${CYA}========== 当前 frps 配置 ==========${END}"
    if [ ! -r "$CONF" ]; then
        echo -e "${YEL}还没装，或者找不到配置文件。${END}"
        pause
        return
    fi

    local bind_port vhttp vhttps web_port web_user web_pass token version
    bind_port=$(conf_get bindPort)
    vhttp=$(conf_get vhostHTTPPort)
    vhttps=$(conf_get vhostHTTPSPort)
    web_port=$(conf_get webServer.port)
    web_user=$(conf_get webServer.user)
    web_pass=$(conf_get webServer.password)
    token=$(conf_get auth.token)

    echo -e "穿透主端口   : ${GRN}${bind_port}${END}   （内网那台机器要填这个）"
    echo -e "网站占用 80  : ${vhttp:-未设置}"
    echo -e "网站占用 443 : ${vhttps:-未设置}"
    echo -e "面板端口     : ${web_port:-未设置}"
    echo -e "面板用户名   : ${web_user:-未设置}"
    echo -e "面板密码     : ${web_pass:-未设置}"
    echo -e "连接密码     : ${YEL}${token:-未设置}${END}"
    echo ""
    if [ -n "$web_port" ] && [ "$web_port" != "0" ]; then
        echo -e "面板地址     : http://$(public_ip):${web_port}"
    fi
    if [ -s "$BIN" ]; then
        version=$("$BIN" --version 2>/dev/null | head -n1)
        echo -e "程序版本     : ${version:-未知}"
    fi
    echo -e "${CYA}===================================${END}"
    echo "连接密码就是内网那台机器配置时要填的那一串，别丢。"
    pause
}

show_status() {
    echo ""
    echo -e "${CYA}========== 运行状态 ==========${END}"
    if ! is_installed; then
        echo -e "${YEL}未安装。${END}"
        pause
        return
    fi

    if is_running; then
        echo -e "服务状态 : ${GRN}正在运行${END}"
        echo "运行时长 : $(ps -o etime= -p "$(pgrep -x frps | head -n1)" 2>/dev/null | tr -d ' ')"
    else
        echo -e "服务状态 : ${RED}没有运行${END}"
    fi

    echo ""
    echo "frps 实际在监听的端口："
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -i frps | awk '{print "  " $4}' | sort -u
        ss -ulnp 2>/dev/null | grep -i frps | awk '{print "  " $4 "  (UDP)"}' | sort -u
    else
        echo "  (系统里没有查看端口的工具)"
    fi
    echo ""
    echo "开机自启："
    if [ -e /etc/systemd/system/multi-user.target.wants/frps.service ] \
       || ls /etc/rc3.d/ 2>/dev/null | grep -q 'S.*frps'; then
        echo "  已注册"
    else
        echo "  (未确认)"
    fi
    pause
}

# ---------- 调用安装脚本 ----------
do_install() {
    echo ""
    if is_running; then
        echo -e "${YEL}已经在运行了，安装脚本不会重复安装。${END}"
        echo "想重新装，请用菜单里的「重新安装」。"
        pause
        return
    fi
    bash "$INSTALLER" install
    pause
}

do_reinstall() {
    echo ""
    echo -e "${RED}重新安装会先删掉现有配置和连接密码。${END}"
    echo "删掉之后已经配好的隧道全部失效，连接密码会重新生成。"
    read -r -p "确定继续请输入 yes，其他任意键取消：" ok
    if [ "$ok" != "yes" ]; then
        echo "已取消。"
        pause
        return
    fi
    bash "$INSTALLER" uninstall
    echo ""
    echo "开始重新安装..."
    bash "$INSTALLER" install
    pause
}

do_update() {
    echo ""
    if ! is_installed; then
        echo -e "${YEL}还没装，先安装。${END}"
        pause
        return
    fi
    echo -e "${YEL}提醒：升级会把程序换成新版本。${END}"
    echo "现在这套是验证过能用的，换版本后可能需要重新检查隧道。"
    read -r -p "确定升级请输入 yes，其他任意键取消：" ok
    [ "$ok" = "yes" ] || { echo "已取消。"; pause; return; }
    bash "$INSTALLER" update
    pause
}

do_uninstall() {
    echo ""
    if ! is_installed; then
        echo -e "${YEL}本来就没装。${END}"
        pause
        return
    fi
    echo -e "${RED}卸载会删掉程序、配置和连接密码，无法恢复。${END}"
    read -r -p "确定卸载请输入 yes，其他任意键取消：" ok
    [ "$ok" = "yes" ] || { echo "已取消。"; pause; return; }
    bash "$INSTALLER" uninstall
    pause
}

svc() {
    echo ""
    if ! is_installed; then
        echo -e "${YEL}还没装，先安装。${END}"
        pause
        return
    fi
    if [ ! -x "$INIT" ]; then
        echo -e "${RED}找不到服务控制脚本，可能装得不完整。${END}"
        pause
        return
    fi
    "$INIT" "$1"
    sleep 1
    if is_running; then
        echo -e "现在状态：${GRN}正在运行${END}"
    else
        echo -e "现在状态：${RED}没有运行${END}"
    fi
    pause
}

# ---------- 改设置 ----------
chg_port() {
    # $1=键名  $2=中文名  $3=是否要提示"客户端也得改"
    local key="$1" label="$2" hint="$3" v bak
    echo ""
    echo "当前${label}：$(conf_get "$key")"
    read -r -p "输入新的端口（1-65535，直接回车取消）：" v
    [ -z "$v" ] && { echo "已取消。"; pause; return; }
    if ! printf '%s' "$v" | grep -qE '^[0-9]+$' || [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
        echo -e "${RED}不是合法端口，已取消。${END}"
        pause
        return
    fi
    if [ -n "$hint" ]; then
        echo -e "${YEL}注意：改完这个，内网那台机器的客户端配置也要跟着改。${END}"
    fi
    bak=$(backup_conf)
    conf_set "$key" "$v" ""
    echo "已写入，正在重启验证..."
    apply_and_verify "$bak"
    pause
}

chg_password() {
    local v bak
    echo ""
    echo "现在会生成一串新的面板登录密码，你也可以自己输。"
    read -r -p "直接回车＝随机生成，或输入自定义密码（留空回车）：" v
    if [ -z "$v" ]; then
        v=$(rand_pwd)
        while [ ${#v} -lt 12 ]; do v=$(rand_pwd); done
        echo "已生成：$v"
    fi
    bak=$(backup_conf)
    conf_set "webServer.password" "$v" 1
    echo "已写入，正在重启验证..."
    if apply_and_verify "$bak"; then
        echo ""
        echo -e "新的面板登录信息："
        echo -e "  地址：http://$(public_ip):$(conf_get webServer.port)"
        echo -e "  用户名：$(conf_get webServer.user)"
        echo -e "  密码：${GRN}${v}${END}"
        echo "（请把这串密码存下来）"
    fi
    pause
}

chg_token() {
    echo ""
    echo -e "${YEL}连接密码是服务端和内网客户端之间的暗号，两边必须一致。${END}"
    echo "改了以后，所有内网机器都要同步改，否则连不上。"
    read -r -p "确定要改请输入 yes，其他任意键取消：" ok
    [ "$ok" = "yes" ] || { echo "已取消。"; pause; return; }
    local v bak
    v=$(head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24)
    bak=$(backup_conf)
    conf_set "auth.token" "$v" 1
    echo "已写入，正在重启验证..."
    if apply_and_verify "$bak"; then
        echo ""
        echo -e "新的连接密码：${GRN}${v}${END}"
        echo "（请把这串抄下来，内网那台机器要填）"
    fi
    pause
}

settings_menu() {
    local c
    while true; do
        clear
        echo ""
        echo -e "${CYA}+--------------------------------------+${END}"
        echo -e "${CYA}|            修改设置                    |${END}"
        echo -e "${CYA}+--------------------------------------+${END}"
        echo ""
        echo "  1. 改穿透主端口（内网机器连服务端用的）"
        echo "  2. 改面板端口"
        echo "  3. 改面板登录密码"
        echo "  4. 换连接密码（所有客户端要同步改）"
        echo "  0. 返回"
        echo ""
        read -r -p "请输入数字 [0-4]：" c
        case "$c" in
            1) chg_port "bindPort" "穿透主端口" "1" ;;
            2) chg_port "webServer.port" "面板端口" "" ;;
            3) chg_password ;;
            4) chg_token ;;
            0) return ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------- 主循环 ----------
menu() {
    while true; do
        clear
        echo ""
        echo -e "${CYA}+------------------------------------------------+${END}"
        echo -e "${CYA}|              frps 管理菜单                     |${END}"
        echo -e "${CYA}+------------------------------------------------+${END}"
        if is_running; then
            echo -e "  当前状态：${GRN}正在运行${END}   端口 $(conf_get bindPort)"
        elif is_installed; then
            echo -e "  当前状态：${YEL}已安装，未运行${END}"
        else
            echo -e "  当前状态：未安装"
        fi
        echo ""
        echo "   1. 安装"
        echo "   2. 重新安装（会清空现有配置）"
        echo "   3. 修改设置"
        echo "   4. 查看配置与连接密码"
        echo "   5. 查看运行状态"
        echo "   6. 启动          7. 停止"
        echo "   8. 重启"
        echo "   9. 升级程序"
        echo "  10. 卸载"
        echo "   0. 退出"
        echo ""
        read -r -p "请输入数字 [0-10]：" n
        case "$n" in
            1) do_install ;;
            2) do_reinstall ;;
            3) settings_menu ;;
            4) show_info ;;
            5) show_status ;;
            6) svc start ;;
            7) svc stop ;;
            8) svc restart ;;
            9) do_update ;;
            10) do_uninstall ;;
            0) clear; exit 0 ;;
            *) echo ""; echo "没有这个选项。"; sleep 1 ;;
        esac
    done
}

need_root
check_env
menu
