import yaml, hashlib, sys

PARES = [
    ('.github/workflows/restart_server_no_ec2.yml', 'scripts/docker_exec_ecr.sh'),
    ('.github/workflows/ligar_ec2_nos_loadbalancers.yml', 'scripts/ligar_ec2_nos_loadbalancers.sh'),
]

falhou = False
for wf, sh in PARES:
    d = yaml.safe_load(open(wf))
    steps = list(d['jobs'].values())[0]['steps']
    run = next(s['run'] for s in steps if 'Escrever script' in s.get('name', ''))

    # o YAML já removeu a indentação do bloco; pega entre os marcadores
    linhas = run.split('\n')
    i = linhas.index("cat > /tmp/ga/script.sh <<'GA_SCRIPT_EOF'")
    j = linhas.index('GA_SCRIPT_EOF')
    extraido = '\n'.join(linhas[i+1:j]) + '\n'

    original = open(sh).read()
    he = hashlib.sha256(extraido.encode()).hexdigest()[:16]
    ho = hashlib.sha256(original.encode()).hexdigest()[:16]
    ok = he == ho
    falhou |= not ok
    print(f"{'OK ' if ok else 'ERRO'}  {sh}  extraido={he} original={ho}")
    if not ok:
        eo, oo = extraido.split('\n'), original.split('\n')
        print(f"      linhas: extraido={len(eo)} original={len(oo)}")
        for n, (a, b) in enumerate(zip(eo, oo)):
            if a != b:
                print(f"      1a divergencia linha {n+1}:\n        yaml={a!r}\n        .sh ={b!r}")
                break

sys.exit(1 if falhou else 0)
