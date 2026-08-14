#!/usr/bin/env bash
# ovpn 公共运行时；只由 ovpn.sh 加载。

readonly OVPN_INSTALL_PATH="/usr/local/bin/ovpn"
readonly OVPN_LIB_INSTALL_DIR="/usr/local/lib/ovpn"
readonly OVPN_EASYRSA="/usr/share/easy-rsa/easyrsa"
readonly OVPN_SERVICE="openvpn-server@server.service"
readonly OVPN_SERVER_DIR="/etc/openvpn/server"
readonly OVPN_SERVER_CONF="$OVPN_SERVER_DIR/server.conf"
readonly OVPN_RUNTIME_CA="$OVPN_SERVER_DIR/ca.crt"
readonly OVPN_RUNTIME_SERVER_CERT="$OVPN_SERVER_DIR/server.crt"
readonly OVPN_RUNTIME_SERVER_KEY="$OVPN_SERVER_DIR/server.key"
readonly OVPN_RUNTIME_CRL="$OVPN_SERVER_DIR/crl.pem"
readonly OVPN_RUNTIME_TLS_CRYPT_V2="$OVPN_SERVER_DIR/tls-crypt-v2.key"
readonly OVPN_AUTH_VERIFY_SCRIPT="$OVPN_SERVER_DIR/auth-verify.sh"
readonly OVPN_DROPIN="/etc/systemd/system/$OVPN_SERVICE.d/ovpn.conf"
readonly OVPN_SYSCTL_FILE="/etc/sysctl.d/99-ovpn.conf"
readonly OVPN_NAT_SERVICE="ovpn-nat.service"
readonly OVPN_NAT_UNIT="/etc/systemd/system/$OVPN_NAT_SERVICE"
readonly OVPN_NAT_RULES="$OVPN_SERVER_DIR/ovpn-nat.nft"
readonly OVPN_PURGE_BACKUP_ROOT="/var/backups/ovpn"

OVPN_DRY_RUN="${OVPN_DRY_RUN:-0}"
OVPN_NO_AUDIT="${OVPN_NO_AUDIT:-0}"
OVPN_STATE_DIR="${OVPN_STATE_DIR:-/etc/openvpn/ovpn}"
OVPN_AUDIT_EVENTS=()
OVPN_AUDIT_FILES=()
OVPN_TEMP_PATHS=()

ovpn_die() { printf '错误：%s\n' "$*" >&2; exit 1; }
ovpn_info() { printf '==> %s\n' "$*"; }
ovpn_have() { command -v "$1" >/dev/null 2>&1; }

ovpn_register_temp() { OVPN_TEMP_PATHS+=("$1"); }

ovpn_cleanup_temporaries() {
    local path
    for path in "${OVPN_TEMP_PATHS[@]}"; do
        [[ -z "$path" ]] || rm -rf -- "$path"
    done
}

ovpn_require_root() {
    [[ "$OVPN_DRY_RUN" == 1 ]] && return
    (( EUID == 0 )) || ovpn_die "此操作需要 root 权限，请使用 sudo"
}

ovpn_require_command() {
    ovpn_have "$1" || ovpn_die "缺少命令：$1；请先运行 ovpn core install"
}

ovpn_validate_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ && "$1" != server ]]
}

ovpn_validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

ovpn_validate_days() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 36500 ))
}

ovpn_validate_state_dir() {
    [[ "$OVPN_STATE_DIR" == /* ]] || ovpn_die "--dir 必须是绝对路径"
    [[ "$OVPN_STATE_DIR" != / && "$OVPN_STATE_DIR" != /etc/openvpn ]] ||
        ovpn_die "拒绝使用过宽的管理目录：$OVPN_STATE_DIR"
}

ovpn_audit_command() {
    local rendered
    printf -v rendered '%q ' "$@"
    OVPN_AUDIT_EVENTS+=("\$ ${rendered% }")
}

ovpn_audit_file() { OVPN_AUDIT_FILES+=("$1  $2"); }

ovpn_print_audit() {
    local result="${1:-成功}"
    [[ "$OVPN_NO_AUDIT" == 1 ]] && return
    if (( ${#OVPN_AUDIT_EVENTS[@]} == 0 && ${#OVPN_AUDIT_FILES[@]} == 0 )); then
        printf '\n审计：无操作\n'
        return
    fi
    printf '\n执行审计：\n  结果：%s\n' "$result"
    [[ "$OVPN_DRY_RUN" != 1 ]] || printf '  模式：dry-run\n'
    local item
    for item in "${OVPN_AUDIT_EVENTS[@]}"; do printf '  %s\n' "$item"; done
    for item in "${OVPN_AUDIT_FILES[@]}"; do printf '  %s\n' "$item"; done
}

ovpn_confirm() {
    local expected="$1" prompt="$2" answer
    [[ -r /dev/tty ]] || ovpn_die "需要交互终端确认高风险操作"
    printf '%s\n' "$prompt" >&2
    read -r -p "请输入 $expected 确认：" answer </dev/tty
    [[ "$answer" == "$expected" ]] || ovpn_die "确认文字不匹配，操作已取消"
}

ovpn_lock() {
    local lock_dir="$OVPN_STATE_DIR/lock"
    install -d -o root -g root -m 0700 -- "$lock_dir"
    exec {OVPN_LOCK_FD}>"$lock_dir/ovpn.lock"
    flock -x "$OVPN_LOCK_FD"
}

ovpn_invoking_user() {
    local user="${SUDO_USER:-$(id -un)}"
    getent passwd "$user" >/dev/null || ovpn_die "系统用户不存在：$user"
    printf '%s\n' "$user"
}

ovpn_require_initialized() {
    [[ -s "$OVPN_STATE_DIR/pki/ca.crt" && -s "$OVPN_STATE_DIR/pki/ca-chain.crt" &&
        -s "$OVPN_STATE_DIR/pki/private/ca.key" && -f "$OVPN_STATE_DIR/pki/index.txt" &&
        -d "$OVPN_STATE_DIR/pki/issued" && -d "$OVPN_STATE_DIR/pki/reqs" ]] ||
        ovpn_die "OpenVPN 尚未初始化，请先运行 ovpn ca init"
}

ovpn_safe_regular_file() {
    [[ -f "$1" && ! -L "$1" ]] || ovpn_die "要求非符号链接普通文件：$1"
}

ovpn_edit() {
    local target="${1:-}" editor="${OVPN_EDITOR:-vi}" file template_name
    (( $# == 1 )) || ovpn_die "用法：ovpn edit env|server[:NAME]|client[:NAME]"
    case "$target" in
        env)
            file="$OVPN_RESOURCE_DIR/config/ovpn.env"
            ;;
        server|client)
            file="$OVPN_RESOURCE_DIR/config/$target/default.conf.tpl"
            ;;
        server:*|client:*)
            template_name="${target#*:}"
            ovpn_validate_name "$template_name" || ovpn_die "模板名称格式无效：$template_name"
            file="$OVPN_RESOURCE_DIR/config/${target%%:*}/$template_name.conf.tpl"
            ;;
        *)
            ovpn_die "edit 目标可用：env、server[:NAME]、client[:NAME]"
            ;;
    esac
    [[ "$editor" != *[[:space:]]* ]] || ovpn_die "OVPN_EDITOR 只接受单个编辑器命令，不支持参数：$editor"
    ovpn_have "$editor" || ovpn_die "编辑器不存在：$editor"
    ovpn_safe_regular_file "$file"
    ovpn_audit_command "$editor" "$file"
    ovpn_audit_file M "$file"
    [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; return; }
    "$editor" "$file"
    ovpn_print_audit
}

ovpn_atomic_install() {
    local source="$1" target="$2" mode="$3" owner="${4:-root}" group="${5:-root}"
    local target_dir temporary
    target_dir="$(dirname -- "$target")"
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || ovpn_die "输出目录不存在或不是安全目录：$target_dir"
    temporary="$(mktemp --tmpdir="$target_dir" .ovpn.XXXXXX)"
    ovpn_register_temp "$temporary"
    install -o "$owner" -g "$group" -m "$mode" -- "$source" "$temporary"
    mv -f -- "$temporary" "$target"
}

ovpn_template_replace() {
    local input="$1" output="$2"
    shift 2
    cp -- "$input" "$output"
    while (( $# > 0 )); do
        local token="$1" value="$2" escaped count
        shift 2
        count="$(ovpn_template_token_count "$output" "$token")"
        if (( count == 0 )) && [[ "${OVPN_WARN_UNUSED_TEMPLATE_VARS:-1}" == 1 ]]; then
            ovpn_warn "模板变量 {{$token}} 出现 0 次，本次值未被使用"
        elif (( count > 1 )); then
            ovpn_warn "模板变量 {{$token}} 出现 $count 次，将替换全部匹配位置"
        fi
        escaped="${value//\\/\\\\}"
        escaped="${escaped//&/\\&}"
        escaped="${escaped//|/\\|}"
        sed -i "s|{{$token}}|$escaped|g" "$output"
    done
    if grep -Eq '\{\{[A-Z0-9_]+\}\}' "$output"; then
        ovpn_die "模板包含未知或未替换占位符：$input"
    fi
}

ovpn_warn() { printf '警告：%s\n' "$*" >&2; }

ovpn_template_token_count() {
    local file="$1" token="{{$2}}"
    awk -v token="$token" '
        {
            text = $0
            while ((position = index(text, token)) != 0) {
                count++
                text = substr(text, position + length(token))
            }
        }
        END { print count + 0 }
    ' "$file"
}

ovpn_validate_env_assignment() {
    local assignment="$1" key value
    [[ "$assignment" == *=* ]] || ovpn_die "环境变量必须使用 KEY=VALUE 格式"
    key="${assignment%%=*}"
    value="${assignment#*=}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || ovpn_die "环境变量名格式无效：$key"
    case "$key" in
        CA_CERT|SERVER_CERT|SERVER_KEY|CRL_FILE|TLS_CRYPT_V2_SERVER_KEY|AUTH_VERIFY_SCRIPT|AUTH_DB|CA_INLINE|CLIENT_CERT_INLINE|CLIENT_KEY_INLINE|TLS_CRYPT_V2_CLIENT_INLINE|AUTH_USER_PASS|APPEND_CONFIG)
            ovpn_die "环境变量名由 ovpn 保留：$key"
            ;;
    esac
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || ovpn_die "环境变量值不能包含换行"
}

ovpn_render_append_config() {
    local template="$1" output="$2" configs_name="$3" context="$4" line count=0 replaced=0
    local -n configs_ref="$configs_name"
    count="$(grep -Fxc '{{APPEND_CONFIG}}' "$template" || true)"
    if (( count == 0 )) && [[ "${OVPN_WARN_UNUSED_TEMPLATE_VARS:-1}" == 1 ]]; then
        ovpn_warn "${context}模板变量 {{APPEND_CONFIG}} 出现 0 次，追加配置将写到文件末尾"
    elif (( count > 1 )); then
        ovpn_warn "${context}模板变量 {{APPEND_CONFIG}} 出现 $count 次，将在第一处插入配置并删除其余位置"
    fi
    : >"$output"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '{{APPEND_CONFIG}}' ]]; then
            if (( replaced == 0 )); then
                (( ${#configs_ref[@]} == 0 )) || printf '%s\n' "${configs_ref[@]}" >>"$output"
                replaced=1
            fi
        else
            printf '%s\n' "$line" >>"$output"
        fi
    done <"$template"
    if (( replaced == 0 && ${#configs_ref[@]} > 0 )); then
        printf '%s\n' "${configs_ref[@]}" >>"$output"
    fi
}

ovpn_load_env() {
    local file="$1" array_name="$2" line key value
    local -n env_ref="$array_name"
    ovpn_safe_regular_file "$file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        ovpn_validate_env_assignment "$line"
        key="${line%%=*}"
        value="${line#*=}"
        env_ref["$key"]="$value"
    done <"$file"
}

ovpn_apply_env() {
    local file="$1" array_name="$2" key value escaped count
    local -n env_ref="$array_name"
    for key in "${!env_ref[@]}"; do
        value="${env_ref[$key]}"
        count="$(ovpn_template_token_count "$file" "$key")"
        if (( count == 0 )) && [[ "${OVPN_WARN_UNUSED_TEMPLATE_VARS:-1}" == 1 ]]; then
            ovpn_warn "模板变量 {{$key}} 出现 0 次，本次值未被使用"
        elif (( count > 1 )); then
            ovpn_warn "模板变量 {{$key}} 出现 $count 次，将替换全部匹配位置"
        fi
        escaped="${value//\\/\\\\}"
        escaped="${escaped//&/\\&}"
        escaped="${escaped//|/\\|}"
        sed -i "s|{{$key}}|$escaped|g" "$file"
    done
}

ovpn_cleanup_backups() {
    local root="$1"
    [[ -d "$root" ]] || return 0
    find "$root" -mindepth 1 -maxdepth 1 -type d -mtime +60 -exec rm -rf -- {} +
    mapfile -t OVPN_OLD_BACKUPS < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | tail -n +51 | cut -d' ' -f2-)
    (( ${#OVPN_OLD_BACKUPS[@]} == 0 )) || rm -rf -- "${OVPN_OLD_BACKUPS[@]}"
}
