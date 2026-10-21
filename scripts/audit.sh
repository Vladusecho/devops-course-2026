#!/usr/bin/env bash
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo " [OK] $desc"; ((PASS++))
    else
        echo " [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | grep -i '^permitrootlogin' | awk '{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | grep -i '^passwordauthentication' | awk '{print $2}')"

# TODO 1: проверьте, что значение параметра port отлично от 22
ACTUAL_PORT="$(sudo sshd -T | grep -i '^port' | awk '{print $2}')"
[[ "$ACTUAL_PORT" != "22" && -n "$ACTUAL_PORT" ]] && PORT_CHECK="true" || PORT_CHECK="false"
check "Порт службы SSH отличен от 22" "true" "$PORT_CHECK"

# TODO 2: проверьте, что значение параметра maxauthtries равно 3
check "Лимит попыток аутентификации равен 3" "3" "$(sudo sshd -T | grep -i '^maxauthtries' | awk '{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"

# TODO 3: проверьте, что политика по умолчанию для входящего трафика равна deny
DEFAULT_INCOMING="$(sudo ufw status verbose | awk '/^Default:/{print $2}')"
check "Политика по умолчанию для входящего трафика равна deny" "deny" "$DEFAULT_INCOMING"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf " %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
# а) служба nginx активна
check "Служба Nginx активна" "active" "$(systemctl is-active nginx 2>/dev/null || true)"

# б) конфигурация nginx синтаксически корректна
if sudo nginx -t >/dev/null 2>&1; then
    NGINX_SYNTAX="ok"
else
    NGINX_SYNTAX="error"
fi
check "Конфигурация Nginx синтаксически корректна" "ok" "$NGINX_SYNTAX"

# в) сертификат истекает не ранее чем через 30 дней (2592000 сек)
CERT_THRESHOLD="${CERT_THRESHOLD:-2592000}"
if openssl x509 -checkend "$CERT_THRESHOLD" -noout -in /etc/ssl/certs/devops.crt >/dev/null 2>&1; then
    CERT_VALID="valid"
else
    CERT_VALID="expired_or_expiring"
fi
check "Сертификат действует не менее 30 дней" "valid" "$CERT_VALID"

# г) в каталоге ресурса нет файлов o+w и права ключа равны 600
WORLD_WRITABLE="$(find /var/www/devops-site -perm -o+w 2>/dev/null | wc -l | tr -d ' ')"
KEY_PERMS="$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null || true)"
if [[ "$WORLD_WRITABLE" -eq 0 && "$KEY_PERMS" == "600" ]]; then
    SECURITY_CHECK="ok"
else
    SECURITY_CHECK="failed"
fi
check "Отсутствуют файлы с правом записи для всех и права ключа 600" "ok" "$SECURITY_CHECK"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
