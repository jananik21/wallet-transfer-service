package com.paytm.wallet.ledger;

import com.paytm.wallet.observability.DomainMetrics;
import com.paytm.wallet.transfer.TransferJdbcRepository;
import com.paytm.wallet.transfer.TransferRecord;
import com.paytm.wallet.transfer.TransferStatus;
import com.paytm.wallet.wallet.WalletEntity;
import com.paytm.wallet.wallet.WalletJdbcRepository;
import com.paytm.wallet.web.IdempotencyConflictException;
import com.paytm.wallet.web.NotFoundException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * Reusable money-movement primitive.
 * Idempotency claim + wallet locks + debit/credit happen in ONE database transaction.
 *
 * Lock order matters: wallets are locked BEFORE inserting the transfer row.
 * Inserting first takes FOR KEY SHARE via FKs; upgrading to FOR UPDATE under
 * concurrency can deadlock. Locking first avoids that.
 */
@Service
public class MoneyMovementService {

    private static final Logger log = LoggerFactory.getLogger(MoneyMovementService.class);

    private final TransferJdbcRepository transferJdbcRepository;
    private final WalletJdbcRepository walletJdbcRepository;
    private final DomainMetrics domainMetrics;

    public MoneyMovementService(TransferJdbcRepository transferJdbcRepository,
                                WalletJdbcRepository walletJdbcRepository,
                                DomainMetrics domainMetrics) {
        this.transferJdbcRepository = transferJdbcRepository;
        this.walletJdbcRepository = walletJdbcRepository;
        this.domainMetrics = domainMetrics;
    }

    public record MovementResult(TransferRecord transfer, boolean replay) {
    }

    @Transactional
    public MovementResult transfer(UUID fromWalletId,
                                   UUID toWalletId,
                                   long amountPaise,
                                   String idempotencyKey) {
        if (fromWalletId.equals(toWalletId)) {
            throw new IllegalArgumentException("from and to wallets must be different");
        }
        if (amountPaise <= 0) {
            throw new IllegalArgumentException("amount_paise must be positive");
        }

        String requestHash = RequestHasher.hashTransferRequest(fromWalletId, toWalletId, amountPaise);

        // Fast path for replays: avoid locking wallets when the key already finalized.
        var existingBefore = transferJdbcRepository.findByIdempotencyKey(idempotencyKey);
        if (existingBefore.isPresent()) {
            TransferRecord existing = existingBefore.get();
            if (existing.status() == TransferStatus.PENDING) {
                // Extremely unlikely to observe committed PENDING; treat as conflict with in-flight.
                throw new IllegalStateException("Transfer still PENDING for key=" + idempotencyKey);
            }
            if (!existing.requestHash().equals(requestHash)) {
                log.info("event=idempotency_conflict idempotencyKey={}", idempotencyKey);
                throw new IdempotencyConflictException(
                        "Idempotency key was reused with a different transfer request");
            }
            log.info("event=idempotent_replay transferId={} idempotencyKey={} status={}",
                    existing.id(), idempotencyKey, existing.status());
            domainMetrics.idempotentReplay();
            return new MovementResult(existing, true);
        }

        List<WalletEntity> locked = walletJdbcRepository.lockByIdsForUpdateOrdered(fromWalletId, toWalletId);
        if (locked.size() != 2) {
            throw new NotFoundException("One or both wallets not found");
        }

        // Re-check after locks: a concurrent TX may have committed the same key while we waited.
        existingBefore = transferJdbcRepository.findByIdempotencyKey(idempotencyKey);
        if (existingBefore.isPresent()) {
            TransferRecord existing = existingBefore.get();
            if (!existing.requestHash().equals(requestHash)) {
                log.info("event=idempotency_conflict idempotencyKey={}", idempotencyKey);
                throw new IdempotencyConflictException(
                        "Idempotency key was reused with a different transfer request");
            }
            log.info("event=idempotent_replay transferId={} idempotencyKey={} status={}",
                    existing.id(), idempotencyKey, existing.status());
            domainMetrics.idempotentReplay();
            return new MovementResult(existing, true);
        }

        UUID transferId = UUID.randomUUID();
        boolean claimed = transferJdbcRepository.tryInsertPending(
                transferId, fromWalletId, toWalletId, amountPaise, idempotencyKey, requestHash);

        if (!claimed) {
            TransferRecord existing = transferJdbcRepository.findByIdempotencyKey(idempotencyKey)
                    .orElseThrow(() -> new IllegalStateException(
                            "Idempotency conflict without visible row for key=" + idempotencyKey));
            if (!existing.requestHash().equals(requestHash)) {
                log.info("event=idempotency_conflict idempotencyKey={}", idempotencyKey);
                throw new IdempotencyConflictException(
                        "Idempotency key was reused with a different transfer request");
            }
            log.info("event=idempotent_replay transferId={} idempotencyKey={} status={}",
                    existing.id(), idempotencyKey, existing.status());
            domainMetrics.idempotentReplay();
            return new MovementResult(existing, true);
        }

        log.info("event=transfer_created transferId={} from={} to={} amountPaise={}",
                transferId, fromWalletId, toWalletId, amountPaise);

        int debited = walletJdbcRepository.conditionalDebit(fromWalletId, amountPaise);
        if (debited == 0) {
            TransferRecord declined = transferJdbcRepository.updateStatus(
                    transferId, TransferStatus.DECLINED_INSUFFICIENT_FUNDS);
            log.info("event=transfer_declined_insufficient_funds transferId={} from={} amountPaise={}",
                    transferId, fromWalletId, amountPaise);
            domainMetrics.transferDeclinedInsufficientFunds();
            return new MovementResult(declined, false);
        }

        log.info("event=transfer_debited transferId={} walletId={} amountPaise={}",
                transferId, fromWalletId, amountPaise);

        int credited = walletJdbcRepository.credit(toWalletId, amountPaise);
        if (credited != 1) {
            throw new IllegalStateException("Credit failed for wallet " + toWalletId);
        }

        log.info("event=transfer_credited transferId={} walletId={} amountPaise={}",
                transferId, toWalletId, amountPaise);

        TransferRecord completed = transferJdbcRepository.updateStatus(transferId, TransferStatus.COMPLETED);
        domainMetrics.transferCreated();
        return new MovementResult(completed, false);
    }
}
