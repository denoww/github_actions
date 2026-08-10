#!/usr/bin/env bash
# Detector de pin desatualizado (PSC-48).
#
# Pinar os reusaveis por SHA resolve "commit entra em producao sem revisao", mas cria o
# problema simetrico: uma correcao publicada aqui NAO chega em quem nao bumpar, e ninguem
# e avisado. Foi o que aconteceu em 10/08 — o fix de `HOME: unbound variable` saiu, e o
# midia_indoor_player ficou no SHA quebrado ate alguem varrer os repos na mao.
#
# O dependabot NAO cobre este caso: o updater de github-actions bumpa a partir de
# tag/release do repo alvo, e este repo nao tem nenhuma. Sem tag, ele nao tem para onde
# mover. Por isso o detector e proprio.
#
# Uso:
#   bash scripts/checar_pins_dos_consumidores.sh           # relatorio
#   bash scripts/checar_pins_dos_consumidores.sh --check   # exit 1 se alguem estiver atras
#
# Requer: gh autenticado com leitura dos repos consumidores.

set -uo pipefail

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# repo:branch — quem consome os reusaveis deste repositorio
CONSUMIDORES=(
  "denoww/portaria:master"
  "denoww/sc_linker:master"
  "denoww/scsip:main"
  "denoww/socket-server-seucondominio:master"
  "denoww/midia_indoor_player:master"
  "denoww/seucondominio:master"
)

MAIN_SHA="$(gh api /repos/denoww/github_actions/commits/main --jq .sha)"
if [[ -z "$MAIN_SHA" ]]; then
  echo "ERRO: nao consegui ler o SHA de denoww/github_actions@main" >&2
  exit 2
fi
echo "denoww/github_actions@main = $MAIN_SHA"
echo

# Compara o CONTEUDO do reusavel, nao o SHA do commit.
#
# Comparar com o SHA do main marcaria todo consumidor como atrasado a cada commit neste
# repo, mesmo que o arquivo que ELE usa nao tenha mudado (foi o caso do ERP, pinado num
# SHA anterior onde o `diego_build_*` e byte a byte identico ao de hoje). Detector
# barulhento vira detector ignorado, entao a pergunta certa e "o arquivo que eu pinei e
# igual ao de agora?" — respondida pelo blob SHA que a API do GitHub ja devolve.
blob_sha() { # <arquivo> <ref>
  gh api "/repos/denoww/github_actions/contents/.github/workflows/$1?ref=$2" --jq .sha 2>/dev/null
}
declare -A BLOB_CACHE

ATRASADOS=0
MOVEIS=0
VISTOS=0
ILEGIVEIS=0

for entrada in "${CONSUMIDORES[@]}"; do
  repo="${entrada%%:*}"
  branch="${entrada##*:}"

  # lista os workflows do consumidor e procura referencias a este repo
  arquivos="$(gh api "/repos/$repo/contents/.github/workflows?ref=$branch" \
                --jq '.[].name' 2>/dev/null | grep -E '\.ya?ml$' || true)"
  if [[ -z "$arquivos" ]]; then
    echo "⚠️  $repo: nao consegui listar .github/workflows (branch $branch?)"
    ILEGIVEIS=$((ILEGIVEIS + 1))
    continue
  fi

  while IFS= read -r arq; do
    [[ -z "$arq" ]] && continue
    conteudo="$(gh api "/repos/$repo/contents/.github/workflows/$arq?ref=$branch" \
                  --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ -z "$conteudo" ]] && continue

    while IFS= read -r ref; do
      [[ -z "$ref" ]] && continue
      VISTOS=$((VISTOS + 1))
      reusavel="$(sed 's|.*/||; s|@.*||' <<<"$ref")"
      versao="${ref##*@}"

      if [[ ! "$versao" =~ ^[0-9a-f]{40}$ ]]; then
        echo "🔴 $repo/$arq → $reusavel@$versao  (REFERENCIA MOVEL — nao pinada)"
        MOVEIS=$((MOVEIS + 1))
        continue
      fi

      : "${BLOB_CACHE[$reusavel@main]:=$(blob_sha "$reusavel" "$MAIN_SHA")}"
      : "${BLOB_CACHE[$reusavel@$versao]:=$(blob_sha "$reusavel" "$versao")}"
      blob_main="${BLOB_CACHE[$reusavel@main]}"
      blob_pin="${BLOB_CACHE[$reusavel@$versao]}"

      if [[ -z "$blob_main" || -z "$blob_pin" ]]; then
        echo "⚠️  $repo/$arq → $reusavel@${versao:0:7}  (nao consegui comparar o conteudo)"
      elif [[ "$blob_pin" != "$blob_main" ]]; then
        echo "🟠 $repo/$arq → $reusavel@${versao:0:7}  (CONTEUDO ATRASADO; main=${MAIN_SHA:0:7})"
        ATRASADOS=$((ATRASADOS + 1))
      elif [[ "$versao" != "$MAIN_SHA" ]]; then
        echo "🟢 $repo/$arq → $reusavel@${versao:0:7}  (SHA antigo, conteudo identico ao main)"
      else
        echo "🟢 $repo/$arq → $reusavel@${versao:0:7}"
      fi
    done < <(grep -oE "uses: denoww/github_actions/\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml@[A-Za-z0-9_.-]+" <<<"$conteudo" || true)
  done <<<"$arquivos"
done

echo
echo "referencias verificadas: $VISTOS | moveis: $MOVEIS | atrasadas: $ATRASADOS | consumidores ilegiveis: $ILEGIVEIS"

# Controle anti-cegueira. Um consumidor que nao pode ser lido nao e "consumidor ok" — e
# um ponto cego, e um relatorio verde com pontos cegos e pior que nenhum relatorio.
#
# A primeira versao so falhava com VISTOS=0, e isso NAO bastava: na estreia em CI o token
# lia 1 dos 6 repos, entao VISTOS ficou 2 e a cegueira nos outros 5 passou como aviso
# cosmetico. Cegueira PARCIAL tambem falha.
if [[ "$ILEGIVEIS" -gt 0 ]]; then
  echo >&2
  echo "ERRO: $ILEGIVEIS consumidor(es) nao puderam ser lidos — o relatorio acima esta" >&2
  echo "      INCOMPLETO e nao prova que os demais estao pinados." >&2
  echo "      Causa usual: o GITHUB_TOKEN deste repo nao enxerga repositorio privado alheio." >&2
  echo "      Configure o secret PINS_READ_TOKEN com leitura dos repos consumidores." >&2
  exit 2
fi

if [[ "$VISTOS" -eq 0 ]]; then
  echo >&2
  echo "ERRO: nenhuma referencia encontrada em consumidor algum — a busca provavelmente" >&2
  echo "      esta cega (branch errada?). Nao trate isso como 'esta tudo ok'." >&2
  exit 2
fi

if [[ "$CHECK" -eq 1 && $((MOVEIS + ATRASADOS)) -gt 0 ]]; then
  echo
  echo "Para resolver: abra um PR em cada repo acima trocando o @<sha> por $MAIN_SHA."
  exit 1
fi
exit 0
