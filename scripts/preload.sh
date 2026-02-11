#!/usr/bin/env bash
# Self-Healing: Yaygin hata/cozum ciftlerini on yukle
# Ilk kullanimda sistemi hemen faydali hale getirmek icin
# 30 yaygin hata/cozum cifti yukler
# Idempotent: zaten yuklenmi ise tekrar yuklemez

set -euo pipefail

DATA_DIR="$HOME/.claude/self-healing"
ERRORS_FILE="$DATA_DIR/errors.jsonl"
FIXES_FILE="$DATA_DIR/fixes.jsonl"
MARKER="$DATA_DIR/.preload_done"
SCRIPTS_DIR="$HOME/.claude/skills/self-healing/scripts"

# Zaten yuklenmisse cik
if [ -f "$MARKER" ]; then
  echo "Onyukleme zaten yapilmis."
  exit 0
fi

# Dizinleri olustur
mkdir -p "$DATA_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Self-Healing onyukleme basliyor (30 hata/cozum cifti)..."

# Yardimci fonksiyon: Hata ve fix kaydini yaz
add_entry() {
  local error_snippet="$1"
  local error_category="$2"
  local error_sub_category="$3"
  local framework="$4"
  local severity="$5"
  local fix_description="$6"

  # errors.jsonl'e fixed:true olarak yaz
  local error_record
  error_record=$(jq -c -n \
    --arg ts "$TIMESTAMP" \
    --arg session "preloaded" \
    --arg project "global" \
    --arg project_hash "preloaded" \
    --arg tool "Bash" \
    --arg command "(preloaded)" \
    --argjson exit_code "1" \
    --arg error_snippet "$error_snippet" \
    --arg error_category "$error_category" \
    --arg error_sub_category "$error_sub_category" \
    --arg framework "$framework" \
    --arg severity "$severity" \
    --argjson context_files "[]" \
    --argjson stack_locations "[]" \
    --arg fix_description "$fix_description" \
    '{
      ts: $ts, session: $session, project: $project, project_hash: $project_hash,
      tool: $tool, command: $command, exit_code: $exit_code,
      error_snippet: $error_snippet, error_category: $error_category,
      error_sub_category: $error_sub_category, framework: $framework,
      severity: $severity, context_files: $context_files,
      stack_locations: $stack_locations,
      fixed: true, fix_command: "preloaded", fix_description: $fix_description
    }')
  echo "$error_record" >> "$ERRORS_FILE"

  # fixes.jsonl'e fix kaydini yaz
  local fix_record
  fix_record=$(jq -c -n \
    --arg ts "$TIMESTAMP" \
    --arg session "preloaded" \
    --arg project "global" \
    --arg project_hash "preloaded" \
    --arg command "(preloaded)" \
    --arg original_error_ts "$TIMESTAMP" \
    --arg error_category "$error_category" \
    --arg error_sub_category "$error_sub_category" \
    --arg framework "$framework" \
    --arg severity "$severity" \
    --arg error_snippet "$error_snippet" \
    --arg fix_description "$fix_description" \
    --argjson fix_files "[]" \
    '{
      ts: $ts, session: $session, project: $project, project_hash: $project_hash,
      command: $command, original_error_ts: $original_error_ts,
      error_category: $error_category, error_sub_category: $error_sub_category,
      framework: $framework, severity: $severity, error_snippet: $error_snippet,
      fix_description: $fix_description, fix_files: $fix_files,
      type: "preloaded"
    }')
  echo "$fix_record" >> "$FIXES_FILE"
}

# ============================================================
# JavaScript/TypeScript Runtime (6)
# ============================================================

# 1
add_entry \
  "Cannot read properties of undefined (reading 'map')" \
  "runtime" "null_reference" "react" "high" \
  "Optional chaining ekle: items?.map() veya varsayilan deger ver: (items || []).map()"

# 2
add_entry \
  "Cannot read properties of null" \
  "runtime" "null_reference" "" "high" \
  "Null check ekle: if (obj !== null) veya optional chaining: obj?.property"

# 3
add_entry \
  "X is not a function" \
  "runtime" "not_function" "" "high" \
  "Import'u kontrol et, dogru export/import kullanildigini dogrula, default vs named export"

# 4
add_entry \
  "Maximum call stack size exceeded" \
  "runtime" "stack_overflow" "" "high" \
  "Recursive fonksiyonda base case eksik veya useEffect'te sonsuz dongu, dependency array kontrol et"

# 5
add_entry \
  "X is not defined" \
  "runtime" "reference_error" "" "high" \
  "Degiskeni tanimla veya import et, scope kontrolu yap"

# 6
add_entry \
  "Assignment to constant variable" \
  "runtime" "type_error" "" "high" \
  "const yerine let kullan veya yeni degisken olustur"

# ============================================================
# TypeScript Type (5)
# ============================================================

# 7
add_entry \
  "TS2322: Type X is not assignable to type Y" \
  "type" "type_mismatch" "" "high" \
  "Interface/type tanimini guncelle veya type assertion (as Type) kullan"

# 8
add_entry \
  "TS2345: Argument of type X is not assignable to parameter of type Y" \
  "type" "argument_type" "" "high" \
  "Fonksiyon parametresinin tipini guncelle veya gonderilen degeri donustur"

# 9
add_entry \
  "TS2339: Property X does not exist on type Y" \
  "type" "property_missing" "" "high" \
  "Interface'e eksik property'yi ekle veya type guard kullan"

# 10
add_entry \
  "TS2531: Object is possibly null" \
  "type" "possibly_null" "" "high" \
  "Non-null assertion (!), optional chaining (?.) veya null check (if) ekle"

# 11
add_entry \
  "TS2307: Cannot find module X" \
  "type" "module_not_found" "" "medium" \
  "npm install eksik paket, @types/ paketini kur veya import path'i duzelt"

# ============================================================
# Module/Import (3)
# ============================================================

# 12
add_entry \
  "Module not found: Can't resolve X" \
  "module" "module_not_found" "webpack" "medium" \
  "npm install ile paketi kur, veya import yolunu duzelt (goreceli vs mutlak)"

# 13
add_entry \
  "ENOENT: no such file or directory" \
  "module" "file_not_found" "" "medium" \
  "Dosya yolunu kontrol et, buyuk/kucuk harf duyarliligi, dosyanin var oldugunu dogrula"

# 14
add_entry \
  "ERR_MODULE_NOT_FOUND" \
  "module" "module_not_found" "" "medium" \
  "Dosya uzantisini belirt (.js), package.json type:module ekle veya require/import uyumsuzlugunu gider"

# ============================================================
# React/Next.js (6)
# ============================================================

# 15
add_entry \
  "Hydration failed because the server rendered HTML didn't match the client" \
  "runtime" "null_reference" "nextjs" "high" \
  "suppressHydrationWarning ekle, dynamic import ile ssr:false kullan veya useEffect icinde client-only render yap"

# 16
add_entry \
  "useState/useEffect can only be called inside a function component" \
  "runtime" "not_function" "react" "high" \
  "Dosyanin basina 'use client' direktifi ekle (Next.js App Router)"

# 17
add_entry \
  "Each child in a list should have a unique key prop" \
  "runtime" "type_error" "react" "medium" \
  "map() icinde her elemana benzersiz key prop'u ekle: key={item.id}"

# 18
add_entry \
  "Too many re-renders. React limits the number of renders" \
  "runtime" "stack_overflow" "react" "high" \
  "onClick={fn()} yerine onClick={() => fn()} kullan, state guncellemesini useEffect'e tasi"

# 19
add_entry \
  "'use client' directive must be at the top of the file" \
  "syntax" "parse_error" "nextjs" "medium" \
  "'use client' satirini dosyanin en basina tasi, import'lardan once"

# 20
add_entry \
  "Error: Dynamic server usage" \
  "build" "compilation" "nextjs" "critical" \
  "export const dynamic = 'force-dynamic' ekle veya fetch'e cache: 'no-store' parametresi ver"

# ============================================================
# Build/Dependency (4)
# ============================================================

# 21
add_entry \
  "ERESOLVE unable to resolve dependency tree" \
  "dependency" "module_not_found" "" "medium" \
  "npm install --legacy-peer-deps kullan veya catisan dependency versiyonlarini guncelle"

# 22
add_entry \
  "Failed to compile" \
  "build" "compilation" "" "critical" \
  "Hata mesajindaki dosya ve satir numarasina git, syntax/type hatasini duzelt"

# 23
add_entry \
  "Missing script: X" \
  "build" "compilation" "" "medium" \
  "package.json'daki scripts bolumune eksik scripti ekle"

# 24
add_entry \
  "npm ERR! peer dep missing" \
  "dependency" "module_not_found" "" "medium" \
  "Eksik peer dependency'yi yukle: npm install X"

# ============================================================
# Test (3)
# ============================================================

# 25
add_entry \
  "Expected X to equal Y / toBe / toEqual" \
  "test" "assertion" "jest" "medium" \
  "Beklenen degeri guncelle veya test edilen fonksiyonun ciktisini duzelt"

# 26
add_entry \
  "Exceeded timeout of 5000 ms for a test" \
  "test" "timeout" "jest" "medium" \
  "jest.setTimeout(30000) veya test icinde done() callback'i cagirildigini kontrol et"

# 27
add_entry \
  "Cannot find module from test file" \
  "test" "test_failure" "jest" "medium" \
  "jest.config'de moduleNameMapper veya roots ayarini kontrol et, tsconfig paths eslesmesi"

# ============================================================
# Database (2)
# ============================================================

# 28
add_entry \
  "Unique constraint failed / duplicate key value" \
  "database" "constraint" "prisma" "critical" \
  "Kayit eklemeden once upsert kullan veya mevcut kaydi kontrol et"

# 29
add_entry \
  "ECONNREFUSED 127.0.0.1:5432" \
  "database" "connection" "" "critical" \
  "Veritabani servisinin calistigini kontrol et: docker compose up -d veya brew services start postgresql"

# ============================================================
# Git/Permission (1)
# ============================================================

# 30
add_entry \
  "Permission denied (publickey)" \
  "permission" "access" "git" "medium" \
  "SSH key'i kontrol et: ssh-add ~/.ssh/id_ed25519, veya HTTPS URL kullan"

# ============================================================
# SONUC
# ============================================================

ERRORS_COUNT=$(wc -l < "$ERRORS_FILE" | tr -d ' ')
FIXES_COUNT=$(wc -l < "$FIXES_FILE" | tr -d ' ')

echo "Yuklenen: ${ERRORS_COUNT} hata kaydi, ${FIXES_COUNT} fix kaydi"

# Pattern analizini tetikle
if [ -f "$SCRIPTS_DIR/analyze-patterns.sh" ]; then
  echo "Pattern analizi calistiriliyor..."
  bash "$SCRIPTS_DIR/analyze-patterns.sh" 2>/dev/null || true
fi

# Marker dosyasi olustur
echo "preloaded_at=$TIMESTAMP" > "$MARKER"
echo "entries=30" >> "$MARKER"

echo "Onyukleme tamamlandi."
