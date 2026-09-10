package com.paytm.wallet.transfer;

import java.time.Instant;
import java.util.UUID;

public record TransferResponse(
        UUID id,
        UUID fromWalletId,
        UUID toWalletId,
        long amountPaise,
        TransferStatus status,
        String idempotencyKey,
        Instant createdAt,
        Instant updatedAt
) {
}
