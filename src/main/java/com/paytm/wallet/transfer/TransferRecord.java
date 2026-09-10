package com.paytm.wallet.transfer;

import java.time.Instant;
import java.util.UUID;

public record TransferRecord(
        UUID id,
        UUID fromWalletId,
        UUID toWalletId,
        long amountPaise,
        TransferStatus status,
        String idempotencyKey,
        String requestHash,
        Instant createdAt,
        Instant updatedAt
) {
    TransferResponse toResponse() {
        return new TransferResponse(
                id,
                fromWalletId,
                toWalletId,
                amountPaise,
                status,
                idempotencyKey,
                createdAt,
                updatedAt
        );
    }
}
