#!/usr/bin/env bash
# Step 1 — environment check (OS/WSL, Docker, Compose, Go, git, jq, curl, disk, docker without sudo).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
start_log task1 00_check_env

step "Шаг 1. Проверка окружения"
run uname -a
grep -qi microsoft /proc/version && ok "WSL2: $(grep -oP 'microsoft[-a-zA-Z0-9.]*' /proc/version | head -1)" || info "native Linux"
. /etc/os-release && ok "ОС: $PRETTY_NAME"

if docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
  ok "Docker Engine $(docker version --format '{{.Server.Version}}') (без sudo — пользователь $(id -un))"
  docker info --format '{{.OperatingSystem}}' | grep -q 'Docker Desktop' && ok "Docker Desktop WSL-интеграция активна"
else
  fail "docker недоступен без sudo"
fi
docker compose version >/dev/null 2>&1 && ok "$(docker compose version)" || fail "docker compose v2 не найден"
command -v go >/dev/null && ok "$(go version)" || fail "go не найден"
for t in git jq curl xxd; do
  command -v "$t" >/dev/null && ok "$t: $($t --version 2>&1 | head -1)" || fail "$t не найден (sudo apt-get install -y $t)"
done
free_gb=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
(( free_gb > 15 )) && ok "Свободное место: ${free_gb} ГБ" || warn "Мало места: ${free_gb} ГБ"
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
ok "RAM, доступная WSL: ${mem_mb} МБ"
command -v openssl >/dev/null && ok "$(openssl version)" || fail "openssl не найден"
[[ "$ROOT" == /mnt/* ]] && warn "Репозиторий в /mnt/c — будет медленно" || ok "Репозиторий в Linux-ФС: $ROOT"
summary
