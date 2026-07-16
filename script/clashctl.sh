# shellcheck disable=SC2148
# shellcheck disable=SC2155

_is_tcp_port_listening() {
    local port=$1
    [ -n "$port" ] || return 1
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|.*[:.])${port}$"
}

_set_system_proxy() {
    # Ensure config files exist before reading
    [ ! -f "$MIHOMO_CONFIG_RUNTIME" ] && {
        _failcat "运行时配置文件不存在: $MIHOMO_CONFIG_RUNTIME"
        return 1
    }
    
    local auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    [ -n "$auth" ] && auth=$auth@

    local http_proxy_addr="http://${auth}127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5h://${auth}127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy

    # Ensure mixin config directory exists and update using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.system-proxy.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新系统代理配置"
        return 1
    }
}

_unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY

    # Ensure mixin config exists and update using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.system-proxy.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新系统代理配置"
    }
}

function clashon() {
    # Ensure config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RUNTIME")"
    
    # Merge configuration using user permissions
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    # 检查端口冲突并显示分配结果
    _resolve_port_conflicts "$MIHOMO_CONFIG_RUNTIME" true
    
    # Start mihomo process
    if start_mihomo; then
        # Wait for mihomo to fully start
        sleep 2
        
        # 验证实际端口并设置端口变量
        _verify_actual_ports
        
        # 保存端口状态并设置系统代理
        _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT"
        _set_system_proxy
        _okcat '已开启代理环境'
    else
        _failcat '代理启动失败'
        return 1
    fi
}

# 验证实际监听端口与配置是否一致
_verify_actual_ports() {
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    [ ! -f "$log_file" ] && return 0
    
    # Extract actual listening ports from log
    # Try both old format (Mixed) and new format (HTTP proxy)
    local actual_proxy_port=$(grep "Mixed(http+socks) proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
    [ -z "$actual_proxy_port" ] && actual_proxy_port=$(grep "HTTP proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
    
    local actual_ui_port=$(grep "RESTful API listening at:" "$log_file" | tail -1 | sed -n 's/.*:\([0-9]\+\)[^0-9]*$/\1/p')
    local actual_dns_port=$(grep "DNS server(UDP) listening at:" "$log_file" | tail -1 | sed -n 's/.*\[::\]:\([0-9]*\).*/\1/p')
    
    # 从配置文件获取期望端口进行比较
    local config_proxy_port=$("$BIN_YQ" '.mixed-port // 7890' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_ui_addr=$("$BIN_YQ" '.external-controller // "127.0.0.1:9090"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_ui_port=${config_ui_addr##*:}
    local config_dns_addr=$("$BIN_YQ" '.dns.listen // "0.0.0.0:15353"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_dns_port=${config_dns_addr##*:}
    
    local port_changed=false
    
    # 设置实际监听端口到变量
    if [ -n "$actual_proxy_port" ]; then
        MIXED_PORT=$actual_proxy_port
        [ "$actual_proxy_port" != "$config_proxy_port" ] && {
            _failcat "🔄" "mihomo自动调整代理端口: $config_proxy_port → $actual_proxy_port"
            port_changed=true
        }
    else
        MIXED_PORT=$config_proxy_port
    fi
    
    if [ -n "$actual_ui_port" ]; then
        UI_PORT=$actual_ui_port
        [ "$actual_ui_port" != "$config_ui_port" ] && {
            _failcat "🔄" "mihomo自动调整UI端口: $config_ui_port → $actual_ui_port"
            port_changed=true
        }
    else
        UI_PORT=$config_ui_port
    fi
    
    if [ -n "$actual_dns_port" ]; then
        DNS_PORT=$actual_dns_port
        [ "$actual_dns_port" != "$config_dns_port" ] && {
            _failcat "🔄" "mihomo自动调整DNS端口: $config_dns_port → $actual_dns_port"
            port_changed=true
        }
    else
        DNS_PORT=$config_dns_port
    fi
    
    # 只有当端口有变化时才显示最终端口分配并重新设置系统代理
    if [ "$port_changed" = true ]; then
        _okcat "最终端口分配 - 代理:$MIXED_PORT UI:$UI_PORT DNS:$DNS_PORT"
        # 保存实际监听端口到状态文件
        _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT"
        # 端口变化时重新设置系统代理环境变量
        _set_system_proxy
    fi
}

watch_proxy() {
    # 新开交互式shell，且无代理变量时
    [ -z "$http_proxy" ] && [[ $- == *i* ]] && {
        # 检查用户是否启用系统代理
        local system_proxy_status=$("$BIN_YQ" '.system-proxy.enable // true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)

        # 仅当用户启用系统代理且 mihomo 进程运行时，自动写入环境变量
        if [ "$system_proxy_status" = "true" ] && is_mihomo_running; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _set_system_proxy
        fi
    }
}

function clashoff() {
    # Stop mihomo process
    stop_mihomo
    _unset_system_proxy
    _okcat '已关闭代理环境'
}

function clashrestart() {
    _okcat "正在重启代理服务..."
    { clashoff && clashon; } >&/dev/null && _okcat "代理服务重启成功"
}

function clashproxy() {
    case "$1" in
    on)
        if is_mihomo_running; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _set_system_proxy
            _okcat '已开启系统代理'
        else
            _failcat '无法开启系统代理：mihomo 进程未运行'
            return 1
        fi
        ;;
    off)
        _unset_system_proxy
        _okcat '已关闭系统代理'
        ;;
    status)
        local system_proxy_status=$("$BIN_YQ" '.system-proxy.enable' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)
        if [ "$system_proxy_status" = "false" ]; then
            _failcat "系统代理：关闭"
            return 1
        fi
        
        if is_mihomo_running; then
            _okcat "系统代理：开启
http_proxy： $http_proxy
socks_proxy：$all_proxy"
        else
            _failcat "系统代理：配置为开启，但 mihomo 进程未运行"
            return 1
        fi
        ;;
    *)
        cat <<EOF
用法: clashproxy [on|off|status]
    on      开启系统代理
    off     关闭系统代理
    status  查看系统代理状态
EOF
        ;;
    esac
}

function clashport() {
    local action=$1
    shift || true

    case "$action" in
    ""|status)
        _load_port_preferences
        _get_proxy_port
        local mode_msg
        if [ "$PORT_PREF_MODE" = "manual" ] && [ -n "$PORT_PREF_VALUE" ]; then
            mode_msg="固定(${PORT_PREF_VALUE})"
        else
            mode_msg="自动"
        fi
        _okcat "端口模式：$mode_msg"
        _okcat "当前代理端口：$MIXED_PORT"
        ;;
    auto)
        _save_port_preferences auto ""
        _okcat "已切换为自动分配代理端口"
        if is_mihomo_running; then
            _okcat "正在重新应用配置..."
            clashrestart
        fi
        ;;
    set|manual)
        local manual_port=$1
        local prefer_auto=false

        while true; do
            if [ -z "$manual_port" ]; then
                printf "请输入想要固定的代理端口 [1024-65535]: "
                read -r manual_port
            fi

            if [ -z "$manual_port" ]; then
                _failcat "未输入端口"
                continue
            fi

            if ! [[ $manual_port =~ ^[0-9]+$ ]] || [ "$manual_port" -lt 1024 ] || [ "$manual_port" -gt 65535 ]; then
                _failcat "端口号无效，请输入 1024-65535 之间的数字"
                manual_port=""
                continue
            fi

            if _is_already_in_use "$manual_port" "$BIN_KERNEL_NAME"; then
                _failcat '🎯' "端口 $manual_port 已被占用"
                printf "选择操作 [r]重新输入/[a]自动分配: "
                read -r choice
                case "$choice" in
                [aA])
                    prefer_auto=true
                    break
                    ;;
                [rR])
                    manual_port=""
                    continue
                    ;;
                *)
                    manual_port=""
                    continue
                    ;;
                esac
            fi

            break
        done

        if [ "$prefer_auto" = true ]; then
            _save_port_preferences auto ""
            _okcat "已切换为自动分配代理端口"
        else
            _save_port_preferences manual "$manual_port"
            _okcat "已固定代理端口：$manual_port"
        fi

        if is_mihomo_running; then
            _okcat "正在重新应用配置..."
            clashrestart
        fi
        ;;
    *)
        cat <<EOF
用法: clashport [status|auto|set <port>]
    status          查看当前代理端口模式与端口
    auto            切换为自动分配代理端口
    set <port>      固定代理端口，端口冲突时可选择重新输入或自动分配
EOF
        ;;
    esac
}

function clashstatus() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    
    # Show subscription URL
    local subscription_url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    if [ -n "$subscription_url" ]; then
        _okcat "订阅地址: $subscription_url"
    else
        _failcat "订阅地址: 未设置"
    fi
    
    if is_mihomo_running; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        _okcat "mihomo 进程状态: 运行中"
        _okcat "进程 PID: $pid"
        _okcat "运行时间: ${uptime:-未知}"
        _okcat "配置文件: $MIHOMO_CONFIG_RUNTIME"
        _okcat "日志文件: $log_file"
        
        # Show proxy port status
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _okcat "代理端口: $MIXED_PORT"
            _okcat "管理端口: $UI_PORT"
            _okcat "DNS端口: $DNS_PORT"
        else
            _failcat "配置文件不存在，无法获取端口信息"
        fi
        
        # Show system proxy status
        clashproxy status
    else
        _failcat "mihomo 进程状态: 未运行"
        [ -f "$pid_file" ] && {
            _failcat "发现残留 PID 文件，已清理"
            rm -f "$pid_file"
        }
        return 1
    fi
}


function clashpick() {
    local group=""
    local keyword=""
    local list_groups=false
    local plain=false
    local test_delay=true

    while [ "$#" -gt 0 ]; do
        case "$1" in
        -g|--group)
            [ -n "$2" ] || {
                _failcat "缺少策略组名称"
                return 1
            }
            group=$2
            shift 2
            ;;
        --groups|groups)
            list_groups=true
            shift
            ;;
        --plain|--no-fzf)
            plain=true
            shift
            ;;
        --test)
            test_delay=true
            shift
            ;;
        --no-test|--cached)
            test_delay=false
            shift
            ;;
        -h|--help)
            cat <<EOF
用法: clash pick [关键词] [-g 策略组] [--plain] [--no-test]

示例:
    clash pick              选择 Proxy 策略组中的节点
    clash pick 美国         只显示名称/类型包含“美国”的节点
    clash pick -g 自动选择  选择指定策略组中的节点
    clash pick groups       列出可切换的策略组

说明:
    默认会刷新并显示节点延迟。有 fzf 且处于交互式终端时会打开可搜索列表；否则使用编号菜单。
EOF
            return 0
            ;;
        *)
            keyword="${keyword:+$keyword }$1"
            shift
            ;;
        esac
    done

    if ! is_mihomo_running; then
        _failcat "mihomo 进程未运行，请先执行 clash on"
        return 1
    fi

    _verify_actual_ports 2>/dev/null || true
    _get_ui_port

    local api_secret=""
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        api_secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
        [ "$api_secret" = "null" ] && api_secret=""
    fi

    CLASH_PICK_API="http://127.0.0.1:${UI_PORT}" \
    CLASH_PICK_SECRET="$api_secret" \
    CLASH_PICK_GROUP="$group" \
    CLASH_PICK_FILTER="$keyword" \
    CLASH_PICK_LIST_GROUPS="$([ "$list_groups" = true ] && printf 1 || printf 0)" \
    CLASH_PICK_PLAIN="$([ "$plain" = true ] && printf 1 || printf 0)" \
    CLASH_PICK_TEST_DELAY="$([ "$test_delay" = true ] && printf 1 || printf 0)" \
    python3 <<'PY'
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

api_base = os.environ["CLASH_PICK_API"].rstrip("/")
secret = os.environ.get("CLASH_PICK_SECRET", "")
requested_group = os.environ.get("CLASH_PICK_GROUP", "").strip()
keyword = os.environ.get("CLASH_PICK_FILTER", "").strip()
list_groups = os.environ.get("CLASH_PICK_LIST_GROUPS") == "1"
plain = os.environ.get("CLASH_PICK_PLAIN") == "1"
test_delay = os.environ.get("CLASH_PICK_TEST_DELAY") == "1"


def request(method, path, payload=None, quiet=False):
    data = None
    headers = {"Content-Type": "application/json"}
    if secret:
        headers["Authorization"] = f"Bearer {secret}"
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(api_base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        if quiet:
            return None
        body = exc.read().decode("utf-8", "replace")[:300]
        print(f"mihomo API 请求失败: HTTP {exc.code} {body}", file=sys.stderr)
        raise SystemExit(1)
    except Exception as exc:
        if quiet:
            return None
        print(f"mihomo API 不可用: {exc}", file=sys.stderr)
        raise SystemExit(1)
    if not raw:
        return None
    return json.loads(raw.decode("utf-8"))


def is_switch_group(item):
    return isinstance(item, dict) and isinstance(item.get("all"), list) and item.get("type") in {
        "Selector",
        "URLTest",
        "Fallback",
        "LoadBalance",
    }


def fetch_delay(name):
    encoded = urllib.parse.quote(name, safe="")
    path = f"/proxies/{encoded}/delay?timeout=3000&url=https%3A%2F%2Fwww.google.com%2Fgenerate_204"
    data = request("GET", path, quiet=True)
    if not isinstance(data, dict):
        return "timeout"
    delay = data.get("delay") if isinstance(data, dict) else None
    if delay is None or delay < 0:
        return "timeout"
    return f"{delay}ms"


data = request("GET", "/proxies")
proxies = data.get("proxies", {})
groups = [(name, item) for name, item in proxies.items() if is_switch_group(item)]
groups.sort(key=lambda pair: (pair[0] != "Proxy", pair[0]))

if not groups:
    print("没有发现可切换的策略组", file=sys.stderr)
    raise SystemExit(1)

if list_groups:
    print("可切换策略组:")
    for idx, (name, item) in enumerate(groups, 1):
        now = item.get("now") or "-"
        count = len(item.get("all") or [])
        print(f"{idx:>3}. {name}  当前: {now}  可选: {count}")
    raise SystemExit(0)

group_names = [name for name, _ in groups]
if requested_group:
    if requested_group in proxies and is_switch_group(proxies[requested_group]):
        group = requested_group
    else:
        matches = [name for name in group_names if requested_group.casefold() in name.casefold()]
        if len(matches) == 1:
            group = matches[0]
        else:
            print(f"未找到唯一策略组: {requested_group}", file=sys.stderr)
            print("可用策略组: " + ", ".join(group_names), file=sys.stderr)
            raise SystemExit(1)
elif "Proxy" in proxies and is_switch_group(proxies["Proxy"]):
    group = "Proxy"
else:
    group = group_names[0]

group_info = proxies[group]
current = group_info.get("now") or ""
query = keyword.casefold()
rows = []
for name in group_info.get("all") or []:
    item = proxies.get(name, {})
    proxy_type = item.get("type", "")
    now = item.get("now", "")
    history = item.get("history") or []
    delay = ""
    if history and isinstance(history[-1], dict) and history[-1].get("delay") is not None:
        delay = f"{history[-1]['delay']}ms"
    haystack = f"{name} {proxy_type} {now}".casefold()
    if query and query not in haystack:
        continue
    rows.append({"name": name, "type": proxy_type, "delay": delay, "current": name == current})

if not rows:
    print(f"策略组 [{group}] 下没有匹配节点: {keyword}", file=sys.stderr)
    raise SystemExit(1)

if test_delay:
    limit = min(len(rows), 80)
    print(f"正在测试延迟: {limit}/{len(rows)} 个节点 ...", file=sys.stderr)
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
        futures = {
            executor.submit(fetch_delay, row["name"]): idx
            for idx, row in enumerate(rows[:limit])
        }
        for future in concurrent.futures.as_completed(futures):
            rows[futures[future]]["delay"] = future.result()


def render_line(index, row):
    mark = "*" if row["current"] else " "
    meta = row["type"] or "Unknown"
    if row["delay"]:
        meta = f"{meta}, {row['delay']}"
    return f"{index:>3}. {mark} {row['name']} [{meta}]"


selected_index = None
lines = [render_line(i, row) for i, row in enumerate(rows, 1)]
use_fzf = (not plain and shutil.which("fzf") and sys.stdin.isatty() and sys.stdout.isatty())
exact_matches = [idx for idx, row in enumerate(rows) if keyword and row["name"] == keyword]

if len(exact_matches) == 1:
    selected_index = exact_matches[0]
elif use_fzf:
    prompt = f"{group}> "
    proc = subprocess.run(
        ["fzf", "--height=80%", "--reverse", "--prompt", prompt, "--query", keyword],
        input="\n".join(lines),
        text=True,
        stdout=subprocess.PIPE,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        print("已取消")
        raise SystemExit(1)
    selected_index = int(proc.stdout.strip().split(".", 1)[0]) - 1
else:
    print(f"策略组: {group}")
    print(f"当前节点: {current or '-'}")
    if keyword:
        print(f"过滤关键词: {keyword}")
    print("")
    for line in lines:
        print(line)
    if not sys.stdin.isatty():
        if len(rows) == 1:
            selected_index = 0
        else:
            print("非交互式终端下需要过滤到唯一节点", file=sys.stderr)
            raise SystemExit(1)
    else:
        choice = input("\n选择节点编号 (空回车取消): ").strip()
        if not choice:
            print("已取消")
            raise SystemExit(1)
        if not choice.isdigit() or not (1 <= int(choice) <= len(rows)):
            print("节点编号无效", file=sys.stderr)
            raise SystemExit(1)
        selected_index = int(choice) - 1

selected = rows[selected_index]["name"]
encoded_group = urllib.parse.quote(group, safe="")
request("PUT", f"/proxies/{encoded_group}", {"name": selected})
print(f"已切换策略组 [{group}] -> {selected}")
PY
}

function clashui() {
    _get_ui_port
    # 公网ip
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 $query_url)
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}

function clashtui() {
    local clashctl_bin="${MIHOMO_BASE_DIR}/bin/clashctl-tui"

    # 懒加载: 首次使用时下载 TUI 工具
    if [ ! -x "$clashctl_bin" ]; then
        _download_tui || return 1
    fi

    # 确保 mihomo 运行
    if ! is_mihomo_running; then
        _okcat "正在启动 mihomo..."
        clashon || return 1
    fi

    # 获取实际端口
    _verify_actual_ports
    _get_ui_port

    # 检查端口可用性
    if ! _is_bind "$UI_PORT" 2>/dev/null; then
        _failcat "API 端口 ${UI_PORT} 未监听，请执行 clash status 检查"
        return 1
    fi

    # 生成配置并启动 TUI
    local endpoint="http://127.0.0.1:${UI_PORT}"
    local api_secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_file="${MIHOMO_BASE_DIR}/config/clashctl.ron"

    _generate_clashctl_config "mihomo-local" "$endpoint" "$api_secret" > "$config_file" || {
        _failcat "生成配置失败"
        return 1
    }

    _okcat "正在连接 $endpoint ..."
    "$clashctl_bin" --config-path "$config_file" tui
}

_merge_config_restart() {
    # Use user-accessible temp directory instead of /tmp
    local backup="${MIHOMO_BASE_DIR}/config/runtime.backup"
    
    # Ensure config directory exists
    mkdir -p "$(dirname "$backup")"
    
    # Backup current runtime config
    cat "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null > "$backup"
    
    # Merge configurations using user permissions
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    # Validate merged configuration
    _valid_config "$MIHOMO_CONFIG_RUNTIME" || {
        # Restore backup on validation failure
        cat "$backup" > "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null
        _error_quit "验证失败：请检查 Mixin 配置"
    }
    
    # Clean up backup file
    rm -f "$backup"
    
    clashrestart
}

function clashsecret() {
    case "$#" in
    0)
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            _okcat "当前密钥：$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)"
        else
            _failcat "运行时配置文件不存在"
        fi
        ;;
    1)
        # Ensure mixin config directory exists
        mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
        "$BIN_YQ" -i ".secret = \"$1\"" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        local tun_status=$("$BIN_YQ" '.tun.enable' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        # shellcheck disable=SC2015
        [ "$tun_status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
    else
        _failcat 'Tun 状态：配置文件不存在'
        return 1
    fi
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    # Ensure mixin config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _merge_config_restart && _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    # Ensure mixin config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _merge_config_restart
    sleep 0.5s
    
    # Check if mihomo is running and tun mode is working
    if is_mihomo_running; then
        local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
        # Check recent log entries for tun mode status
        if [ -f "$log_file" ]; then
            # Look for tun-related messages in the last few lines
            tail -20 "$log_file" 2>/dev/null | grep -i "tun" >/dev/null 2>&1 && {
                _okcat "Tun 模式已开启"
            } || {
                _okcat "Tun 模式已开启 (请检查日志确认状态: $log_file)"
            }
        else
            _okcat "Tun 模式已开启"
        fi
    else
        _failcat "Tun 模式配置已更新，但 mihomo 进程未运行"
    fi
}

function clashtun() {
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

_lanstatus() {
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        local lan_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        if [ "$lan_status" = 'true' ]; then
            _okcat '局域网访问：已开启'
        else
            _failcat '局域网访问：已关闭'
        fi
    else
        _failcat '局域网访问：配置文件不存在'
        return 1
    fi
}

_lanoff() {
    _lanstatus >/dev/null 2>&1 && {
        local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        [ "$current_status" = 'false' ] && return 0
    }

    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.allow-lan = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _merge_config_restart && _okcat "局域网访问已关闭"
}

_lanon() {
    local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
    [ "$current_status" = 'true' ] && return 0

    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.allow-lan = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _merge_config_restart && _okcat "局域网访问已开启"
}

function clashlan() {
    case "$1" in
    on)
        _lanon
        ;;
    off)
        _lanoff
        ;;
    status)
        _lanstatus
        ;;
    *)
        _lanstatus
        ;;
    esac
}

_profile_store() {
    printf "%s\n" "${MIHOMO_BASE_DIR}/config/profiles.tsv"
}

_profile_active_file() {
    printf "%s\n" "${MIHOMO_BASE_DIR}/config/profile.active"
}

_profile_init() {
    local store=$(_profile_store)
    mkdir -p "$(dirname "$store")"
    [ -f "$store" ] && return 0

    local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    : > "$store"
    [ "${url:0:4}" = "http" ] && printf "default\t%s\n" "$url" >> "$store"
}

_profile_url_by_name() {
    local name=$1
    local store=$(_profile_store)
    awk -F '\t' -v n="$name" '$1 == n {print $2; found=1; exit} END {exit found ? 0 : 1}' "$store"
}

_profile_write_active() {
    local active=$1
    local active_file=$(_profile_active_file)
    mkdir -p "$(dirname "$active_file")"
    printf "%s\n" "$active" > "$active_file"
}

_profile_current_name() {
    local active_file=$(_profile_active_file)
    [ -f "$active_file" ] && {
        cat "$active_file" 2>/dev/null
        return 0
    }

    local current_url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    local store=$(_profile_store)
    [ -f "$store" ] && awk -F '\t' -v u="$current_url" '$2 == u {print $1; found=1; exit} END {exit found ? 0 : 1}' "$store"
}

function clashprofile() {
    local action=${1:-list}
    shift || true
    _profile_init

    local store=$(_profile_store)
    case "$action" in
    list|ls)
        local active=$(_profile_current_name)
        _okcat "订阅配置:"
        if [ "$active" = "direct" ]; then
            printf "  * 0. direct  不使用代理\n"
        else
            printf "    0. direct  不使用代理\n"
        fi
        awk -F '\t' -v active="$active" 'NF >= 2 {
            mark = ($1 == active) ? "*" : " "
            printf("  %s %d. %s  %s\n", mark, NR, $1, $2)
        }' "$store"
        ;;
    add)
        local name=$1
        local url=$2
        if [ -z "$name" ] || [ -z "$url" ]; then
            _failcat "用法: clash profile add <名称> <订阅URL>"
            return 1
        fi
        if printf "%s" "$name" | grep -q '[[:space:]]'; then
            _failcat "订阅名称不要包含空格"
            return 1
        fi
        if [ "${url:0:4}" != "http" ]; then
            _failcat "订阅 URL 必须以 http 或 https 开头"
            return 1
        fi
        local tmp="${store}.tmp.$$"
        awk -F '\t' -v n="$name" '$1 != n' "$store" > "$tmp" 2>/dev/null || true
        printf "%s\t%s\n" "$name" "$url" >> "$tmp"
        mv -f "$tmp" "$store"
        _okcat "已保存订阅: $name"
        ;;
    rm|remove|delete)
        local name=$1
        [ -n "$name" ] || {
            _failcat "用法: clash profile rm <名称>"
            return 1
        }
        local tmp="${store}.tmp.$$"
        awk -F '\t' -v n="$name" '$1 != n' "$store" > "$tmp"
        mv -f "$tmp" "$store"
        _okcat "已删除订阅: $name"
        ;;
    use|switch)
        local name=$1
        [ -n "$name" ] || {
            _failcat "用法: clash profile use <名称|direct>"
            return 1
        }
        if [ "$name" = "direct" ] || [ "$name" = "off" ] || [ "$name" = "none" ]; then
            _profile_write_active direct
            clashoff
            _okcat "已切换到直连模式"
            return 0
        fi

        local url
        if [ "${name:0:4}" = "http" ]; then
            url=$name
            name=temporary
        else
            url=$(_profile_url_by_name "$name") || {
                _failcat "未找到订阅: $name"
                return 1
            }
        fi
        _profile_write_active "$name"
        mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
        printf "%s\n" "$url" > "$MIHOMO_CONFIG_URL"
        clashupdate "$url"
        ;;
    pick|menu)
        local active=$(_profile_current_name)
        clashprofile list
        printf "\n选择订阅编号 (0 为直连，空回车取消): "
        read -r choice
        [ -n "$choice" ] || {
            _okcat "已取消"
            return 0
        }
        if ! [[ $choice =~ ^[0-9]+$ ]]; then
            _failcat "请输入数字编号"
            return 1
        fi
        if [ "$choice" = "0" ]; then
            clashprofile use direct
            return $?
        fi
        local name
        name=$(awk -F '\t' -v n="$choice" 'NR == n {print $1; found=1; exit} END {exit found ? 0 : 1}' "$store") || {
            _failcat "订阅编号无效"
            return 1
        }
        clashprofile use "$name"
        ;;
    current)
        local active=$(_profile_current_name)
        [ -n "$active" ] || active="unknown"
        _okcat "当前订阅: $active"
        ;;
    *)
        cat <<EOF
用法: clash profile <命令>
    list                 列出订阅和直连模式
    add <名称> <URL>      保存一个订阅
    use <名称|direct>     切换订阅；direct 表示不使用代理
    pick                 编号交互式切换订阅
    rm <名称>             删除订阅
    current              查看当前订阅
EOF
        ;;
    esac
}

_check_url() {
    local label=$1
    local url=$2
    local proxy_url=$3
    local direct_mode=$4

    set --
    [ -n "$proxy_url" ] && set -- "$@" --proxy "$proxy_url"
    [ "$direct_mode" = "direct" ] && set -- "$@" --noproxy "*"

    local result
    result=$(curl -sS -o /dev/null \
        --connect-timeout 5 \
        --max-time 12 \
        -w "%{http_code} connect=%{time_connect} total=%{time_total}" \
        "$@" \
        "$url" 2>&1)
    local code=$?
    if [ "$code" -eq 0 ]; then
        _okcat "$label: $result"
    else
        _failcat "$label: failed ($result)"
    fi
}

function clashcheck() {
    _verify_actual_ports 2>/dev/null || true
    _get_proxy_port

    local proxy="http://127.0.0.1:${MIXED_PORT}"
    _okcat "代理端口: ${MIXED_PORT}"
    if is_mihomo_running; then
        _okcat "mihomo: running"
    else
        _failcat "mihomo: not running"
    fi

    _check_url "Google via proxy" "https://www.google.com/generate_204" "$proxy" ""
    _check_url "OpenAI via proxy" "https://api.openai.com/v1/models" "$proxy" ""
    _check_url "Baidu direct" "https://www.baidu.com" "" direct
    _check_url "Tencent direct" "https://www.qq.com" "" direct
}

_hostproxy_name() {
    local port=${1:-18888}
    printf "LOCAL-SSH-%s\n" "$port"
}

_hostproxy_apply() {
    local name=$1
    local port=$2
    local mode=$3

    HOST_PROXY_FILE="$MIHOMO_CONFIG_MIXIN" \
    HOST_PROXY_NAME="$name" \
    HOST_PROXY_PORT="$port" \
    HOST_PROXY_MODE="$mode" \
    python3 <<'PY'
import os
from pathlib import Path

import yaml

path = Path(os.environ["HOST_PROXY_FILE"])
name = os.environ["HOST_PROXY_NAME"]
port = int(os.environ["HOST_PROXY_PORT"])
mode = os.environ["HOST_PROXY_MODE"]

if path.exists():
    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
else:
    data = {}

proxies = [item for item in data.get("proxies", []) or [] if item.get("name") != name]
groups = data.get("proxy-groups", []) or []

if mode == "on":
    proxies.insert(0, {
        "name": name,
        "type": "socks5",
        "server": "127.0.0.1",
        "port": port,
    })

for group in groups:
    group_proxies = [item for item in group.get("proxies", []) or [] if item != name]
    group_type = str(group.get("type", "")).lower()
    if mode == "on" and (
        group.get("name") in {"Proxy", "GLOBAL", "BoostNet"} or group_type == "select"
    ):
        group["proxies"] = [name] + group_proxies
    else:
        group["proxies"] = group_proxies

data["proxies"] = proxies
data["proxy-groups"] = groups
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("w", encoding="utf-8") as fh:
    yaml.safe_dump(data, fh, allow_unicode=True, sort_keys=False)
PY
}

function clashhostproxy() {
    local action=${1:-status}
    local port=${2:-18888}
    local name=$(_hostproxy_name "$port")

    case "$action" in
    on|enable)
        if ! [[ $port =~ ^[0-9]+$ ]]; then
            _failcat "端口必须是数字"
            return 1
        fi
        mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
        _hostproxy_apply "$name" "$port" on || {
            _failcat "写入本机代理节点失败"
            return 1
        }
        _merge_config_restart || return 1
        _okcat "已加入本机代理节点: $name"
        _okcat "请确保 SSH 已建立 RemoteForward: A800:${port} -> 本机代理端口"
        clashpick --plain --no-test -g BoostNet "$name" 2>/dev/null || true
        clashpick --plain --no-test -g GLOBAL "$name" 2>/dev/null || true
        ;;
    off|disable)
        _hostproxy_apply "$name" "$port" off || {
            _failcat "移除本机代理节点失败"
            return 1
        }
        _merge_config_restart || return 1
        _okcat "已移除本机代理节点: $name"
        ;;
    status)
        if _is_bind "$port" >/dev/null 2>&1; then
            _okcat "A800 本地端口 ${port}: listening"
        else
            _failcat "A800 本地端口 ${port}: not listening"
        fi
        _check_url "Host proxy Google" "https://www.google.com/generate_204" "socks5h://127.0.0.1:${port}" ""
        ;;
    *)
        cat <<EOF
用法: clash hostproxy [on|off|status] [端口]
    on 18888      加入并优先使用本机 SSH 转发代理节点
    off 18888     移除这个本机代理节点
    status 18888  测试 A800 上的本机代理转发口
EOF
        ;;
    esac
}

function clashmenu() {
    while true; do
        cat <<EOF

Clash for Lab 快捷菜单
  1. 查看网络情况
  2. 切换订阅/直连
  3. 切换节点
  4. 启用本机代理兜底
  5. 设置代理端口
  6. 查看状态
  0. 退出
EOF
        printf "请选择: "
        read -r choice
        case "$choice" in
        1) clashcheck ;;
        2) clashprofile pick ;;
        3) clashpick ;;
        4)
            printf "本机代理转发端口 [18888]: "
            read -r port
            clashhostproxy on "${port:-18888}"
            ;;
        5)
            printf "固定代理端口 [7890，留空为自动]: "
            read -r port
            if [ -n "$port" ]; then
                clashport set "$port"
            else
                clashport auto
            fi
            ;;
        6) clashstatus ;;
        0|"") return 0 ;;
        *) _failcat "未知选项: $choice" ;;
        esac
    done
}

function clashsubscribe() {
    case "$#" in
    0)
        # Show current subscription URL
        local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
        if [ -n "$url" ]; then
            _okcat "当前订阅地址: $url"
        else
            _failcat "未设置订阅地址"
            return 1
        fi
        ;;
    1)
        # Set new subscription URL
        local new_url="$1"
        if [ "${new_url:0:4}" != "http" ]; then
            _failcat "无效的订阅地址，必须以 http 或 https 开头"
            return 1
        fi
        
        # Save URL
        mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
        echo "$new_url" > "$MIHOMO_CONFIG_URL"
        _okcat "订阅地址已设置: $new_url"
        
        # Ask if user wants to update immediately
        printf "是否立即更新订阅配置? [y/N]: "
        read -r response
        case "$response" in
        [yY]|[yY][eE][sS])
            clashupdate "$new_url"
            ;;
        *)
            _okcat "订阅地址已保存，使用 'clash update' 命令更新配置"
            ;;
        esac
        ;;
    *)
        cat <<EOF
用法: clash subscribe [URL]
    无参数      显示当前订阅地址
    URL         设置新的订阅地址
EOF
        ;;
    esac
}

function clashupdate() {
    local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    local is_auto

    case "$1" in
    auto)
        is_auto=true
        [ -n "$2" ] && url=$2
        ;;
    log)
        tail "${MIHOMO_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${MIHOMO_CONFIG_RAW} 进行更新..."
        url="file://$MIHOMO_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置用户级定时任务
    [ "$is_auto" = true ] && {
        # Persist URL for cron runs (cron executes `mihomoctl update`, which reads MIHOMO_CONFIG_URL).
        [ "${url:0:4}" = "http" ] && {
            mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
            echo "$url" > "$MIHOMO_CONFIG_URL"
        }

        # Check if crontab entry already exists
        crontab -l 2>/dev/null | grep -qs 'mihomoctl_auto_update' || {
            # Add user-level crontab entry (every 2 days at midnight)
            (crontab -l 2>/dev/null; echo "0 0 */2 * * $_SHELL -i -c 'mihomoctl update' # mihomoctl_auto_update") | crontab -
        }
        _okcat "已设置用户级定时更新订阅 (每2天执行一次)" && return 0
    }

    _okcat '👌' "正在下载：原配置已备份..."
    
    # Ensure directories exist and backup using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RAW_BAK")" "$(dirname "$MIHOMO_UPDATE_LOG")"
    cp "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW_BAK" 2>/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        # Restore backup using user permissions
        cp "$MIHOMO_CONFIG_RAW_BAK" "$MIHOMO_CONFIG_RAW" 2>/dev/null
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" >> "${MIHOMO_UPDATE_LOG}"
        return 1
    }

    _download_config "$MIHOMO_CONFIG_RAW" "$url" || { _rollback "下载失败：已回滚配置" || true; return 1; }
    _valid_config "$MIHOMO_CONFIG_RAW" || { _rollback "转换失败：已回滚配置，转换日志：$BIN_SUBCONVERTER_LOG" || true; return 1; }

    _merge_config_restart || return 1
    _okcat '🍃' '订阅更新成功'
    
    # Save URL and log success using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
    echo "$url" > "$MIHOMO_CONFIG_URL"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" >> "${MIHOMO_UPDATE_LOG}"
}

function clashmixin() {
    case "$1" in
    -e)
        vim "$MIHOMO_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less -f "$MIHOMO_CONFIG_RUNTIME"
        ;;
    *)
        less -f "$MIHOMO_CONFIG_MIXIN"
        ;;
    esac
}

function clashctl() {
    case "$1" in
    on)
        clashon
        ;;
    off)
        clashoff
        ;;
    restart)
        clashrestart
        ;;
    ui)
        clashui
        ;;
    status)
        shift
        clashstatus "$@"
        ;;
    proxy)
        shift
        clashproxy "$@"
        ;;
    check|test|doctor)
        shift
        clashcheck "$@"
        ;;
    menu)
        shift
        clashmenu "$@"
        ;;
    profile|profiles)
        shift
        clashprofile "$@"
        ;;
    hostproxy|host)
        shift
        clashhostproxy "$@"
        ;;
    port)
        shift
        clashport "$@"
        ;;
    tun)
        shift
        clashtun "$@"
        ;;
    lan)
        shift
        clashlan "$@"
        ;;
    mixin)
        shift
        clashmixin "$@"
        ;;
    secret)
        shift
        clashsecret "$@"
        ;;
    subscribe)
        shift
        clashsubscribe "$@"
        ;;
    update)
        shift
        clashupdate "$@"
        ;;
    pick)
        shift
        clashpick "$@"
        ;;
    tui)
        clashtui
        ;;
    *)
        cat <<EOF

Usage:
    clash COMMAND  [OPTION]
    mihomo COMMAND [OPTION]
    mihomoctl COMMAND [OPTION]

Commands:
    on                      开启代理
    off                     关闭代理
    restart                 重启代理服务
    status                  进程运行状态
    tui                     交互式终端界面（TUI）
    menu                    一键交互菜单
    check                   测试 Google/OpenAI/国内网络
    profile  [list|add|use|pick|rm]  多订阅/直连切换
    hostproxy [on|off|status] [端口] 本机 SSH 代理兜底
    pick     [关键词] [-g 策略组] 快速选择代理节点
    ui                      Web 控制台地址
    proxy    [on|off|status]       系统代理环境变量
    port     [status|auto|set]     代理端口模式设置
    tun      [on|off|status]       Tun 模式 (需要权限)
    lan      [on|off|status]       局域网访问控制
    mixin    [-e|-r]        Mixin 配置文件
    secret   [SECRET]       Web 控制台密钥
    subscribe [URL]         设置或查看订阅地址
    update   [auto|log]     更新订阅配置

说明:
    • 用户空间运行，无需 sudo 权限
    • 配置目录: ~/tools/mihomo/
    • 日志目录: ~/tools/mihomo/logs/
    • 进程管理: 基于 PID 文件和 nohup

EOF
        ;;
    esac
}

function mihomoctl() {
    clashctl "$@"
}

function clash() {
    clashctl "$@"
}

function mihomo() {
    clashctl "$@"
}
