# github_actions

Workflows reutilizáveis para infraestrutura AWS.

## Workflows disponíveis

### `rodar_docker_compose_no_ec2.yml`
Executa `docker compose up` em instâncias EC2 filtradas por tag via SSM.

```yaml
jobs:
  deploy:
    uses: denoww/github_actions/.github/workflows/rodar_docker_compose_no_ec2.yml@main
    with:
      ec2_com_tag: meu-projeto   # tag 'projetos' na EC2
      workdir: /opt/meu-projeto  # pasta do docker-compose na EC2
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

| Input | Obrigatório | Default | Descrição |
|---|---|---|---|
| `ec2_com_tag` | sim | — | Valor na tag `projetos` da EC2 |
| `workdir` | sim | — | Diretório do docker-compose na EC2 |
| `compose_file` | não | `docker-compose.yml` | Nome do arquivo compose |
| `services` | não | `""` (todos) | Services específicos |
| `pull_before` | não | `true` | Faz pull antes do up |
| `aws_region` | não | `us-east-1` | Região AWS |

---

### `rodar_comandos_em_todos_ec2_com_tag.yml`
Executa qualquer comando shell em instâncias EC2 via SSM.

```yaml
jobs:
  run:
    uses: denoww/github_actions/.github/workflows/rodar_comandos_em_todos_ec2_com_tag.yml@main
    with:
      ec2_com_tag: meu-projeto
      remote_cmd: "echo hello"
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

---

### `build_docker_image_and_upload_to_ecr.yml`
Build de imagem Docker e push para o ECR.

```yaml
jobs:
  build:
    uses: denoww/github_actions/.github/workflows/build_docker_image_and_upload_to_ecr.yml@main
    with:
      ecr_repository: meu-repo
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

---

### `diego_build_docker_image_and_upload_to_ecr.yml`
Versão avançada do build ECR com cache remoto, env files do S3 e versionamento automático.
