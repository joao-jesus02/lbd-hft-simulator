# lbd-hft-simulator

Simulador de Order Book de criptomoedas usando PostgreSQL 15, PL/pgSQL e Python.

O projeto implementa cadastro de usuarios, carteiras com saldo disponivel e bloqueado, ordens de compra/venda, matching automatico com Partial Fill, trades imutaveis, auditoria, candles OHLCV por minuto, views e gerador concorrente de dados.

## Estrutura

```text
database/
  sql/
    00_reset_schema.sql
    00_run_all.sql
    01_schema.sql
    02_matching_views.sql
    03_matching_tests.sql
    04_validation_queries.sql
docs/
  DER.md
  CHECKLIST_CONFORMIDADE.md
  EXECUCAO.md
  der/
    der_hft_simulator.jpeg
    README_DER.md
  evidence/
    00_generator_result.png
    01_volume_summary.png
    02_market_summary.png
    03_trades_history.png
    04_traders_ranking.png
    05_integrity_checks.png
  report/
    RELATORIO_TECNICO.md
scripts/
  generate_data.py
docker-compose.yml
requirements.txt
```

## Requisitos

Opcao recomendada:

- Docker Desktop
- Python 3.10+

Opcao sem Docker:

- PostgreSQL 15+
- Cliente `psql`
- Python 3.10+

Instale as dependencias Python:

```bash
python -m pip install -r requirements.txt
```

## Execucao Rapida com Docker

Suba o PostgreSQL 15:

```bash
docker compose up -d
```

Copie os scripts para o container:

```bash
docker cp database/. lbd-hft-pg:/database
```

Execute a criacao do banco, funcoes, trigger, testes e validacoes:

```bash
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/sql/01_schema.sql
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/sql/02_matching_views.sql
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/sql/03_matching_tests.sql
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/sql/04_validation_queries.sql
```

Opcao equivalente para rodar tudo de uma vez:

```bash
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/sql/00_run_all.sql
```

Se precisar recomecar do zero no mesmo banco:

```bash
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/sql/00_reset_schema.sql
```

Depois execute novamente `00_run_all.sql` ou a sequencia de scripts.

DSN para conexao local ao banco do Docker:

```text
postgresql://postgres:postgres@localhost:55432/hft
```

## Execucao Sem Docker

Crie o banco local:

```bash
createdb hft
```

Execute os scripts:

```bash
psql -d hft -v ON_ERROR_STOP=1 -f database/sql/01_schema.sql
psql -d hft -v ON_ERROR_STOP=1 -f database/sql/02_matching_views.sql
psql -d hft -v ON_ERROR_STOP=1 -f database/sql/03_matching_tests.sql
psql -d hft -v ON_ERROR_STOP=1 -f database/sql/04_validation_queries.sql
```

Opcao equivalente para rodar tudo de uma vez:

```bash
psql -d hft -v ON_ERROR_STOP=1 -f database/sql/00_run_all.sql
```

Se precisar recomecar do zero:

```bash
psql -d hft -v ON_ERROR_STOP=1 -f database/sql/00_reset_schema.sql
```

DSN local comum:

```text
postgresql://postgres:postgres@localhost:5432/hft
```

## Scripts SQL

- `01_schema.sql`: cria schema, tipos, tabelas, PKs, FKs, CHECKs, particoes e indices.
- `02_matching_views.sql`: cria funcoes, trigger de matching, auditoria, imutabilidade de trades e views.
- `03_matching_tests.sql`: insere um teste pequeno de matching e Partial Fill.
- `04_validation_queries.sql`: executa consultas de demonstracao e checks de integridade.

Para carga grande, rode primeiro `01_schema.sql` e `02_matching_views.sql`, depois o gerador Python. O `03_matching_tests.sql` e opcional e serve para demonstracao curta.

## Geracao de Dados

O gerador usa processos paralelos e insercao em lote via `COPY`.

Com Docker:

```bash
python scripts/generate_data.py --dsn "postgresql://postgres:postgres@localhost:55432/hft" --workers 4 --orders 200000 --batch-size 1000
```

Sem Docker:

```bash
python scripts/generate_data.py --dsn "postgresql://postgres:postgres@localhost:5432/hft" --workers 4 --orders 200000 --batch-size 1000
```

Para atingir entre 700 MB e 1 GB, aumente `--orders` gradualmente. A execucao registrada para este trabalho atingiu:

```text
volume_total_orders = 440503
trades_generated = 324065
candles_rebuilt = 75
database_size = 703 MB
database_size_bytes = 737516903
```

As evidencias estao em `docs/evidence`.

## Validacao

Com Docker:

```bash
docker cp database/. lbd-hft-pg:/database
docker exec lbd-hft-pg psql -U postgres -d hft -v ON_ERROR_STOP=1 -f /database/sql/04_validation_queries.sql
```

Sem Docker:

```bash
psql -d hft -v ON_ERROR_STOP=1 -f database/sql/04_validation_queries.sql
```

Checks esperados:

```text
negative_wallets = 0
bad_order_quantities = 0
lock_mismatch = 0
crossed_books = 0
```

## DER e Evidencias

DER exportado do Astah:

```text
docs/der/der_hft_simulator.jpeg
```

Evidencias geradas:

```text
docs/evidence/00_generator_result.png
docs/evidence/01_volume_summary.png
docs/evidence/02_market_summary.png
docs/evidence/03_trades_history.png
docs/evidence/04_traders_ranking.png
docs/evidence/05_integrity_checks.png
```

## Principais Recursos

- Usuarios, ativos, mercados, carteiras, ordens, trades, auditoria e candles.
- Saldo disponivel e saldo bloqueado.
- Order Book com bids e asks.
- Trigger de matching com Partial Fill.
- `SELECT FOR UPDATE SKIP LOCKED`.
- `pg_advisory_xact_lock` para evitar deadlocks na liquidacao financeira.
- Trades imutaveis.
- Candles OHLCV por minuto particionados e reconstruidos em lote a partir dos trades.
- Views de resumo de mercado, historico de trades e ranking de traders.
- Funcoes `get_best_orders`, `cancel_order` e `user_portfolio`.

## Integrantes e Link do Drive

```text
Integrante 1: Joao Pedro de Jesus Perin
RGA: 2023.1906.050-0
E-mail: joao_jesus@ufms.br

Integrante 2:
RGA:
E-mail:

Link do Google Drive:
```
