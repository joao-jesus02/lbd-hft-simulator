# lbd-hft-simulator

Simulador de Order Book de criptomoedas usando PostgreSQL 15, PL/pgSQL e Python.

## Estrutura

```text
database/
  01_schema.sql
  02_matching_views.sql
  03_matching_tests.sql
  04_validation_queries.sql
  README_EXECUCAO.md
  generate_data.py
docs/
  DER.md
  CHECKLIST_CONFORMIDADE.md
  RELATORIO_TECNICO.md
requirements.txt
```

## Requisitos

- PostgreSQL 15+
- Python 3.10+
- Pacote Python `psycopg[binary]`

Instalacao da dependencia Python:

```bash
pip install -r requirements.txt
```

## Execucao do Banco

Crie o banco:

```bash
createdb hft
```

Execute os scripts:

```bash
psql -d hft -f database/01_schema.sql
psql -d hft -f database/02_matching_views.sql
psql -d hft -f database/03_matching_tests.sql
psql -d hft -f database/04_validation_queries.sql
```

## Geracao de Dados

O gerador usa processos paralelos e insercao em lote via `COPY`.

```bash
python database/generate_data.py --dsn "postgresql://postgres:postgres@localhost:5432/hft" --workers 4 --orders 200000 --batch-size 1000
```

Para atingir 700 MB a 1 GB, aumente `--orders` gradualmente e acompanhe o tamanho impresso no final da execucao.

## Principais Recursos

- Usuarios, ativos, mercados, carteiras, ordens, trades, auditoria e candles.
- Saldo disponivel e saldo bloqueado.
- Order Book com bids e asks.
- Trigger de matching com Partial Fill.
- `SELECT FOR UPDATE SKIP LOCKED`.
- Trades imutaveis.
- Candles OHLCV por minuto particionados, reconstruidos em lote a partir dos trades.
- Views de resumo de mercado, historico de trades e ranking de traders.
- Funcoes `get_best_orders`, `cancel_order` e `user_portfolio`.

## Entregaveis Manuais

Antes da entrega final:

- Exportar o DER do Astah em PNG ou PDF.
- Preencher os membros no relatorio tecnico.
- Inserir screenshots das consultas e da geracao de dados.
- Executar o gerador ate o banco atingir entre 700 MB e 1 GB.
- Subir todos os artefatos no Google Drive institucional.
- Atualizar este README com integrantes, RGAs e link do Drive.

## Integrantes e Link do Drive

Preencher antes da submissao:

```text
Integrante 1: João Pedro de jesus perin
RGA:2023.1906.050-0
E-mail: joao_jesus@ufms.br

Integrante 2:
RGA:
E-mail:

Link do Google Drive:
```
