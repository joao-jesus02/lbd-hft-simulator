# HFT Simulator: Simulador de Order Book de Criptomoedas

## Membros do Projeto

Preencher:

| Nome | Curso | RGA | E-mail |
|---|---|---|---|
|Jefferson Eduardo Pessoa| Sistemas de Informação| 2021.1907.010-2 | jefferson.pessoa@ufms.br |
|João Pedro de Jesus Perin| Engenharia de software | 2023.1906.050-0 | joao_jesus@ufms.br |
|  |  |  |  |

## Justificativa e Contexto do Problema

Exchanges de criptomoedas precisam manter um Order Book consistente mesmo com muitas ordens chegando simultaneamente. O desafio central e controlar concorrencia, atomicidade e saldo dos usuarios. Uma ordem aberta nao pode permitir que o mesmo saldo seja usado novamente, por isso o projeto separa saldo disponivel e saldo bloqueado.

O sistema simula ordens de compra e venda para pares como `BTC/USDT`. Quando uma compra possui preco maior ou igual ao preco de uma venda, ocorre um match. Caso as quantidades sejam diferentes, a ordem pode ser parcialmente executada, mantendo o restante no book.

## Modelo ER

O modelo possui as entidades `users`, `assets`, `markets`, `wallets`, `orders`, `trades`, `order_audit_logs`, `wallet_movements` e `candles_1m`.

As principais decisoes de modelagem foram:

- Separar `assets` e `markets` para representar pares de negociacao como `BTC/USDT`.
- Criar uma carteira por usuario e ativo em `wallets`.
- Separar `available_balance` e `locked_balance` para impedir gasto duplicado.
- Registrar trades em tabela propria, pois uma ordem pode gerar varios trades.
- Registrar auditoria das ordens em `order_audit_logs`.
- Registrar movimentacoes financeiras em `wallet_movements`.
- Particionar candles por periodo em `candles_1m`.

O DER completo esta documentado em `docs/DER.md`.

## Regras de Negocio Implementadas

- Usuario possui carteiras por ativo.
- Ordem pertence a usuario e mercado.
- Ordem pode ser `open`, `partial`, `filled` ou `cancelled`.
- Compra bloqueia saldo do ativo de cotacao.
- Venda bloqueia saldo do ativo base.
- Matching respeita price-time priority.
- Matching usa `FOR UPDATE SKIP LOCKED`.
- Matching usa `pg_advisory_xact_lock` para serializar a liquidacao financeira e evitar deadlocks entre carteiras.
- Partial Fill e suportado.
- Trades sao imutaveis.
- Cancelamento libera saldo bloqueado restante.
- Auditoria registra criacao, execucao parcial, execucao total e cancelamento.

## Regras Nao Implementadas ou Simplificadas

- Taxas de negociacao foram previstas pelo tipo `fee`, mas nao aplicadas no matching.
- Nao ha autenticacao de usuarios.
- Nao ha interface grafica; a demonstracao e feita por SQL e pelo script Python.
- As particoes de candles foram criadas para junho e julho de 2026, podendo ser expandidas conforme o periodo da geracao.

## Principais Consultas, Funcoes e Gatilhos

- `match_order_after_insert`: trigger principal de matching.
- `rebuild_candles_1m`: reconstrucao dos candles OHLCV por minuto a partir dos trades.
- `get_best_orders`: consulta os melhores bids e asks.
- `cancel_order`: cancela ordem aberta ou parcial e libera saldo.
- `user_portfolio`: mostra saldos e valor estimado em USDT.
- `view_market_summary`: resumo de mercado com ultimo preco, variacao, volume e spread.
- `view_trades_history`: historico recente de trades.
- `view_traders_ranking`: ranking de traders por volume nas ultimas 24h.

## Screenshots das Saidas

As evidencias de execucao foram geradas em `docs/evidence`:

- `00_generator_result.png`: execucao do gerador, volume, trades, candles e tempo.
- `01_volume_summary.png`: tamanho do banco e totais principais.
- `02_market_summary.png`: saida de `view_market_summary`.
- `03_trades_history.png`: saida de `view_trades_history`.
- `04_traders_ranking.png`: saida de `view_traders_ranking`.
- `05_integrity_checks.png`: checks de saldos, quantidades e book cruzado.

O DER exportado do Astah esta em `docs/der/der_hft_simulator.jpeg`.

## Link github

 https://github.com/joao-jesus02/lbd-hft-simulator

## Conclusoes e Melhorias Sugeridas

A solucao resolve o problema principal do Order Book ao controlar saldos bloqueados, executar matches de forma atomica, registrar trades imutaveis e manter auditoria das mudancas de ordem. O uso de `FOR UPDATE SKIP LOCKED` permite concorrencia sem bloquear todo o book.

Melhorias futuras incluem interface web, suporte a taxas, criacao automatica de particoes, metricas de latencia e testes de carga com relatorios comparativos.
