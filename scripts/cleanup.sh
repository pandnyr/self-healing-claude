#!/usr/bin/env bash
# Self-Healing: Veri temizleme ve istatistik
# Kullanim:
#   bash cleanup.sh           -> istatistik goster
#   bash cleanup.sh --old     -> 30 gunden eski cozulmus hatalari sil
#   bash cleanup.sh --reset   -> tum verileri sil (onay ister)

set -euo pipefail

DATA_DIR="$HOME/.claude/self-healing"
ERRORS_FILE="$DATA_DIR/errors.jsonl"
FIXES_FILE="$DATA_DIR/fixes.jsonl"
PATTERNS_FILE="$DATA_DIR/patterns.json"
CONTEXTS_DIR="$DATA_DIR/project-contexts"

ACTION="${1:-stats}"

# ============================================================
# ISTATISTIK
# ============================================================

show_stats() {
  echo "=== Self-Healing Istatistikleri ==="
  echo ""

  if [ ! -d "$DATA_DIR" ]; then
    echo "Veri dizini yok: $DATA_DIR"
    exit 0
  fi

  # errors.jsonl
  if [ -f "$ERRORS_FILE" ]; then
    TOTAL=$(wc -l < "$ERRORS_FILE" | tr -d ' ')
    FIXED=$(jq -r 'select(.fixed == true)' "$ERRORS_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
    UNFIXED=$((TOTAL - FIXED))
    SIZE=$(du -h "$ERRORS_FILE" | awk '{print $1}')
    echo "Hatalar (errors.jsonl):"
    echo "  Toplam: $TOTAL ($SIZE)"
    echo "  Cozulmus: $FIXED"
    echo "  Cozulmemis: $UNFIXED"

    # Kategori dagilimi
    echo "  Kategori dagilimi:"
    jq -r '.error_category' "$ERRORS_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | while read -r count cat; do
      echo "    - ${cat}: ${count}"
    done
  else
    echo "Hatalar: henuz kayit yok"
  fi
  echo ""

  # fixes.jsonl
  if [ -f "$FIXES_FILE" ]; then
    FIX_COUNT=$(wc -l < "$FIXES_FILE" | tr -d ' ')
    FIX_SIZE=$(du -h "$FIXES_FILE" | awk '{print $1}')
    echo "Fix'ler (fixes.jsonl): $FIX_COUNT kayit ($FIX_SIZE)"
  else
    echo "Fix'ler: henuz kayit yok"
  fi

  # patterns.json
  if [ -f "$PATTERNS_FILE" ]; then
    PAT_COUNT=$(jq '.patterns | length' "$PATTERNS_FILE" 2>/dev/null || echo "0")
    PAT_DATE=$(jq -r '.stats.analyzed_at // "?"' "$PATTERNS_FILE" 2>/dev/null)
    echo "Pattern'ler: $PAT_COUNT pattern (son analiz: $PAT_DATE)"
  else
    echo "Pattern'ler: henuz analiz yapilmamis"
  fi
  echo ""

  # Proje context'leri
  if [ -d "$CONTEXTS_DIR" ]; then
    CTX_COUNT=$(ls "$CONTEXTS_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    echo "Proje context'leri: $CTX_COUNT proje"
    if [ "$CTX_COUNT" -gt 0 ]; then
      for ctx_file in "$CONTEXTS_DIR"/*.jsonl; do
        P_TOTAL=$(wc -l < "$ctx_file" | tr -d ' ')
        P_PROJECT=$(jq -r '.project' "$ctx_file" 2>/dev/null | head -1 || echo "?")
        P_FIXED=$(jq -r 'select(.fixed == true)' "$ctx_file" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
        echo "  - $(basename "$P_PROJECT"): ${P_TOTAL} hata, ${P_FIXED} cozulmus"
      done
    fi
  fi
  echo ""

  # Disk kullanimi
  TOTAL_SIZE=$(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}' || echo "?")
  echo "Toplam disk kullanimi: $TOTAL_SIZE"
}

# ============================================================
# ESKI VERILERI TEMIZLE
# ============================================================

clean_old() {
  echo "30 gunden eski cozulmus hatalar temizleniyor..."

  if [ ! -f "$ERRORS_FILE" ]; then
    echo "Temizlenecek veri yok."
    exit 0
  fi

  NOW_EPOCH=$(date +%s)
  CUTOFF_EPOCH=$((NOW_EPOCH - 30 * 24 * 3600))

  BEFORE=$(wc -l < "$ERRORS_FILE" | tr -d ' ')

  # Eski cozulmus hatalari filtrele
  TEMP_FILE=$(mktemp)
  while IFS= read -r line; do
    TS=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)
    FIXED=$(echo "$line" | jq -r '.fixed // false' 2>/dev/null)

    KEEP=true
    if [ "$FIXED" = "true" ] && [ -n "$TS" ]; then
      if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s >/dev/null 2>&1; then
        ENTRY_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s)
      elif date -d "$TS" +%s >/dev/null 2>&1; then
        ENTRY_EPOCH=$(date -d "$TS" +%s)
      else
        ENTRY_EPOCH=0
      fi

      if [ "$ENTRY_EPOCH" -gt 0 ] && [ "$ENTRY_EPOCH" -lt "$CUTOFF_EPOCH" ]; then
        KEEP=false
      fi
    fi

    [ "$KEEP" = "true" ] && echo "$line"
  done < "$ERRORS_FILE" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$ERRORS_FILE"
  AFTER=$(wc -l < "$ERRORS_FILE" | tr -d ' ')
  REMOVED=$((BEFORE - AFTER))

  echo "Tamamlandi: $REMOVED eski kayit silindi ($BEFORE -> $AFTER)"

  # Proje context dosyalari icin de ayni islemi yap
  if [ -d "$CONTEXTS_DIR" ]; then
    for ctx_file in "$CONTEXTS_DIR"/*.jsonl; do
      [ ! -f "$ctx_file" ] && continue
      CTX_BEFORE=$(wc -l < "$ctx_file" | tr -d ' ')
      TEMP_CTX=$(mktemp)

      while IFS= read -r line; do
        TS=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)
        FIXED=$(echo "$line" | jq -r '.fixed // false' 2>/dev/null)

        KEEP=true
        if [ "$FIXED" = "true" ] && [ -n "$TS" ]; then
          if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s >/dev/null 2>&1; then
            ENTRY_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s)
          elif date -d "$TS" +%s >/dev/null 2>&1; then
            ENTRY_EPOCH=$(date -d "$TS" +%s)
          else
            ENTRY_EPOCH=0
          fi
          if [ "$ENTRY_EPOCH" -gt 0 ] && [ "$ENTRY_EPOCH" -lt "$CUTOFF_EPOCH" ]; then
            KEEP=false
          fi
        fi
        [ "$KEEP" = "true" ] && echo "$line"
      done < "$ctx_file" > "$TEMP_CTX"

      mv "$TEMP_CTX" "$ctx_file"
      CTX_AFTER=$(wc -l < "$ctx_file" | tr -d ' ')
      CTX_REMOVED=$((CTX_BEFORE - CTX_AFTER))
      [ "$CTX_REMOVED" -gt 0 ] && echo "  $(basename "$ctx_file"): $CTX_REMOVED kayit silindi"

      # Bos dosyalari sil
      [ "$CTX_AFTER" -eq 0 ] && rm -f "$ctx_file"
    done
  fi
}

# ============================================================
# FULL RESET
# ============================================================

full_reset() {
  echo "UYARI: Tum self-healing verileri silinecek!"
  echo "  - errors.jsonl"
  echo "  - fixes.jsonl"
  echo "  - patterns.json"
  echo "  - project-contexts/"
  echo "  - .last-error, .pending-ops"
  echo ""
  echo "Scriptler ve SKILL.md korunacak."
  echo ""

  read -r -p "Devam etmek istiyor musunuz? (evet/hayir): " CONFIRM
  if [ "$CONFIRM" = "evet" ]; then
    rm -f "$ERRORS_FILE" "$FIXES_FILE" "$PATTERNS_FILE"
    rm -f "$DATA_DIR/.last-error" "$DATA_DIR/.pending-ops"
    rm -f "$CONTEXTS_DIR"/*.jsonl 2>/dev/null || true
    echo "Tum veriler silindi. Self-healing sifirdan ogrenmeye baslayacak."
  else
    echo "Iptal edildi."
  fi
}

# ============================================================
# MAIN
# ============================================================

case "$ACTION" in
  stats|--stats|-s)
    show_stats
    ;;
  --old|old|-o)
    clean_old
    ;;
  --reset|reset|-r)
    full_reset
    ;;
  *)
    echo "Kullanim:"
    echo "  bash cleanup.sh           Istatistikleri goster"
    echo "  bash cleanup.sh --old     30 gunden eski cozulmus hatalari sil"
    echo "  bash cleanup.sh --reset   Tum verileri sil (onay ister)"
    ;;
esac
