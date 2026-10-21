#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

# 1. Разбор аргумента --dry-run
DRY_RUN=""
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--dry-run" ]]; then
        DRY_RUN="--dry-run"
    else
        echo "Неизвестный аргумент: $1" >&2
        echo "Использование: $0 [--dry-run]" >&2
        exit 1
    fi
fi

# 2. Проверки по требованиям 4 и 5
# Требование 4: Наличие site/index.html
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo "Ошибка: обязательный файл '${LOCAL_DIR}index.html' отсутствует!" >&2
    exit 1
fi

# Требование 5: Проверка чистоты репозитория (не должно быть незафиксированных изменений)
if ! git -C "${REPO_ROOT}" diff --quiet || ! git -C "${REPO_ROOT}" diff --cached --quiet; then
    echo "Ошибка: в репозитории есть незафиксированные изменения! Зафиксируйте их перед деплоем." >&2
    exit 1
fi

# 3. Синхронизация каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR}
# Совместимость с macOS openrsync и GNU rsync
CHMOD_ARG="--chmod=D755,F644"
if rsync --version 2>&1 | grep -qi "openrsync"; then
    CHMOD_ARG="--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r"
fi

rsync -avz --delete "${CHMOD_ARG}" ${DRY_RUN} \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ -n "${DRY_RUN}" ]]; then
    echo "Пробный запуск (--dry-run) завершён успешно."
    exit 0
fi

# 5. Проверка доступности ${SITE_URL} и завершение с корректным кодом возврата
if ! curl -sf --cacert "${CA_CERT}" "${SITE_URL}" > /dev/null; then
    echo "Ошибка: ресурс ${SITE_URL} недоступен после деплоя!" >&2
    exit 1
fi

COMMIT_HASH="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
echo "Деплой успешно выполнен! Доставлен коммит: ${COMMIT_HASH}"
exit 0
