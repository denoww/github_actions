name: Reusable • EC2 fanout via SSM

on:
  workflow_call:
    inputs:
      aws_region:
        type: string
        default: us-east-1
      projeto_tag:
        description: "Token a procurar dentro da tag 'projetos' (CSV-aware)"
        type: string
        required: true
      tag_key:
        description: "Chave da tag usada no filtro"
        type: string
        default: projetos
      # Constrói o comando padrão (se remote_cmd não for fornecido)
      app_name:
        type: string
        default: portaria
      ports:
        type: string
        default: "3001,9000,9001,9005"
      npm_cmd:
        type: string
        default: "npm run run_docker_image"
      node_env:
        type: string
        default: production
      # Se quiser sobrescrever tudo, passe remote_cmd e ele será usado no lugar
      remote_cmd:
        description: "Comando shell completo a executar nas instâncias (sobrepõe app/ports/npm_cmd/node_env)"
        type: string
        default: ""
      max_attempts:
        description: "Tentativas para aguardar conclusão do SSM"
        type: number
        default: 60
      interval_secs:
        description: "Intervalo (s) entre tentativas"
        type: number
        default: 5
    secrets:
      AWS_ACCESS_KEY_ID:
        required: true
      AWS_SECRET_ACCESS_KEY:
        required: true

jobs:
  fanout:
    runs-on: ubuntu-latest
    permissions:
      contents: read

    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ inputs.aws_region }}

      - name: Descobrir instâncias alvo (tag CSV-aware)
        id: discover
        shell: bash
        env:
          AWS_REGION: ${{ inputs.aws_region }}
          TAG_KEY: ${{ inputs.tag_key }}
          PROJECT_TOKEN: ${{ inputs.projeto_tag }}
        run: |
          set -euo pipefail
          aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --filters Name=instance-state-name,Values=running Name=tag-key,Values="$TAG_KEY" \
            --query 'Reservations[].Instances[].[InstanceId,Tags]' \
            --output json > instances.json

          # Seleciona IDs cujo valor da tag contém o token como item de CSV (delimitado por vírgula)
          ids=$(jq -r --arg tok "$PROJECT_TOKEN" --arg key "$TAG_KEY" '
            .[] 
            | {id: .[0], tags: (.[1] // [])}
            | (.tags[]? | select(.Key==$key) | .Value // "" | gsub("\\s";"")) as $val
            | select($val | test("(^|,)" + $tok + "(,|$)"))
            | .id
          ' instances.json | sort -u | tr '\n' ' ')

          echo "Targets: ${ids:-<none>}"
          echo "instance_ids=${ids}" >> "$GITHUB_OUTPUT"

      - name: Montar comando remoto
        id: cmd
        shell: bash
        env:
          REMOTE_CMD_IN: ${{ inputs.remote_cmd }}
          APP_NAME:  ${{ inputs.app_name }}
          PORTS:     ${{ inputs.ports }}
          NPM_CMD:   ${{ inputs.npm_cmd }}
          NODE_ENV:  ${{ inputs.node_env }}
        run: |
          set -euo pipefail
          if [[ -n "${REMOTE_CMD_IN}" ]]; then
            CMD="${REMOTE_CMD_IN}"
          else
            # Comando padrão (se você não passar remote_cmd)
            CMD='curl -fsSL https://gist.githubusercontent.com/denoww/4ed3acb2d942da7fc9c70adb5406c44d/raw | sudo -E env HOME="$HOME" bash -s -- '"${APP_NAME}"' "'"${PORTS}"'" "'"${NPM_CMD}"'" '"${NODE_ENV}"
          fi
          echo "remote_cmd=$CMD" >> "$GITHUB_OUTPUT"
          printf 'Comando remoto:\n%s\n' "$CMD"

      - name: Executar via SSM
        if: steps.discover.outputs.instance_ids != ''
        shell: bash
        env:
          AWS_REGION:   ${{ inputs.aws_region }}
          INSTANCE_IDS: ${{ steps.discover.outputs.instance_ids }}
          REMOTE_CMD:   ${{ steps.cmd.outputs.remote_cmd }}
          MAX_ATTEMPTS: ${{ inputs.max_attempts }}
          INTERVAL:     ${{ inputs.interval_secs }}
        run: |
          set -euo pipefail
          for ID in $INSTANCE_IDS; do
            echo "::group::Enviando comando para $ID"
            COMMAND_ID=$(aws ssm send-command \
              --region "$AWS_REGION" \
              --document-name "AWS-RunShellScript" \
              --comment "GitHub Actions EC2 fanout" \
              --parameters commands=["$REMOTE_CMD"] \
              --instance-ids "$ID" \
              --query 'Command.CommandId' --output text)

            echo "CommandId: $COMMAND_ID"
            # esperar
            attempt=0
            while (( attempt < MAX_ATTEMPTS )); do
              STATUS=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$COMMAND_ID" \
                --instance-id "$ID" \
                --query 'Status' --output text || echo "Pending")
              echo "[$ID] Status: $STATUS"
              case "$STATUS" in
                Success|Cancelled|TimedOut|Failed) break ;;
              esac
              sleep "$INTERVAL"
              ((attempt++))
            done

            echo "--- Saída $ID ---"
            aws ssm get-command-invocation \
              --region "$AWS_REGION" \
              --command-id "$COMMAND_ID" \
              --instance-id "$ID" \
              --query '{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}' \
              --output text || true
            echo "::endgroup::"
          done

      - name: Sem alvos compatíveis
        if: steps.discover.outputs.instance_ids == ''
        run: echo "Nenhuma instância com tag '${{ inputs.tag_key }}' contendo '${{ inputs.projeto_tag }}'."
