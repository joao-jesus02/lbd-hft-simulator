# Checklist de Conformidade

## Requisitos do banco

- [x] PostgreSQL 15+.
- [x] Cadastro de usuarios.
- [x] Carteiras por usuario e ativo.
- [x] Saldo disponivel em `wallets.available_balance`.
- [x] Saldo bloqueado em `wallets.locked_balance`.
- [x] Order Book com ordens de compra e venda.
- [x] Status da ordem: `open`, `partial`, `filled`, `cancelled`.
- [x] Trades registrados em tabela separada.
- [x] Trades protegidos contra `UPDATE` e `DELETE`.
- [x] Candles OHLCV por minuto reconstruidos a partir dos trades.
- [x] Tabela `candles_1m` particionada por periodo.
- [x] Log de auditoria das ordens em `order_audit_logs`.

## Matching

- [x] Trigger executada apos inserir ordem.
- [x] Busca de contraparte por price-time priority.
- [x] Compra prioriza maior preco e timestamp mais antigo.
- [x] Venda prioriza menor preco e timestamp mais antigo.
- [x] Uso de `FOR UPDATE SKIP LOCKED`.
- [x] Uso de advisory lock transacional para evitar deadlocks na liquidacao financeira.
- [x] Suporte a Partial Fill.
- [x] Atualizacao atomica de ordens, trades e saldos.
- [x] Registro de auditoria a cada mudanca de estado.

## Funcoes exigidas

- [x] `get_best_orders`.
- [x] `cancel_order`.
- [x] `user_portfolio`.

## Views exigidas

- [x] `view_market_summary`.
- [x] `view_trades_history`.
- [x] `view_traders_ranking`.
- [x] Uso de window function em `view_traders_ranking`.

## Geracao de dados

- [x] Script em Python.
- [x] Pelo menos 4 processos paralelos por padrao.
- [x] Insercao em lote via `COPY`.
- [x] Sem `sleep()` ou `delay()`.
- [x] Precos com variacao realista por seno, drift e ruido.
- [x] Impressao de total de ordens, trades gerados, tamanho do banco e tempo.
- [x] Banco validado com 703 MB em ambiente de teste.

## Pendencias externas

- [ ] Exportar DER do Astah como PNG ou PDF.
- [ ] Inserir DER no relatorio tecnico.
- [ ] Preencher integrantes, RGA e e-mail no relatorio.
- [ ] Executar gerador ate atingir 700 MB a 1 GB.
- [ ] Registrar prints das consultas e aplicacao.
- [ ] Gravar apresentacao final de ate 15 minutos.
- [ ] Subir todos os artefatos ao Google Drive institucional.
- [ ] Colocar no README final o link do Google Drive.
