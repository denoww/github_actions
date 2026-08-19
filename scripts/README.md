# `scripts/` — os scripts que rodam como root nas EC2

Estes arquivos são executados **como root**, via SSM (`AWS-RunShellScript`), em toda EC2
com a tag `projetos` correspondente, a cada deploy dos repos `portaria`, `sc_linker`,
`scsip`, `socket-server-seucondominio` e `midia_indoor_player`.

Até 07/08/2026 eles **não existiam em repositório nenhum**: viviam só como gist público do
usuário `denoww` e eram consumidos por `curl -fsSL <gist>/raw | sudo -E bash`. Sem review,
sem histórico revisável, sem pinning — `/raw` serve **sempre a última revisão**, então
qualquer edição do gist era auto-confiada e executada no deploy seguinte, com root nas
quatro máquinas de produção. Contexto completo e plano de migração: **PSC-48** no repo
`seguranca_sc`.

| Arquivo | Gist de origem | Consumido por |
|---|---|---|
| `docker_exec_ecr.sh` | `denoww/4ed3acb2d942da7fc9c70adb5406c44d` | `12_prod_restart_server.yml` (5 repos) |
| `ligar_ec2_nos_loadbalancers.sh` | `denoww/5044b8da36f85afabb920263925684e9` | `13_prod_ligar_load_balance.yml` (5 repos) |

## Regra de ouro

**Nunca edite o gist direto.** O fluxo é:

1. Altere o arquivo **aqui**, em PR, com review.
2. Republique o gist a partir deste conteúdo (`gh gist edit <id> -f <arquivo> <caminho>`).
3. Pegue o SHA da revisão nova: `gh api gists/<id> --jq '.history[0].version'`.
4. **Bump o SHA pinado** nos workflows dos 5 repos consumidores.

O passo 4 é o que dá valor ao pinning: uma edição do gist não entra em produção sozinha —
alguém precisa abrir um PR mudando o SHA, e esse PR é revisável.

## Por que ainda passa por gist

O workflow reusável `rodar_comandos_em_todos_ec2_com_tag.yml` **não faz `actions/checkout`**
— ele só configura credenciais e chama `ssm send-command`. E `actions/checkout` no repo
chamador não alcança este repositório (o `GITHUB_TOKEN` do caller não lê outro repo
privado). Por isso o script precisa vir de uma URL que a própria EC2 consiga buscar.

Destino final desejado (não implementado ainda — ver PSC-48): **embutir o conteúdo do
script no próprio workflow reusável** e mandá-lo via SSM em base64, mecanismo que o
workflow já usa para o `remote_cmd`. Isso elimina o gist, a rede e a exposição pública de
uma vez — o script passa a viajar dentro do repositório privado que o GitHub já resolve.

## Verificando que a cópia bate com o que roda hoje

```bash
# corpo original (sem os cabeçalhos de proveniência que adicionamos aqui)
curl -s "https://gist.githubusercontent.com/denoww/4ed3acb2d942da7fc9c70adb5406c44d/raw/f5fd15fdb7c72115b621ed8d0f1672e2e92e6561/docker_exec_ecr.sh" | sha256sum
# esperado: 933ea499af56c6b61906c36f1a2e79502ae04cef3dd3bbed7b617acea4f8b051
```

## Diferenças já aplicadas nesta cópia (ainda NÃO publicadas no gist)

`docker_exec_ecr.sh` — o download do env do S3 era `... || true`, e a ausência de env
apenas logava "Seguindo sem `--env-file`". Em 07/08/2026 isso derrubou o `socket-server`
por ~10 min: a role da EC2 não tinha permissão de S3, o sync falhou, o script seguiu,
derrubou o container bom e subiu um sem env (crash loop com `EAI_AGAIN` em `redis`) — e o
job do GitHub Actions ficou **verde**. Agora aborta nos dois pontos, antes de encostar no
container que está rodando.

**Enquanto o gist não for republicado, essa correção não está em produção.**

## Dependabot × arquivos gerados — por que a PR dele nasce vermelha

`restart_server_no_ec2.yml` e `ligar_ec2_nos_loadbalancers.yml` são **gerados** por
`gerar_workflows.sh`. O dependabot não sabe disso: ao bumpar uma action de terceiro
(`actions/checkout`, `aws-actions/configure-aws-credentials`, …) ele edita o **artefato**,
e aí o `verifica_embed.py --check` acusa:

```
DERIVA em .github/workflows/restart_server_no_ec2.yml — regenere com: bash scripts/gerar_workflows.sh
```

Isso é o gate funcionando, não um defeito. Se a edição do dependabot fosse mergeada sozinha,
o próximo `gerar_workflows.sh` a reverteria em silêncio e a action voltaria à versão antiga.

**Como fechar uma PR do dependabot aqui:**

```bash
gh pr checkout <n>
# repetir o mesmo bump na FONTE
sed -i 's|<action>@v<antiga>|<action>@v<nova>|g' scripts/gerar_workflows.sh
bash scripts/gerar_workflows.sh
python3 scripts/verifica_embed.py --check   # tem que passar
git commit -am "chore(ci): bump tambem na fonte (gerar_workflows.sh)" && git push
```

⚠️ Bump de major na cadeia de credencial (`aws-actions/configure-aws-credentials` 4 → 6)
muda comportamento de autenticação e **não** é merge automático — leia o changelog. Esse
caminho roda como root nas EC2 de produção.

Feito em 2026-08-19 (PRs #8 e #9): `configure-aws-credentials` 4 → 6 e `actions/checkout`
4 → 7. O que foi conferido antes de mergear, porque *cada* major traz um breaking próprio:

| Major | Breaking | Por que não nos atinge |
|---|---|---|
| aws-creds v5 | muda tratamento de input booleano inválido | os 6 call-sites passam só 3 inputs string (key/secret/region) — zero booleano |
| aws-creds v6 | node24, exige runner ≥ v2.327.1 | todo job é `runs-on: ubuntu-latest` (hosted, sempre atual) |
| checkout v6 | credencial do git passa a ficar em arquivo separado | ninguém usa a credencial persistida — quem chama `gh` passa `GH_TOKEN:` explícito |
| checkout v7 | bloqueia checkout de PR de fork em `pull_request_target`/`workflow_run` | não existe nenhum desses dois triggers no repo |

Prova de que a fonte ficou coerente com o artefato: depois de bumpar o gerador, o regen deu
**diff zero** nos dois arquivos gerados — ou seja, o gerador voltou a produzir byte a byte
o que o dependabot tinha escrito à mão.

## Detector de pin desatualizado

`checar_pins_dos_consumidores.sh` compara o pin de cada consumidor com o **conteúdo** atual
do reusável (blob SHA), não com o SHA do commit — senão todo consumidor apareceria atrasado
a cada push aqui. Roda semanalmente via `.github/workflows/checar_pins_dos_consumidores.yml`
e abre/atualiza uma issue quando alguém fica para trás.

**Precisa do secret `PINS_READ_TOKEN`** (PAT com leitura dos 6 repos consumidores). O
`GITHUB_TOKEN` deste repositório não enxerga repositório privado alheio; sem o secret, o job
falha com `consumidores ilegiveis > 0` — de propósito, porque relatório verde com ponto cego
é pior que relatório nenhum.
