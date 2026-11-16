#!/usr/bin/env bash
# ============================================================
#  launch.sh — Lance tout "Cousin Debian Manager" en 1 commande
#  Version PORTABLE : fonctionne depuis n'importe quel dossier
#
#  Usage :
#    bash launch.sh             → lance depuis le dossier courant
#    bash launch.sh stop        → arrête le serveur
#
#  Le script s'auto-détecte : le projet = le dossier qui contient
#  ce launch.sh (après extraction de l'archive).
# ============================================================
set -Eeuo pipefail

# --- Couleurs
B='\033[1;34m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; N='\033[0m'
say()  { printf "${B}[*]${N} %s\n" "$1"; }
ok()   { printf "${G}[OK]${N} %s\n" "$1"; }
warn() { printf "${Y}[!]${N}  %s\n" "$1"; }
err()  { printf "${R}[X]${N} %s\n" "$1" >&2; }

# --- Détection automatique du dossier projet (= dossier de launch.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR"
cd "$PROJECT" || { err "Dossier projet introuvable : $PROJECT"; exit 1; }

PORT="${PORT:-3000}"
PID_FILE="$PROJECT/.run/dev.pid"
LOG_FILE="$PROJECT/dev.log"
DB_DIR="$PROJECT/db"
mkdir -p "$PROJECT/.run" "$DB_DIR"

# --- Mode stop
if [[ "${1:-}" == "stop" ]]; then
  say "Arrêt du serveur..."
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")" && ok "Serveur arrêté (PID $(cat "$PID_FILE"))"
  else
    warn "Aucun serveur en cours"
  fi
  pkill -f "next dev" 2>/dev/null || true
  exit 0
fi

# --- 1) Vérifier package.json
if [[ ! -f "$PROJECT/package.json" ]]; then
  err "package.json introuvable dans $PROJECT"
  err "→ Extrayez d'abord l'archive .tar.gz, puis lancez ce script depuis le dossier extrait."
  exit 1
fi

# --- 2) Vérifier les outils
say "Vérification des outils..."
if ! command -v bun >/dev/null 2>&1; then
  warn "bun absent — installation..."
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || true
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
command -v bun >/dev/null || { err "bun introuvable. Installez : curl -fsSL https://bun.sh/install | bash"; exit 1; }
if ! command -v node >/dev/null 2>&1; then
  warn "node absent — installation via bun..."
  bunx n --install lts >/dev/null 2>&1 || true
fi
command -v node >/dev/null 2>&1 || { err "node introuvable. Installez Node 20+."; exit 1; }
ok "bun + node présents"

# --- 3) Dépendances
if [[ ! -d "$PROJECT/node_modules" ]]; then
  say "Installation des dépendances (premier lancement, ~1 min)..."
  (cd "$PROJECT" && bun install)
fi
ok "Dépendances installées"

# --- 4) Base de données SQLite
say "Initialisation de la base SQLite..."
export DATABASE_URL="file:$DB_DIR/custom.db"
( cd "$PROJECT" && bun run db:push >/dev/null 2>&1 ) || \
  ( cd "$PROJECT" && bunx prisma db push --accept-data-loss >/dev/null 2>&1 )
( cd "$PROJECT" && bunx prisma generate >/dev/null 2>&1 ) || true
ok "Schéma Prisma synchronisé"

# --- 5) Seed (si la base est vide)
PKGS=$(cd "$PROJECT" && bunx prisma db execute --stdin <<<"SELECT COUNT(*) FROM Package;" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || echo "0")
if [[ "${PKGS:-0}" == "0" ]]; then
  say "Base vide : exécution du seed..."
  ( cd "$PROJECT" && bun run scripts/seed.ts >/dev/null 2>&1 ) || \
  ( cd "$PROJECT" && bun scripts/seed.ts >/dev/null 2>&1 )
  ok "21 paquets + dépôts + hommages chargés"
else
  ok "Base déjà peuplée ($PKGS paquets)"
fi

# --- 6) Tuer un éventuel ancien serveur
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  warn "Ancien serveur encore actif — arrêt..."
  kill "$(cat "$PID_FILE")" 2>/dev/null || true
  sleep 1
fi
pkill -f "next dev -p $PORT" 2>/dev/null || true
sleep 1

# --- 7) Lancer le serveur Next.js
say "Démarrage de Next.js sur le port $PORT..."
PORT="$PORT" DATABASE_URL="file:$DB_DIR/custom.db" \
  nohup bun run dev >"$LOG_FILE" 2>&1 &
DEV_PID=$!
echo "$DEV_PID" > "$PID_FILE"
ok "Serveur lancé (PID $DEV_PID) — log : $LOG_FILE"

# --- 8) Attendre que le serveur réponde
say "Attente de démarrage (max 30s)..."
for i in $(seq 1 30); do
  if curl -fsS "http://localhost:$PORT/" >/dev/null 2>&1; then
    ok "Serveur prêt en ${i}s"
    break
  fi
  sleep 1
  [[ $i -eq 30 ]] && { err "Le serveur ne répond pas après 30s"; tail -20 "$LOG_FILE"; exit 1; }
done

# --- 9) Récap
echo
echo -e "${G}============================================================${N}"
echo -e "${G}  🟢  COUSIN DEBIAN MANAGER EST EN LIGNE${N}"
echo -e "${G}============================================================${N}"
echo -e "   Dossier     : ${B}$PROJECT${N}"
echo -e "   URL locale  : ${B}http://localhost:${PORT}${N}"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -n "$IP" ]] && echo -e "   URL réseau  : ${B}http://${IP}:${PORT}${N}"
echo -e "   Log         : ${LOG_FILE}"
echo -e "   Arrêt       : ${Y}bash $PROJECT/launch.sh stop${N}"
echo
echo -e "   En hommage au créateur originel — Repose en paix."
echo

# --- 10) Suivre le log en direct (Ctrl+C = quitter l'affichage, le serveur reste vivant)
say "Affichage du log en direct (Ctrl+C pour quitter, le serveur reste actif)..."
tail -f "$LOG_FILE" 2>/dev/null || true
