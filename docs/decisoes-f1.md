# TokenBar — F1 · Decisões Técnicas

Data: 2026-09-02
Projeto: tokenbar (F1 — skeleton Claude Code local)
Spec de referência: `docs/specs/2026-09-02-design.md`

Registro das decisões técnicas tomadas durante a implementação da F1, no formato do `docs/decisoes/` do domhubs-devsquad (contexto → decisão → consequência).

---

## Decisão 1: Swift Testing via `run-tests.sh` (XCTest inexistente no CLT)

**Contexto:** O toolchain Command Line Tools (sem Xcode) não inclui os módulos XCTest nem Testing nos search paths padrão do `swiftc`. Pior: `swift test` puro neste toolchain pode sair 0 **sem executar nenhum teste** — falso verde.

**Decisão:** Usar Swift Testing (framework `Testing`, que vive em `<CLT>/Library/Developer/Frameworks`) via `./run-tests.sh`, que injeta os flags de compile (`-F`), link (`-F`) e runtime (`-rpath`) apontando para os caminhos do CLT. Proibido rodar `swift test` puro neste projeto.

**Consequência:** Verde só conta se vier do script (sem falso verde; `swift test` puro falha alto). CI/agentes devem usar `./run-tests.sh` como comando canônico de teste.

## Decisão 2: Semântica de timestamp do parser (ausente → mtime; inválido → descarta)

**Contexto:** Linhas de transcript podem vir sem `timestamp` ou com timestamp corrompido (linhas poison). A pergunta "quanto usei hoje" depende de atribuir cada evento a um dia.

**Decisão:** Timestamp ausente → usa o mtime do arquivo. Timestamp presente mas inválido → a linha é descartada (`nil`), nunca atribuída a "hoje" por fallback.

**Consequência:** Eventos corrompidos não poluem a contagem do dia (evita falso aumento de "hoje"); linhas válidas sem timestamp continuam contando via mtime.

## Decisão 3: `JSONFileOffsetStore` com `OSAllocatedUnfairLock`

**Contexto:** O store de cursores é tocado pelo loop do watcher e pelo ingest — código concorrente sob Swift 6 strict concurrency.

**Decisão:** `JSONFileOffsetStore` protege o dicionário de cursores com `OSAllocatedUnfairLock`; estado mutável não atravessa fronteiras de isolamento sem lock. Persistência em JSON (não em SQLite) — migração para SQLite fica pra F3.

**Consequência:** Compila limpo sob strict concurrency sem `@unchecked` indiscriminado; cursores sobrevivem a restart já na F1, sem pagar o custo do banco antes da hora.

## Decisão 4: Chave de cursor é sempre `FileIngestResult.path`

**Contexto:** O `FileManager.enumerator` retorna paths canônicos; montar o path na mão (concatenação de strings) produz chaves que não batem com as gravadas — cursor órfão e reingest duplicada.

**Decisão:** Lookup e gravação de cursores usam sempre `FileIngestResult.path` (o path canônico do enumerator), nunca path montado manualmente.

**Consequência:** Zero divergência de chave entre ingest e store; regra valendo também para o E2E (T5/SDD-4: o app e o selfcheck recebem o MESMO caminho de corpus, sem normalização na mão).

## Decisão 5: Tabela de siglas de display (multi-provider fica pra F5/F6)

**Contexto:** A string da menu bar precisa ser curta e distinguível por provider. F1 só tem Claude, mas o formato já precisa accomodar os próximos.

**Decisão:** Tabela de siglas: `{claude: C, codex: X, gemini: G, zai: Z, cursor: U, openrouter: O, copilot: P}`. Implementação multi-sigla (exibição de vários providers) fica pra F5/F6 — F1 renderiza só o Claude.

**Consequência:** Contrato de display congelado desde já (testes de UI dependem dele); adições futuras são insert na tabela, não redesign.

## Decisão 6: Truncamento com substituição (não soma)

**Contexto:** Editores e CLIs às vezes truncam/reescrevem o transcript: o arquivo encolhe (`size < offset` anterior). Somar o reingest sobre a soma antiga inflaria o total.

**Decisão:** Quando o arquivo encolhe, o ingester reinicia do offset 0 e sinaliza `resetToZero`; o ledger **substitui** (zera a contribuição daquele arquivo) antes de somar os eventos reingestados.

**Consequência:** Total correto após truncate/regenerate do transcript; coberto por regressão no Red Team (caso 2).

## Decisão 7: Fallback poll de 15 min além do FSEvents

**Contexto:** FSEvents pode falhar silenciosamente (edge cases de volume, sleep, rename de diretório) — sem rede de segurança, a UI congelaria com dado velho.

**Decisão:** Pipeline de atualização: ingest imediato no arranque → FSEvents → debounce 3 s; **fallback: poll de 900 s (15 min)** caso nenhum evento chegue no intervalo.

**Consequência:** Dado no pior caso 15 min velho, nunca infinito; custo de CPU do poll é desprezível nessa frequência.

## Decisão 8: Ordem subscribe-antes-de-start no watcher

**Contexto:** Se `start()` corre antes do registro do consumidor, os eventos iniciais (disparados pelo próprio scan inicial) se perdem.

**Decisão:** `TranscriptWatcher` exige registrar o consumidor **antes** de `start()` — a API induz a ordem correta em vez de documentá-la.

**Consequência:** Nenhum evento inicial perdido por condição de corrida de registro; ordem errada falha cedo e visível, não silenciosamente.

## Decisão 9: `genfixtures` — totais impressos excluem linhas poison

**Contexto:** O gerador de corpus sintético imprime totais esperados; linhas poison são, por definição, inválidas e não deveriam contar.

**Decisão:** Os totais impressos pelo `genfixtures` EXCLUEM linhas poison — acumulação só ocorre no branch de linha válida.

**Consequência:** O resumo do gerador é coerente com o parser (que descarta poison); por isso o E2E usa o selfcheck como verdade de referência, nunca o resumo do genfixtures com `--poison`.

## Decisão 10: Contrato de idempotência do selfcheck = 2 runs byte-idênticos

**Contexto:** Precisava-se provar que rodar o ingest duas vezes não dobra a contagem (idempotência do par cursor+ledger).

**Decisão:** Contrato verificado: 2 execuções do selfcheck produzem saída byte-idêntica. O store é em memória por processo, então `eventsApplied` repete entre processos — isso é esperado e não é violação.

**Consequência:** Teste de idempotência simples e determinístico; `eventsApplied` não serve como contador global entre processos (por design, até F3 persistir estado).

## Decisão 11: Gate de RAM = `phys_footprint` ≤ 40 MB (não rss do `ps`)

**Contexto:** O rss do `ps` inflou ~66 MB no macOS 26 porque inclui páginas de arquivo compartilhadas dos frameworks GUI (SwiftUI/AppKit) não atribuíveis ao app — o gate original "rss ≤ 40 MB" do spec seria inatingível e mediria o sistema, não o app.

**Decisão:** Métrica do gate: `phys_footprint` (via `vmmap --summary`), ≤ 40 MB — a mesma base da coluna "Memory" do Activity Monitor. Medido em F1: 14,8–15,5 MB. O rss continua logado, só que informativo.

**Consequência:** Gate estável entre versões de SO e verificável; spec §7 emendado para refletir a métrica correta (ver emenda neste commit).

## Decisão 12: Parser ISO8601 próprio (`fastISO8601`) no hot path

**Contexto:** `ISO8601DateFormatter` custou ~41 s para 100k+ linhas — inviável para o orçamento de ingest.

**Decisão:** Parser próprio (`fastISO8601`) no hot path: 100k+ linhas em ~8,5 s. Paridade com `ISO8601DateFormatter` testada (10k timestamps, 0 divergências onde o formato é válido).

**Consequência:** Ingest ~5× mais rápido sem sacrificar corretude; regressão de paridade no suite protege contra drift futuro.

## Decisão 13: Aritmética saturante + rejeição de usage > 10^15 por campo

**Contexto:** Red Team caso 1: transcript hostil com usage próximo de `Int64.max` crashava o app com SIGTRAP (overflow em soma).

**Decisão:** Parser rejeita campos `usage` > 10^15 (linha vira inválida); somas em `TokenSums` usam aritmética saturante (clampa em vez de overflow).

**Consequência:** Transcript malicioso/corrompido degrada para "linha ignorada", nunca crash; regressão no suite (caso 1).

## Decisão 14: Literais `Int` no macro `#expect` do Swift Testing

**Contexto:** O macro `#expect` do Swift Testing fixa a soma de literais como `Int`; comparar com `Optional<Int64>` gera erro de tipo confuso em tempo de compilação.

**Decisão:** Nos testes, o esperado é tipado como `Int64` ao ser comparado com somas `Optional<Int64>` do domínio.

**Consequência:** Testes compilam sem casts espalhados; padrão a seguir em todo teste novo de somas.

## Decisão 15: Spin ≤ 3 s no cancelamento durante `debouncer.wait()`

**Contexto:** `try?` no wait do debouncer engole `CancellationError`; ao cancelar o loop durante o wait, o spin continua até o debounce vencer (≤ 3 s).

**Decisão:** Aceito na F1 — janela curta, sem leak (o loop sai na próxima checagem de cancelamento). Revisar no scheduler da F2.

**Consequência:** Shutdown do app pode levar até 3 s extras em cenário raro; item registrado como dívida conhecida para o desenho do scheduler F2.

## Decisão 16: Heartbeat E2E (`TOKENBAR_E2E_DIR`) só por env, sem paths/conteúdo

**Contexto:** O E2E precisa observar o estado interno do app sem UI; qualquer canal que vaze paths ou conteúdo de transcript seria um furo de privacidade.

**Decisão:** O heartbeat só é ativado pela env `TOKENBAR_E2E_DIR` (instrumentação de teste) e escreve exclusivamente somas agregadas e a string de display — nunca paths nem conteúdo de arquivo.

**Consequência:** Binário de produção sem a env é idêntico ao comportamento normal (canal inerte); privacidade preservada mesmo com instrumentação embutida.

---

## Resumo para a F2

Dívidas conscientes aceitas na F1: spin de cancelamento no debouncer (D15, revisar no scheduler), store de cursores em JSON (D3, migrar para SQLite na F3), multi-sigla de display não implementada (D5, F5/F6).
