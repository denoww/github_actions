#!/usr/bin/env bash
# Gera os workflows reusáveis que embutem os scripts de deploy.
#
# POR QUE ISTO EXISTE
#   Os scripts precisam viajar até a EC2, e o workflow reusável NÃO consegue fazer
#   `actions/checkout` deste repositório: ele roda com o GITHUB_TOKEN do repo CHAMADOR,
#   que não lê um repo privado de terceiros. A saída é embutir o corpo do script no
#   próprio YAML — que o GitHub resolve sozinho a partir daqui.
#
#   Embutir à mão criaria deriva no dia seguinte (alguém edita o .sh e esquece o YAML,
#   ou vice-versa). Então o .sh é a fonte, o YAML é gerado, e o CI (`verifica_embed.yml`)
#   roda este script e falha se o resultado diferir do que está commitado.
#
# USO
#   bash scripts/gerar_workflows.sh          # regenera
#   bash scripts/gerar_workflows.sh --check  # só confere (usado no CI)
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

# Embute o script COMPRIMIDO em base64, não em texto puro.
#
# POR QUE COMPRIMIR — não é micro-otimização, é limite duro da plataforma:
# o GitHub Actions recusa o workflow com "Exceeded max expression length 21000"
# quando um bloco `run:` passa de 21.000 caracteres. O
# `ligar_ec2_nos_loadbalancers.sh` tem 21.314 bytes e estourava por 314. Medido
# em 07/08/2026 com um dispatch real, que falhou no parse antes de rodar.
#
# gzip+base64 leva os dois scripts para ~7-8 KB, com folga de ~3x. Também deixa de
# importar se `${{` aparecer no bash algum dia: dentro do base64 não há o que
# interpolar. O `.sh` continua legível no repo — é dele que o CI extrai a verdade.
#
# `-n` (sem nome/timestamp) é OBRIGATÓRIO: sem ele o gzip embute a hora e a saída
# muda a cada execução, e o `--check` do CI reprovaria sempre.
embutir() {
  local arquivo=$1
  gzip -9n -c "$arquivo" | base64 -w 100 | sed 's/^/          /'
}

gerar() {
  local nome=$1 script=$2 descricao=$3 inputs_yaml=$4 args_yaml_bruto=$5 env_yaml_bruto=${6:-} nlb_expr=${7:-\'\'}
  local destino=".github/workflows/${nome}.yml"

  # Tudo que entra no bloco `run:` do YAML precisa dos 10 espaços — inclusive os
  # terminadores de heredoc. O YAML remove essa indentação, e aí o `GA_SCRIPT_EOF`
  # cai na coluna 0 do shell, que é onde o bash espera encontrá-lo.
  local args_yaml env_yaml
  args_yaml=$(printf '%s\n' "$args_yaml_bruto" | sed 's/^/          /')
  env_yaml=$(printf '%s\n' "$env_yaml_bruto" | sed 's/^/          /')

  {
    cat <<YAML
# ⚠️ ARQUIVO GERADO — não edite à mão.
# Fonte: scripts/${script}
# Gerar: bash scripts/gerar_workflows.sh   (o CI confere via --check)
#
# ${descricao}
name: ${nome}

on:
  workflow_call:
    inputs:
      aws_region:
        type: string
        default: us-east-1
      ec2_com_tag:
        description: "Token a procurar dentro da tag 'projetos' (CSV-aware)"
        type: string
        required: true
      tag_key:
        type: string
        default: projetos
      max_attempts:
        type: number
        default: 60
      interval_secs:
        type: number
        default: 5
${inputs_yaml}
    secrets:
      AWS_ACCESS_KEY_ID:
        required: true
      AWS_SECRET_ACCESS_KEY:
        required: true

jobs:
  executar_no_ec2:
    runs-on: ubuntu-latest
    permissions:
      contents: read

    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6
        with:
          aws-access-key-id: \${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: \${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: \${{ inputs.aws_region }}

      - name: Descobrir instâncias alvo (tag CSV-aware)
        id: discover
        shell: bash
        env:
          AWS_REGION: \${{ inputs.aws_region }}
          TAG_KEY: \${{ inputs.tag_key }}
          PROJECT_TOKEN: \${{ inputs.ec2_com_tag }}
        run: |
          set -euo pipefail
          aws ec2 describe-instances \\
            --region "\$AWS_REGION" \\
            --filters Name=instance-state-name,Values=running Name=tag-key,Values="\$TAG_KEY" \\
            --query 'Reservations[].Instances[].[InstanceId,Tags]' \\
            --output json > instances.json

          ids=\$(jq -r --arg tok "\$PROJECT_TOKEN" --arg key "\$TAG_KEY" '
            .[]
            | {id: .[0], tags: (.[1] // [])}
            | (.tags[]? | select(.Key==\$key) | .Value // "" | gsub("\\\\s";"")) as \$val
            | select(\$val | test("(^|,)" + \$tok + "(,|\$)"))
            | .id
          ' instances.json | sort -u | tr '\\n' ' ')

          echo "Targets: \${ids:-<none>}"
          echo "instance_ids=\${ids}" >> "\$GITHUB_OUTPUT"

      - name: Escrever script e argumentos
        if: steps.discover.outputs.instance_ids != ''
        shell: bash
        env:
          GA_NLB_NAME: ${nlb_expr}
        run: |
          mkdir -p /tmp/ga
          # base64 do gzip do script — ver comentario em scripts/gerar_workflows.sh
          # sobre o teto de 21000 caracteres por bloco \`run:\` do GitHub Actions.
          cat > /tmp/ga/script.sh.gz.b64 <<'GA_SCRIPT_EOF'
YAML

    embutir "scripts/${script}"

    cat <<YAML
          GA_SCRIPT_EOF
          base64 -d /tmp/ga/script.sh.gz.b64 | gunzip > /tmp/ga/script.sh
          bash -n /tmp/ga/script.sh   # falha aqui e nao na EC2 se o embed corromper
          # Um argumento por linha — preserva espaços (ex: "npm run run_docker_image")
          # sem depender de quoting sobrevivendo até o SSM.
          cat > /tmp/ga/args <<'GA_ARGS_EOF'
${args_yaml}
          GA_ARGS_EOF
          # Variáveis de ambiente que o script lê (não são argumentos).
          # docker_exec_ecr.sh:64,243 lê LOG_DRIVER e exige AWSLOGS_GROUP quando
          # o driver é awslogs — sc_linker e scsip dependem disso.
          cat > /tmp/ga/env <<'GA_ENV_EOF'
${env_yaml}
          GA_ENV_EOF
          # \`--nlb-name\` só existe pro portaria. Passar a flag com valor vazio faria o
          # script tratar "" como nome de NLB; então a flag entra só quando ha valor.
          if [ -n "\${GA_NLB_NAME:-}" ]; then
            printf '%s\\n%s\\n' '--nlb-name' "\$GA_NLB_NAME" >> /tmp/ga/args
          fi

      - name: Executar via SSM
        if: steps.discover.outputs.instance_ids != ''
        shell: bash
        env:
          AWS_REGION:   \${{ inputs.aws_region }}
          INSTANCE_IDS: \${{ steps.discover.outputs.instance_ids }}
          MAX_ATTEMPTS: \${{ inputs.max_attempts }}
          INTERVAL:     \${{ inputs.interval_secs }}
        run: |
          set -euo pipefail
          : "\${MAX_ATTEMPTS:=60}"; : "\${INTERVAL:=5}"
          [[ "\$MAX_ATTEMPTS" =~ ^[0-9]+\$ ]] || MAX_ATTEMPTS=60
          [[ "\$INTERVAL" =~ ^[0-9]+\$ ]] || INTERVAL=5

          SCRIPT_B64="\$(base64 -w0 < /tmp/ga/script.sh)"
          ARGS_B64="\$(base64 -w0 < /tmp/ga/args)"
          ENV_B64="\$(base64 -w0 < /tmp/ga/env)"
          echo "Tamanho do payload: script=\${#SCRIPT_B64}B args=\${#ARGS_B64}B env=\${#ENV_B64}B (teto do SSM: 100KB)"

          FAIL=0
          for ID in \$INSTANCE_IDS; do
            echo "::group::Enviando comando para \$ID"

            C1="printf %s '\$SCRIPT_B64' > /tmp/ga_cmd.sh.b64; printf %s '\$ARGS_B64' > /tmp/ga_args.b64; printf %s '\$ENV_B64' > /tmp/ga_env.b64"
            # \`sudo -E env HOME=...\` é obrigatório: o script recupera o HOME real
            # sob sudo (docker_exec_ecr.sh:56-58). Rodar sem isso quebra o docker login.
            # \`set -a\` + source exporta o env antes do sudo; o \`-E\` carrega pra dentro.
            #
            # \`\${HOME:-/root}\` e NÃO \`\$HOME\`: o SSM executa sem HOME no ambiente, e
            # como esta linha roda sob \`set -u\`, \`\$HOME\` cru aborta com
            # "HOME: unbound variable" ANTES de qualquer passo do deploy. O caminho
            # antigo (\`curl | sudo -E env HOME="\$HOME" bash\`) não tinha \`set -u\`,
            # então expandia para vazio e seguia — foi o \`set -u\` novo que
            # transformou isso em falha. Medido em 2026-08-10 no canário do scsip
            # (run 31396334410) e provável causa real do ResponseCode=1 do canário
            # do midia, que na época foi atribuído por inferência à falta de ELB.
            C2='/bin/bash -lc '\\''set -euxo pipefail; LOG=/tmp/ga_cmd.out; \\
          base64 -d /tmp/ga_cmd.sh.b64 > /tmp/ga_cmd.sh; chmod +x /tmp/ga_cmd.sh; \\
          base64 -d /tmp/ga_args.b64 > /tmp/ga_args; mapfile -t GA_ARGS < /tmp/ga_args; \\
          base64 -d /tmp/ga_env.b64 > /tmp/ga_env; set -a; . /tmp/ga_env; set +a; \\
          sudo -E env HOME="\${HOME:-/root}" bash /tmp/ga_cmd.sh "\${GA_ARGS[@]}" > "\$LOG" 2>&1 || RC=\$? || true; RC=\${RC:-0}; \\
          echo "--- BEGIN REMOTE LOG ---"; tail -n 2000 "\$LOG" || true; echo "--- END REMOTE LOG ---"; \\
          echo EXIT_CODE=\$RC; exit \$RC'\\'''

            PARAMS_FILE="\$(mktemp)"
            jq -n --arg c1 "\$C1" --arg c2 "\$C2" '{commands: [\$c1, \$c2]}' > "\$PARAMS_FILE"

            COMMAND_ID=\$(aws ssm send-command \\
              --region "\$AWS_REGION" \\
              --document-name "AWS-RunShellScript" \\
              --comment "GitHub Actions ${nome}" \\
              --parameters "file://\$PARAMS_FILE" \\
              --instance-ids "\$ID" \\
              --query 'Command.CommandId' --output text)
            echo "CommandId: \$COMMAND_ID"

            attempt=0
            while (( attempt < MAX_ATTEMPTS )); do
              STATUS=\$(aws ssm get-command-invocation --region "\$AWS_REGION" \\
                --command-id "\$COMMAND_ID" --instance-id "\$ID" \\
                --query 'Status' --output text 2>/dev/null || echo "Pending")
              echo "[\$ID] Status: \$STATUS"
              case "\$STATUS" in Success|Cancelled|TimedOut|Failed) break ;; esac
              sleep "\$INTERVAL"; attempt=\$((attempt+1))
            done

            GCI=\$(aws ssm get-command-invocation --region "\$AWS_REGION" \\
              --command-id "\$COMMAND_ID" --instance-id "\$ID" --output json || true)
            FINAL_STATUS=\$(jq -r '.Status // "Unknown"' <<<"\$GCI")
            RESPONSE_CODE=\$(jq -r '.ResponseCode // empty' <<<"\$GCI")
            STDOUT=\$(jq -r '.StandardOutputContent // ""' <<<"\$GCI")
            STDERR=\$(jq -r '.StandardErrorContent  // ""' <<<"\$GCI")

            if [[ -z "\${RESPONSE_CODE}" || "\${RESPONSE_CODE}" == "null" ]]; then
              if [[ "\$FINAL_STATUS" == "Success" ]]; then RESPONSE_CODE=0; else RESPONSE_CODE=-1; fi
            fi

            echo "FinalStatus=\$FINAL_STATUS ResponseCode=\$RESPONSE_CODE"
            echo "--- STDOUT ---"; printf "%s\\n" "\$STDOUT"
            echo "--- STDERR ---"; printf "%s\\n" "\$STDERR"

            if [[ "\$FINAL_STATUS" != "Success" || "\$RESPONSE_CODE" != "0" ]]; then
              echo "::error title=SSM falhou para \$ID::Status=\$FINAL_STATUS ResponseCode=\$RESPONSE_CODE"
              FAIL=1
            fi
            echo "::endgroup::"
          done
          exit \$FAIL

      - name: Sem alvos compatíveis
        if: steps.discover.outputs.instance_ids == ''
        run: echo "Nenhuma instância com tag '\${{ inputs.tag_key }}' contendo '\${{ inputs.ec2_com_tag }}'."
YAML
  } > "${destino}.novo"

  if [[ $CHECK -eq 1 ]]; then
    if ! diff -q "$destino" "${destino}.novo" >/dev/null 2>&1; then
      echo "DERIVA em $destino — regenere com: bash scripts/gerar_workflows.sh" >&2
      diff -u "$destino" "${destino}.novo" | head -40 >&2
      rm -f "${destino}.novo"
      exit 1
    fi
    rm -f "${destino}.novo"
    echo "ok  $destino"
  else
    mv "${destino}.novo" "$destino"
    echo "gerado  $destino"
  fi
}

gerar "restart_server_no_ec2" "docker_exec_ecr.sh" \
  "Sobe o container a partir da imagem no ECR, com o env baixado do S3." \
"      ecr_repo:
        type: string
        required: true
      ports:
        type: string
        required: true
      docker_cmd:
        type: string
        required: true
      env_name:
        type: string
        default: production
      workdir:
        type: string
        default: /src
      container_name:
        type: string
        required: true
      s3_folder:
        type: string
        required: true
      log_driver:
        description: \"json-file (padrao) ou awslogs\"
        type: string
        default: ''
      awslogs_group:
        description: \"obrigatorio quando log_driver=awslogs\"
        type: string
        default: ''" \
'${{ inputs.ecr_repo }}
${{ inputs.ports }}
${{ inputs.docker_cmd }}
${{ inputs.env_name }}
${{ inputs.workdir }}
${{ inputs.container_name }}
${{ inputs.s3_folder }}' \
"LOG_DRIVER='\${{ inputs.log_driver }}'
AWSLOGS_GROUP='\${{ inputs.awslogs_group }}'"

gerar "ligar_ec2_nos_loadbalancers" "ligar_ec2_nos_loadbalancers.sh" \
  "Registra a EC2 nos target groups do ALB/NLB." \
"      alb_name:
        type: string
        required: true
      nlb_name:
        type: string
        default: ''
      ports:
        type: string
        required: true
      certificado_https_arn:
        type: string
        required: true" \
'--tags
projetos=${{ inputs.ec2_com_tag }}
--alb-name
${{ inputs.alb_name }}
--ports
${{ inputs.ports }}
--tcp-healthy-threshold
3
--tcp-unhealthy-threshold
3
--region
${{ inputs.aws_region }}
--certificado-https-arn
${{ inputs.certificado_https_arn }}' \
  "" \
  '${{ inputs.nlb_name }}'
