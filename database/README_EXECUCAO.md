# Execucao do Banco

Esta pasta contem os scripts SQL e o gerador de dados do HFT Simulator.

## Arquivos

```text
00_run_all.sql             executa os scripts principais via psql a partir da raiz do projeto
00_reset_schema.sql        remove o schema hft para permitir uma nova execucao do zero
01_schema.sql              cria schema, tipos, tabelas, PKs, FKs, CHECKs, particoes e indices
02_matching_views.sql      cria funcoes, trigger de matching, auditoria, imutabilidade e views
03_matching_tests.sql      insere dados pequenos para testar matching e Partial Fill
04_validation_queries.sql  consultas para demonstracao e validacao do projeto
generate_data.py           gerador concorrente de dados em Python
```

## Ordem Recomendada

Para demonstracao curta:

```bash
psql -d hft -v ON_ERROR_STOP=1 -f database/01_schema.sql
psql -d hft -v ON_ERROR_STOP=1 -f database/02_matching_views.sql
psql -d hft -v ON_ERROR_STOP=1 -f database/03_matching_tests.sql
psql -d hft -v ON_ERROR_STOP=1 -f database/04_validation_queries.sql
```

Ou, a partir da pasta `database`:

```bash
psql -d hft -v ON_ERROR_STOP=1 -f 00_run_all.sql
```

Para recomecar do zero:

```bash
psql -d hft -v ON_ERROR_STOP=1 -f database/00_reset_schema.sql
```

Para carga grande:

```bash
psql -d hft -v ON_ERROR_STOP=1 -f database/01_schema.sql
psql -d hft -v ON_ERROR_STOP=1 -f database/02_matching_views.sql
python database/generate_data.py --dsn "postgresql://postgres:postgres@localhost:5432/hft" --workers 4 --orders 200000 --batch-size 1000
psql -d hft -v ON_ERROR_STOP=1 -f database/04_validation_queries.sql
```

## Docker

Suba o banco a partir da raiz do projeto:

```bash
docker compose up -d
docker cp database/. lbd-hft-pg:/database
```

Execute os scripts dentro do container:

```bash
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/01_schema.sql
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/02_matching_views.sql
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/03_matching_tests.sql
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/04_validation_queries.sql
```

Ou rode tudo de uma vez:

```bash
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/00_run_all.sql
```

Para recomecar do zero no container:

```bash
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/00_reset_schema.sql
```

DSN do Docker:

```text
postgresql://postgres:postgres@localhost:55432/hft
```

## Gerador de Dados

Instale as dependencias a partir da raiz do projeto:

```bash
python -m pip install -r requirements.txt
```

Execute com pelo menos 4 processos:

```bash
python database/generate_data.py --dsn "postgresql://postgres:postgres@localhost:55432/hft" --workers 4 --orders 200000 --batch-size 1000
```

Para atingir entre 700 MB e 1 GB, aumente `--orders`, por exemplo:

```bash
python database/generate_data.py --dsn "postgresql://postgres:postgres@localhost:55432/hft" --workers 4 --orders 1000000 --batch-size 1000
```

O script imprime:

```text
volume_total_orders
trades_generated
candles_rebuilt
database_size
database_size_bytes
execution_time_seconds
```
