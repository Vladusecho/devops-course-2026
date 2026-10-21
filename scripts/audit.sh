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
check "Служба Nginx активна" "active" "$(systemctl is-active nginx 2>/dev/null || true)"

if sudo nginx -t >/dev/null 2>&1; then
    NGINX_SYNTAX="ok"
else
    NGINX_SYNTAX="error"
fi
check "Конфигурация Nginx синтаксически корректна" "ok" "$NGINX_SYNTAX"

CERT_THRESHOLD="${CERT_THRESHOLD:-2592000}"
if openssl x509 -checkend "$CERT_THRESHOLD" -noout -in /etc/ssl/certs/devops.crt >/dev/null 2>&1; then
    CERT_VALID="valid"
else
    CERT_VALID="expired_or_expiring"
fi
check "Сертификат действует не менее 30 дней" "valid" "$CERT_VALID"

WORLD_WRITABLE="$(find /var/www/devops-site -perm -o+w 2>/dev/null | wc -l | tr -d ' ')"
KEY_PERMS="$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null || true)"
if [[ "$WORLD_WRITABLE" -eq 0 && "$KEY_PERMS" == "600" ]]; then
    SECURITY_CHECK="ok"
else
    SECURITY_CHECK="failed"
fi
check "Отсутствуют файлы с правом записи для всех и права ключа 600" "ok" "$SECURITY_CHECK"

echo "[5] Контейнеризация"
# а) служба docker активна
check "Служба Docker активна" "active" "$(systemctl is-active docker 2>/dev/null || true)"

# б) контейнер СУБД находится в состоянии healthy
DB_STATUS="$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || true)"
check "Контейнер СУБД в состоянии healthy" "healthy" "$DB_STATUS"

# в) порты 5000 и 5432 не прослушиваются ни на одном адресе, кроме 127.0.0.1
NON_LOCAL_PORTS="$(ss -tln 2>/dev/null | grep -E ':(5000|5432)\b' | grep -v '127.0.0.1:' | wc -l | tr -d ' ')"
[[ "$NON_LOCAL_PORTS" -eq 0 ]] && PORTS_SECURE="ok" || PORTS_SECURE="failed"
check "Порты 5000 и 5432 закрыты для внешних адресов" "ok" "$PORTS_SECURE"

# г) права файла ~/app/.env равны 600
ENV_FILE="/home/devops/app/.env"
[[ ! -f "$ENV_FILE" && -f "${HOME}/app/.env" ]] && ENV_FILE="${HOME}/app/.env"
ENV_PERMS="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"
check "Права файла .env равны 600" "600" "$ENV_PERMS"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
