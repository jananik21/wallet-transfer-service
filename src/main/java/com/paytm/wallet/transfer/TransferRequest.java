package com.paytm.wallet.transfer;

import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

import java.util.UUID;

public record TransferRequest(
        @NotNull UUID from,
        @NotNull UUID to,
        @Positive
        @Max(value = 1_000_000_000_000_000L, message = "amount_paise exceeds allowed maximum")
        long amountPaise,
        @NotBlank
        @Size(max = 128, message = "idempotency_key must be at most 128 characters")
        String idempotencyKey
) {
    @AssertTrue(message = "from and to wallets must be different")
    public boolean isDifferentWallets() {
        return from == null || to == null || !from.equals(to);
    }
}
