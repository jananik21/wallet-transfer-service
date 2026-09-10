package com.paytm.wallet.transfer;

import com.paytm.wallet.ledger.MoneyMovementService;
import com.paytm.wallet.wallet.WalletEntity;
import com.paytm.wallet.wallet.WalletJdbcRepository;
import com.paytm.wallet.web.ForbiddenException;
import com.paytm.wallet.web.NotFoundException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
public class TransferService {

    private final MoneyMovementService moneyMovementService;
    private final WalletJdbcRepository walletJdbcRepository;
    private final TransferJdbcRepository transferJdbcRepository;

    public TransferService(MoneyMovementService moneyMovementService,
                           WalletJdbcRepository walletJdbcRepository,
                           TransferJdbcRepository transferJdbcRepository) {
        this.moneyMovementService = moneyMovementService;
        this.walletJdbcRepository = walletJdbcRepository;
        this.transferJdbcRepository = transferJdbcRepository;
    }

    public record TransferApiResult(TransferResponse response, boolean replay, TransferStatus status) {
    }

    public TransferApiResult create(String authenticatedUserId, TransferRequest request) {
        WalletEntity fromWallet = walletJdbcRepository.findById(request.from())
                .orElseThrow(() -> new NotFoundException("Source wallet not found: " + request.from()));

        if (!fromWallet.getUserId().equals(authenticatedUserId)) {
            throw new ForbiddenException("You can only transfer from your own wallet");
        }

        if (!walletJdbcRepository.findById(request.to()).isPresent()) {
            throw new NotFoundException("Destination wallet not found: " + request.to());
        }

        MoneyMovementService.MovementResult result = moneyMovementService.transfer(
                request.from(),
                request.to(),
                request.amountPaise(),
                request.idempotencyKey()
        );

        return new TransferApiResult(result.transfer().toResponse(), result.replay(), result.transfer().status());
    }

    @Transactional(readOnly = true)
    public TransferResponse getById(UUID transferId) {
        return transferJdbcRepository.findById(transferId)
                .map(TransferRecord::toResponse)
                .orElseThrow(() -> new NotFoundException("Transfer not found: " + transferId));
    }
}
