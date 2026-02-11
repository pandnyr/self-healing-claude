#!/usr/bin/env bash
# Self-Healing: Hata pattern analizi ve insight cikarma
# Manuel veya periyodik olarak calistirilir
# Gelistirmeler: cross-project learning, framework-aware insights, severity analizi

set -euo pipefail

DATA_DIR="$HOME/.claude/self-healing"
ERRORS_FILE="$DATA_DIR/errors.jsonl"
FIXES_FILE="$DATA_DIR/fixes.jsonl"
PATTERNS_FILE="$DATA_DIR/patterns.json"
CONTEXTS_DIR="$DATA_DIR/project-contexts"

if [ ! -f "$ERRORS_FILE" ]; then
  echo "Henuz hata kaydi yok: $ERRORS_FILE"
  exit 0
fi

TOTAL_ERRORS=$(wc -l < "$ERRORS_FILE" | tr -d ' ')
if [ "$TOTAL_ERRORS" -eq 0 ]; then
  echo "Henuz hata kaydi yok."
  exit 0
fi

echo "Analiz ediliyor: $TOTAL_ERRORS hata kaydi..."

# Gecici dosyalar
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# ============================================================
# HATA PATTERN'LERI CIKAR
# ============================================================

# Hata snippet'lerini normalize et ve grupla
jq -r '.error_snippet // empty' "$ERRORS_FILE" 2>/dev/null | \
  sed 's/[0-9]\{1,\}//g' | \
  sed "s/'[^']*'/'...'/g" | \
  sed 's/"[^"]*"/"..."/g' | \
  sort | uniq -c | sort -rn | head -20 > "$TEMP_DIR/snippet_counts.txt"

# Kategori bazli istatistik
jq -r '.error_category // "unknown"' "$ERRORS_FILE" 2>/dev/null | \
  sort | uniq -c | sort -rn > "$TEMP_DIR/category_counts.txt"

# Sub-kategori bazli istatistik
jq -r '[.error_category, .error_sub_category] | join("/")' "$ERRORS_FILE" 2>/dev/null | \
  sort | uniq -c | sort -rn > "$TEMP_DIR/subcategory_counts.txt"

# Framework bazli istatistik
jq -r '.framework // "unknown"' "$ERRORS_FILE" 2>/dev/null | \
  grep -v '^$' | sort | uniq -c | sort -rn > "$TEMP_DIR/framework_counts.txt"

# Severity bazli istatistik
jq -r '.severity // "unknown"' "$ERRORS_FILE" 2>/dev/null | \
  sort | uniq -c | sort -rn > "$TEMP_DIR/severity_counts.txt"

# Fix oranlarini hesapla
TOTAL_FIXED=$(jq -r 'select(.fixed == true)' "$ERRORS_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
GLOBAL_FIX_RATE=$(echo "scale=2; $TOTAL_FIXED / $TOTAL_ERRORS" | bc 2>/dev/null || echo "0")

# Proje bazli istatistik
jq -r '.project // "unknown"' "$ERRORS_FILE" 2>/dev/null | \
  sort | uniq -c | sort -rn > "$TEMP_DIR/project_counts.txt"

# Tool bazli istatistik
jq -r '.tool // "unknown"' "$ERRORS_FILE" 2>/dev/null | \
  sort | uniq -c | sort -rn > "$TEMP_DIR/tool_counts.txt"

# ============================================================
# PATTERN'LERI JSON'A DONUSTUR
# ============================================================

PATTERNS="[]"
while IFS= read -r line; do
  COUNT=$(echo "$line" | awk '{print $1}')
  SNIPPET=$(echo "$line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')

  [ -z "$SNIPPET" ] && continue
  [ "$COUNT" -lt 2 ] 2>/dev/null && continue

  # Bu pattern icin fix orani
  PATTERN_TOTAL=$(jq -r --arg snip "$SNIPPET" \
    'select(.error_snippet | contains($snip))' "$ERRORS_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null | head -1 || echo "$COUNT")
  PATTERN_FIXED=$(jq -r --arg snip "$SNIPPET" \
    'select(.error_snippet | contains($snip) and .fixed == true)' "$ERRORS_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null | head -1 || echo "0")

  FIX_RATE="0"
  if [ "$PATTERN_TOTAL" -gt 0 ] 2>/dev/null; then
    FIX_RATE=$(echo "scale=2; $PATTERN_FIXED / $PATTERN_TOTAL" | bc 2>/dev/null | head -1 || echo "0")
  fi

  # Etkilenen projeler
  AFFECTED=$(jq -r --arg snip "$SNIPPET" \
    'select(.error_snippet | contains($snip)) | .project' "$ERRORS_FILE" 2>/dev/null | \
    sort -u | head -5 | jq -R . | jq -s . 2>/dev/null || echo "[]")

  # En sik framework
  COMMON_FW=$(jq -r --arg snip "$SNIPPET" \
    'select(.error_snippet | contains($snip) and .framework != "" and .framework != null) | .framework' "$ERRORS_FILE" 2>/dev/null | \
    sort | uniq -c | sort -rn | head -1 | awk '{print $2}' || echo "")

  # En sik severity
  COMMON_SEV=$(jq -r --arg snip "$SNIPPET" \
    'select(.error_snippet | contains($snip)) | .severity' "$ERRORS_FILE" 2>/dev/null | \
    sort | uniq -c | sort -rn | head -1 | awk '{print $2}' || echo "medium")

  # En sik fix description
  COMMON_FIX=$(jq -r --arg snip "$SNIPPET" \
    'select(.error_snippet | contains($snip) and .fixed == true and .fix_description != null and .fix_description != "") | .fix_description' "$ERRORS_FILE" 2>/dev/null | \
    head -1 | head -c 200 || echo "")

  # Multi-solution: farkli cozumleri topla (fixes.jsonl'den)
  ALT_FIXES="[]"
  if [ -f "$FIXES_FILE" ]; then
    ALT_FIXES=$(jq -r --arg snip "$SNIPPET" \
      'select(.error_snippet != null and (.error_snippet | contains($snip)) and .fix_description != null and .fix_description != "" and .fix_description != "(aradaki islemler kaydedilmedi)") | .fix_description' \
      "$FIXES_FILE" 2>/dev/null | sort -u | head -5 | jq -R . | jq -s . 2>/dev/null || echo "[]")
  fi

  # Son gorunme
  LAST_SEEN=$(jq -r --arg snip "$SNIPPET" \
    'select(.error_snippet | contains($snip)) | .ts' "$ERRORS_FILE" 2>/dev/null | \
    tail -1 | cut -dT -f1 2>/dev/null || echo "unknown")

  PATTERN_OBJ=$(jq -n -c \
    --arg error_pattern "$SNIPPET" \
    --argjson frequency "$COUNT" \
    --argjson fix_rate "$FIX_RATE" \
    --argjson affected_projects "$AFFECTED" \
    --arg last_seen "$LAST_SEEN" \
    --arg framework "$COMMON_FW" \
    --arg severity "$COMMON_SEV" \
    --arg common_fix "$COMMON_FIX" \
    --argjson alternative_fixes "$ALT_FIXES" \
    '{
      error_pattern: $error_pattern,
      frequency: $frequency,
      fix_rate: $fix_rate,
      affected_projects: $affected_projects,
      last_seen: $last_seen,
      framework: $framework,
      severity: $severity,
      common_fix: $common_fix,
      alternative_fixes: $alternative_fixes
    }' 2>/dev/null)

  PATTERNS=$(echo "$PATTERNS" | jq --argjson obj "$PATTERN_OBJ" '. + [$obj]' 2>/dev/null || echo "$PATTERNS")
done < "$TEMP_DIR/snippet_counts.txt"

# ============================================================
# GLOBAL INSIGHT'LAR
# ============================================================

INSIGHTS="[]"

# En sik hata kategorisi
TOP_CAT=$(head -1 "$TEMP_DIR/category_counts.txt" | awk '{print $2}')
TOP_CAT_COUNT=$(head -1 "$TEMP_DIR/category_counts.txt" | awk '{print $1}')
if [ -n "$TOP_CAT" ]; then
  INSIGHTS=$(echo "$INSIGHTS" | jq --arg msg "En sik hata kategorisi: ${TOP_CAT} (${TOP_CAT_COUNT} kez)" '. + [$msg]')
fi

# Fix orani yorumu
if [ "$(echo "$GLOBAL_FIX_RATE > 0.7" | bc 2>/dev/null)" = "1" ]; then
  INSIGHTS=$(echo "$INSIGHTS" | jq --arg msg "Yuksek fix orani (%$(echo "scale=0; $GLOBAL_FIX_RATE * 100" | bc 2>/dev/null || echo "?")) - hatalar genellikle cozuluyor" '. + [$msg]')
elif [ "$(echo "$GLOBAL_FIX_RATE < 0.3" | bc 2>/dev/null)" = "1" ]; then
  INSIGHTS=$(echo "$INSIGHTS" | jq --arg msg "Dusuk fix orani (%$(echo "scale=0; $GLOBAL_FIX_RATE * 100" | bc 2>/dev/null || echo "?")) - cozulmemis hatalar birikmis olabilir" '. + [$msg]')
fi

# Severity dagilimi insight
CRITICAL_COUNT=$(grep -w 'critical' "$TEMP_DIR/severity_counts.txt" 2>/dev/null | awk '{print $1}' || echo "0")
HIGH_COUNT=$(grep -w 'high' "$TEMP_DIR/severity_counts.txt" 2>/dev/null | awk '{print $1}' || echo "0")
SEVERE_TOTAL=$((CRITICAL_COUNT + HIGH_COUNT))
if [ "$SEVERE_TOTAL" -gt 5 ] 2>/dev/null; then
  SEVERE_PCT=$(echo "scale=0; $SEVERE_TOTAL * 100 / $TOTAL_ERRORS" | bc 2>/dev/null || echo "?")
  INSIGHTS=$(echo "$INSIGHTS" | jq --arg msg "Kritik/yuksek hatalarin orani: %${SEVERE_PCT} (${SEVERE_TOTAL}/${TOTAL_ERRORS}) - oncelikli dikkat gerekiyor" '. + [$msg]')
fi

# Runtime hatalari icin ozel insight
RUNTIME_ACTUAL=$(grep -w 'runtime' "$TEMP_DIR/category_counts.txt" 2>/dev/null | awk '{print $1}' || echo "0")
if [ "$RUNTIME_ACTUAL" -gt 5 ] 2>/dev/null; then
  INSIGHTS=$(echo "$INSIGHTS" | jq '. + ["Runtime hatalari sik - optional chaining ve null check kullanilmali"]')
fi

# Type hatalari icin ozel insight
TYPE_ACTUAL=$(grep -w 'type' "$TEMP_DIR/category_counts.txt" 2>/dev/null | awk '{print $1}' || echo "0")
if [ "$TYPE_ACTUAL" -gt 5 ] 2>/dev/null; then
  INSIGHTS=$(echo "$INSIGHTS" | jq '. + ["TypeScript type hatalari sik - interface/type tanimlari kontrol edilmeli"]')
fi

# Sub-kategori bazli ozel insight'lar
NULL_REF=$(grep 'null_reference' "$TEMP_DIR/subcategory_counts.txt" 2>/dev/null | awk '{print $1}' || echo "0")
if [ "$NULL_REF" -gt 3 ] 2>/dev/null; then
  INSIGHTS=$(echo "$INSIGHTS" | jq '. + ["null_reference hatalari sik tekrarlaniyor - veri akasindan gelen degerlerde null check eksik"]')
fi

MODULE_NF=$(grep 'module_not_found' "$TEMP_DIR/subcategory_counts.txt" 2>/dev/null | awk '{print $1}' || echo "0")
if [ "$MODULE_NF" -gt 3 ] 2>/dev/null; then
  INSIGHTS=$(echo "$INSIGHTS" | jq '. + ["Module not found hatalari sik - import path ve paket bagimliliklari kontrol edilmeli"]')
fi

# ============================================================
# FRAMEWORK-SPESIFIK INSIGHT'LAR
# ============================================================

FW_INSIGHTS="[]"

while read -r fw_count fw_name; do
  [ -z "$fw_name" ] && continue
  [ "$fw_name" = "unknown" ] && continue
  [ -z "$fw_count" ] && continue
  [ "$fw_count" -lt 2 ] 2>/dev/null && continue

  # Framework icin fix oranini hesapla
  FW_TOTAL=$(jq -r --arg fw "$fw_name" 'select(.framework == $fw)' "$ERRORS_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "$fw_count")
  FW_FIXED=$(jq -r --arg fw "$fw_name" 'select(.framework == $fw and .fixed == true)' "$ERRORS_FILE" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
  FW_FIX_RATE=$(echo "scale=0; $FW_FIXED * 100 / $FW_TOTAL" | bc 2>/dev/null || echo "?")

  # Framework icin en sik sub_category
  FW_TOP_SUB=$(jq -r --arg fw "$fw_name" 'select(.framework == $fw) | .error_sub_category' "$ERRORS_FILE" 2>/dev/null | \
    grep -v '^$' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}' || echo "")

  # Framework-spesifik oneriler
  case "$fw_name" in
    nextjs)
      FW_INSIGHTS=$(echo "$FW_INSIGHTS" | jq --arg msg "Next.js: ${fw_count} hata (%${FW_FIX_RATE} fix) - SSR/RSC sinir kosullari ve API route hatalarina dikkat" '. + [$msg]') ;;
    react)
      FW_INSIGHTS=$(echo "$FW_INSIGHTS" | jq --arg msg "React: ${fw_count} hata (%${FW_FIX_RATE} fix) - state yonetimi ve hook kurallarini kontrol et" '. + [$msg]') ;;
    prisma)
      FW_INSIGHTS=$(echo "$FW_INSIGHTS" | jq --arg msg "Prisma: ${fw_count} hata (%${FW_FIX_RATE} fix) - schema sync ve migration durumunu kontrol et" '. + [$msg]') ;;
    jest|vitest)
      FW_INSIGHTS=$(echo "$FW_INSIGHTS" | jq --arg msg "${fw_name}: ${fw_count} test hatasi (%${FW_FIX_RATE} fix) - mock ve assertion hatalarini incele" '. + [$msg]') ;;
    docker)
      FW_INSIGHTS=$(echo "$FW_INSIGHTS" | jq --arg msg "Docker: ${fw_count} hata (%${FW_FIX_RATE} fix) - Dockerfile ve compose konfigurasyonunu kontrol et" '. + [$msg]') ;;
    python)
      FW_INSIGHTS=$(echo "$FW_INSIGHTS" | jq --arg msg "Python: ${fw_count} hata (%${FW_FIX_RATE} fix) - venv ve dependency cakismalarina dikkat" '. + [$msg]') ;;
    *)
      FW_INSIGHTS=$(echo "$FW_INSIGHTS" | jq --arg msg "${fw_name}: ${fw_count} hata (%${FW_FIX_RATE} fix)$([ -n "$FW_TOP_SUB" ] && echo " - en sik: ${FW_TOP_SUB}")" '. + [$msg]') ;;
  esac
done < "$TEMP_DIR/framework_counts.txt"

# ============================================================
# CROSS-PROJECT ANALIZ
# ============================================================

CROSS_INSIGHTS="[]"

if [ -d "$CONTEXTS_DIR" ]; then
  PROJECT_COUNT=$(find "$CONTEXTS_DIR" -name "*.jsonl" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

  if [ "$PROJECT_COUNT" -gt 1 ]; then
    # Tum projelerdeki ortak hata tipleri
    ALL_CATS=$(mktemp)
    for ctx_file in "$CONTEXTS_DIR"/*.jsonl; do
      jq -r '.error_category' "$ctx_file" 2>/dev/null >> "$ALL_CATS" || true
    done

    # En sik cross-project hata
    CROSS_TOP=$(sort "$ALL_CATS" | uniq -c | sort -rn | head -1 | awk '{print $2}')
    CROSS_TOP_COUNT=$(sort "$ALL_CATS" | uniq -c | sort -rn | head -1 | awk '{print $1}')

    if [ -n "$CROSS_TOP" ] && [ "$CROSS_TOP_COUNT" -gt 3 ] 2>/dev/null; then
      CROSS_INSIGHTS=$(echo "$CROSS_INSIGHTS" | jq --arg msg "${PROJECT_COUNT} projede ortak hata: ${CROSS_TOP} (${CROSS_TOP_COUNT} kez) - sistematik cozum gerekebilir" '. + [$msg]')
    fi

    # Proje saglik skorlari
    BEST_PROJECT=""
    BEST_SCORE=0
    WORST_PROJECT=""
    WORST_SCORE=100

    for ctx_file in "$CONTEXTS_DIR"/*.jsonl; do
      P_TOTAL=$(wc -l < "$ctx_file" | tr -d ' ')
      [ "$P_TOTAL" -lt 3 ] && continue

      P_FIXED=$(jq -r 'select(.fixed == true)' "$ctx_file" 2>/dev/null | jq -s 'length' 2>/dev/null || echo "0")
      P_SCORE=$(echo "scale=0; $P_FIXED * 100 / $P_TOTAL" | bc 2>/dev/null || echo "0")
      P_PROJECT=$(jq -r '.project' "$ctx_file" 2>/dev/null | head -1 || echo "unknown")

      if [ "$P_SCORE" -gt "$BEST_SCORE" ] 2>/dev/null; then
        BEST_SCORE=$P_SCORE
        BEST_PROJECT=$P_PROJECT
      fi
      if [ "$P_SCORE" -lt "$WORST_SCORE" ] 2>/dev/null; then
        WORST_SCORE=$P_SCORE
        WORST_PROJECT=$P_PROJECT
      fi
    done

    if [ -n "$BEST_PROJECT" ] && [ -n "$WORST_PROJECT" ] && [ "$BEST_PROJECT" != "$WORST_PROJECT" ]; then
      CROSS_INSIGHTS=$(echo "$CROSS_INSIGHTS" | jq --arg msg "En iyi fix orani: $(basename "$BEST_PROJECT") (%${BEST_SCORE}), En dusuk: $(basename "$WORST_PROJECT") (%${WORST_SCORE})" '. + [$msg]')
    fi

    rm -f "$ALL_CATS"
  fi
fi

# ============================================================
# SONUC JSON'U OLUSTUR
# ============================================================

RESULT=$(jq -n \
  --argjson patterns "$PATTERNS" \
  --argjson global_insights "$INSIGHTS" \
  --argjson framework_insights "$FW_INSIGHTS" \
  --argjson cross_project_insights "$CROSS_INSIGHTS" \
  --argjson total_errors "$TOTAL_ERRORS" \
  --argjson total_fixed "$TOTAL_FIXED" \
  --argjson global_fix_rate "$GLOBAL_FIX_RATE" \
  --arg analyzed_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    patterns: $patterns,
    global_insights: $global_insights,
    framework_insights: $framework_insights,
    cross_project_insights: $cross_project_insights,
    stats: {
      total_errors: $total_errors,
      total_fixed: $total_fixed,
      global_fix_rate: $global_fix_rate,
      analyzed_at: $analyzed_at
    }
  }')

echo "$RESULT" > "$PATTERNS_FILE"

echo ""
echo "Analiz tamamlandi:"
echo "  Toplam hata: $TOTAL_ERRORS"
echo "  Cozulen: $TOTAL_FIXED"
echo "  Fix orani: $(echo "scale=0; $GLOBAL_FIX_RATE * 100" | bc 2>/dev/null || echo "?")%"
echo "  Pattern sayisi: $(echo "$PATTERNS" | jq 'length' 2>/dev/null || echo "?")"
echo "  Framework insight: $(echo "$FW_INSIGHTS" | jq 'length' 2>/dev/null || echo "0")"
echo "  Cross-project insight: $(echo "$CROSS_INSIGHTS" | jq 'length' 2>/dev/null || echo "0")"
echo "  Sonuc: $PATTERNS_FILE"
