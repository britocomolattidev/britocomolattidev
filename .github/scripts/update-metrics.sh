#!/usr/bin/env bash
# Recalcula as métricas do perfil e reescreve o bloco entre os marcadores do README.
# Requer GH_TOKEN com acesso de leitura aos repositórios privados da organização.
set -euo pipefail
USER_LOGIN="${USER_LOGIN:-britocomolattidev}"
README="${README:-README.md}"
tmp=$(mktemp)

# gh com novas tentativas para falhas de rede passageiras
gh() { local n; for n in 1 2 3 4; do command gh "$@" && return 0; sleep $((n * 3)); done; return 1; }

gh api -X GET search/commits -f q="author:$USER_LOGIN" -f per_page=100 --paginate \
  --jq '.items[]|"\(.repository.full_name)\t\(.commit.author.date[:10])\t\(.sha)"' > "$tmp"

commits=$(wc -l < "$tmp" | tr -d ' ')
repos=$(cut -f1 "$tmp" | sort -u | wc -l | tr -d ' ')
active_days=$(cut -f2 "$tmp" | sort -u | wc -l | tr -d ' ')
peak=$(cut -f2 "$tmp" | sort | uniq -c | sort -rn | head -1)
peak_count=$(echo "$peak" | awk '{print $1}')
peak_day=$(echo "$peak" | awk '{split($2,d,"-"); print d[3]"/"d[2]"/"d[1]}')
first_day=$(cut -f2 "$tmp" | sort | head -1)
days_since=$(( ( $(date +%s) - $(date -d "$first_day" +%s) ) / 86400 + 1 ))

add=0; del=0; files=0
while IFS=$'\t' read -r repo _ sha; do
  read -r a d f < <(gh api "repos/$repo/commits/$sha" --jq '"\(.stats.additions) \(.stats.deletions) \(.files|length)"')
  add=$((add + a)); del=$((del + d)); files=$((files + f))
done < "$tmp"

prs=$(gh api -X GET search/issues -f q="author:$USER_LOGIN type:pr" --jq .total_count)
merged=$(gh api -X GET search/issues -f q="author:$USER_LOGIN type:pr is:merged" --jq .total_count)
reviews=$(gh api -X GET search/issues -f q="reviewed-by:$USER_LOGIN type:pr -author:$USER_LOGIN" --jq .total_count)
issues=$(gh api -X GET search/issues -f q="author:$USER_LOGIN type:issue" --jq .total_count)
orgs=$(gh api "user/orgs" --jq 'length' 2>/dev/null || echo 0)
langs=$(cut -f1 "$tmp" | sort -u | while read -r r; do gh api "repos/$r/languages" --jq 'keys[]'; done | sort -u | grep -v -E '^(Dockerfile|Makefile|Shell|HTML|CSS)$' | wc -l | tr -d ' ')

# separador de milhar no padrão pt-BR (163.352)
fmt() { echo "$1" | sed -E ':a;s/([0-9])([0-9]{3})($|\.)/\1.\2\3/;ta'; }
avg=$(awk -v c="$commits" -v d="$active_days" 'BEGIN{ if (d>0) printf "%.1f", c/d; else print 0 }' | tr . ,)
ratio=""
[ "$prs" -gt 0 ] && ratio=$(awk -v m="$merged" -v p="$prs" 'BEGIN{printf "%.0f%%", 100*m/p}')

{
  echo "<!--METRICS:START-->"
  echo "| Indicador | Valor |"
  echo "| :--- | ---: |"
  echo "| 🧱 **Commits** | **$(fmt "$commits")** |"
  echo "| 📦 **Repositórios com contribuição** | **$repos** |"
  echo "| ➕ **Linhas adicionadas** | **+$(fmt "$add")** |"
  echo "| ➖ **Linhas removidas** | **−$(fmt "$del")** |"
  echo "| 🗂️ **Arquivos alterados** | **$(fmt "$files")** |"
  echo "| 📅 **Dias ativos** | **$active_days de $days_since** |"
  echo "| ⚡ **Média de commits por dia ativo** | **$avg** |"
  echo "| 🔝 **Pico diário** | **$peak_count commits ($peak_day)** |"
  echo "| 🧬 **Linguagens nos projetos** | **$langs** |"
  [ "$orgs" -gt 0 ]    && echo "| 🏢 **Organizações** | **$orgs** |"
  [ "$prs" -gt 0 ]     && echo "| 🔀 **Pull Requests abertos** | **$(fmt "$prs")** |"
  [ "$merged" -gt 0 ]  && echo "| ✅ **Pull Requests mergeados** | **$(fmt "$merged") ($ratio)** |"
  [ "$reviews" -gt 0 ] && echo "| 👀 **Code reviews** | **$(fmt "$reviews")** |"
  [ "$issues" -gt 0 ]  && echo "| 🐞 **Issues abertas** | **$(fmt "$issues")** |"
  echo ""
  echo "<sub>Atualizado automaticamente em $(TZ=America/Sao_Paulo date '+%d/%m/%Y %H:%M') (BRT) · inclui repositórios privados da organização.</sub>"
  echo "<!--METRICS:END-->"
} > "$tmp.block"

awk -v block="$tmp.block" '
  /<!--METRICS:START-->/ { while ((getline line < block) > 0) print line; skip=1; next }
  /<!--METRICS:END-->/   { skip=0; next }
  !skip { print }
' "$README" > "$README.new" && mv "$README.new" "$README"
rm -f "$tmp" "$tmp.block"
