"""Prova que o script embutido no YAML é byte-idêntico ao .sh do repo.

Existe para pegar um bug NO GERADOR — que passaria no `gerar_workflows.sh --check`,
porque lá os dois lados vêm do mesmo código. Aqui o caminho é o inverso: extrai do
YAML como o runner faria (base64 -d | gunzip) e compara com a fonte.
"""
import base64
import gzip
import hashlib
import sys

import yaml

PARES = [
    ('.github/workflows/restart_server_no_ec2.yml', 'scripts/docker_exec_ecr.sh'),
    ('.github/workflows/ligar_ec2_nos_loadbalancers.yml', 'scripts/ligar_ec2_nos_loadbalancers.sh'),
]

# Teto do GitHub Actions por bloco `run:`. Estourar isso derruba o workflow no PARSE,
# antes de rodar — e a mensagem ("Exceeded max expression length") não diz qual step.
LIMITE_EXPRESSAO = 21000

falhou = False
for wf, sh in PARES:
    doc = yaml.safe_load(open(wf))
    steps = list(doc['jobs'].values())[0]['steps']
    run = next(s['run'] for s in steps if 'Escrever script' in s.get('name', ''))

    linhas = run.split('\n')
    i = linhas.index("cat > /tmp/ga/script.sh.gz.b64 <<'GA_SCRIPT_EOF'")
    j = linhas.index('GA_SCRIPT_EOF')
    extraido = gzip.decompress(base64.b64decode(''.join(linhas[i + 1:j])))

    original = open(sh, 'rb').read()
    he = hashlib.sha256(extraido).hexdigest()[:16]
    ho = hashlib.sha256(original).hexdigest()[:16]

    ok_hash = he == ho
    maior = max(len(s['run']) for s in steps if 'run' in s)
    ok_tam = maior < LIMITE_EXPRESSAO
    falhou |= not (ok_hash and ok_tam)

    print(f"{'OK  ' if ok_hash else 'ERRO'} {sh}: extraido={he} original={ho}")
    print(f"{'OK  ' if ok_tam else 'ERRO'} {wf}: maior bloco run = {maior} (teto {LIMITE_EXPRESSAO})")

sys.exit(1 if falhou else 0)
