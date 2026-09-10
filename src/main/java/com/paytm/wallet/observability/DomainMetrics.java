package com.paytm.wallet.observability;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.stereotype.Component;

@Component
public class DomainMetrics {

    private final Counter transfersCreated;
    private final Counter transfersDeclinedInsufficientFunds;
    private final Counter idempotentReplays;

    public DomainMetrics(MeterRegistry registry) {
        this.transfersCreated = Counter.builder("transfers_created_total")
                .description("Transfers that completed successfully (money moved)")
                .register(registry);
        this.transfersDeclinedInsufficientFunds = Counter.builder("transfers_declined_insufficient_funds_total")
                .description("Transfers declined due to insufficient funds")
                .register(registry);
        this.idempotentReplays = Counter.builder("idempotent_replays_total")
                .description("Idempotent replays of an existing transfer key")
                .register(registry);
    }

    public void transferCreated() {
        transfersCreated.increment();
    }

    public void transferDeclinedInsufficientFunds() {
        transfersDeclinedInsufficientFunds.increment();
    }

    public void idempotentReplay() {
        idempotentReplays.increment();
    }
}
