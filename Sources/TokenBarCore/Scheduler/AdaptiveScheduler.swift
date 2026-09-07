import Foundation

/// Scheduler adaptativo de refresh por provider — spec §7.
///
/// Um loop por provider: dorme o intervalo vigente (com jitter ±10%) no clock
/// injetado e dispara `onFire`. Single-flight: nunca há dois fires simultâneos
/// do mesmo provider — enquanto um fire está em curso, o próximo fica na fila
/// para o tick seguinte. O fire roda em task desacoplada do loop, então
/// cancelar/reiniciar o loop (menu, sleep/wake) nunca cancela um fetch em curso.
///
/// Intervalos (spec §7, todos com jitter ±10%):
/// - ocioso: 5 min
/// - menu aberto (`noteMenuOpened`): 60 s — decai de volta p/ ocioso no
///   primeiro `noteResult(ok: true)` com pressão baixa (o wiring reafirma
///   `noteMenuOpened` a cada ciclo enquanto o menu seguir aberto)
/// - pressão ≥ 0,8 (`noteResult`): 30 s (vence o menu)
/// - erro (`noteResult(ok: false)`): backoff ×2 do intervalo atual, teto 30 min
/// - sucesso: recalcula a partir do estado (pressão/ocioso) — zera o backoff
///
/// `noteMenuOpened` e `resumeFromSleep` reiniciam os loops para o novo
/// intervalo valer de imediato (o resume, além disso, dispara refresh
/// imediato de todos os providers).
public actor AdaptiveScheduler {
    public typealias FireHandler = @Sendable () async -> Void

    /// Ocioso (rede), spec §7.
    public static let idleInterval = Duration.seconds(300)
    /// Menu do painel aberto.
    public static let menuInterval = Duration.seconds(60)
    /// Pressão ≥ 0,8 do limite.
    public static let pressureInterval = Duration.seconds(30)
    /// Teto do backoff.
    public static let backoffCeiling = Duration.seconds(1800)

    private struct ProviderState {
        var onFire: FireHandler
        var interval: Duration = AdaptiveScheduler.idleInterval
        var immediate = false
        var task: Task<Void, Never>?
    }

    private let clock: any Clock<Duration>
    private let jitterFraction: Double
    private let random: @Sendable () -> Double

    private var providers: [ProviderID: ProviderState] = [:]
    private var paused = false
    private var firing: Set<ProviderID> = []

    /// - Parameters:
    ///   - clock: clock injetável (`VirtualClock` nos testes; `ContinuousClock` em produção).
    ///   - jitterFraction: fração máxima de jitter (0.1 = ±10%).
    ///   - random: fonte de aleatoriedade ∈ [-1, 1]; injetável p/ bounds determinísticos
    ///     nos testes (default: uniforme).
    public init(
        clock: any Clock<Duration>,
        jitterFraction: Double = 0.1,
        random: (@Sendable () -> Double)? = nil
    ) {
        self.clock = clock
        self.jitterFraction = max(0, jitterFraction)
        self.random = random ?? { Double.random(in: -1...1) }
    }

    // MARK: - Wiring

    /// Registra (ou substitui) o callback de fire do provider e inicia o loop.
    public func register(provider: ProviderID, onFire: @escaping FireHandler) {
        providers[provider]?.task?.cancel()
        var state = ProviderState(onFire: onFire)
        state.task = Task { await self.runLoop(provider: provider) }
        providers[provider] = state
    }

    /// Resultado do último ciclo do provider; decide o próximo intervalo.
    ///
    /// `pressure` = fração usada da janela mais crítica (0…1), se houver.
    /// Sucesso recalcula o intervalo do estado (zera backoff): pressão ≥ 0,8
    /// → 30 s; caso contrário → ocioso 5 min (menu aberto reafirma 60 s via
    /// `noteMenuOpened`). Erro dobra o intervalo atual com teto de 30 min.
    public func noteResult(provider: ProviderID, ok: Bool, pressure: Double?) {
        guard var state = providers[provider] else { return }
        if ok {
            if let pressure, pressure >= 0.8 {
                state.interval = Self.pressureInterval
            } else {
                state.interval = Self.idleInterval
            }
        } else {
            state.interval = min(state.interval * 2, Self.backoffCeiling)
        }
        providers[provider] = state
        // Fora de um fire em curso, o loop está dormindo com o intervalo antigo —
        // reinicia para o novo intervalo valer a partir de agora. Dentro de um
        // fire, o loop relê o estado ao re-agendar (caminho do wiring real).
        if !firing.contains(provider) {
            restart(provider: provider, immediate: false)
        }
    }

    /// Menu do painel aberto: cadência de 60 s a partir de agora.
    public func noteMenuOpened() {
        for provider in Array(providers.keys) {
            providers[provider]?.interval = Self.menuInterval
            restart(provider: provider, immediate: false)
        }
    }

    /// Mac foi dormir: nenhum fire enquanto pausado (rede zero em sleep, spec §7).
    public func pauseForSleep() {
        paused = true
    }

    /// Acordou do sleep: refresh imediato de todos + cadência normal retomada.
    public func resumeFromSleep() {
        paused = false
        for provider in Array(providers.keys) {
            restart(provider: provider, immediate: true)
        }
    }

    // MARK: - Loop

    /// Cancela o loop atual e recomeça com o intervalo vigente; `immediate`
    /// pula o primeiro sleep (refresh imediato do resume).
    private func restart(provider: ProviderID, immediate: Bool) {
        providers[provider]?.task?.cancel()
        providers[provider]?.immediate = immediate
        providers[provider]?.task = Task { await self.runLoop(provider: provider) }
    }

    private func runLoop(provider: ProviderID) async {
        while !Task.isCancelled {
            guard let state = providers[provider] else { return }

            if paused {
                // Estacionado (máquina dormindo): dorme sem disparar nada;
                // resumeFromSleep reinicia a task com fire imediato.
                try? await clock.sleep(for: state.interval)
                if Task.isCancelled { return }
                continue
            }

            if state.immediate {
                providers[provider]?.immediate = false
            } else {
                try? await clock.sleep(for: jittered(state.interval))
                if Task.isCancelled { return }
                if paused { continue }
            }

            // Single-flight: fire em curso → este tick vira fila p/ o próximo.
            guard !firing.contains(provider) else { continue }
            firing.insert(provider)
            let handler = state.onFire
            // Task desacoplada: cancelar o loop não cancela o fetch em curso.
            let fire = Task { await handler() }
            await fire.value
            firing.remove(provider)
        }
    }

    private func jittered(_ base: Duration) -> Duration {
        let roll = min(max(random(), -1), 1)
        return base * (1 + jitterFraction * roll)
    }
}
