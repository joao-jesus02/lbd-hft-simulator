# HFT Simulator - Execucao

Arquivos desta etapa:

- `02_matching_views.sql`: trigger de matching, partial fill, auditoria, imutabilidade de trades e views.
- `03_matching_tests.sql`: testes SQL de matching, partial fill, saldos, auditoria e views.
- `generate_data.py`: gerador concorrente de ordens em Python.

Ordem sugerida:

```bash
psql -d hft -f 01_schema.sql
psql -d hft -f 02_matching_views.sql
psql -d hft -f 03_matching_tests.sql
```

Gerador:

```bash
pip install "psycopg[binary]"
python generate_data.py --dsn "postgresql://postgres:postgres@localhost:5432/hft" --workers 4 --orders 200000 --batch-size 1000
```

Para chegar entre 700 MB e 1 GB, aumente `--orders`. O valor exato depende de indices, quantidade de trades gerados e configuracao do PostgreSQL.

