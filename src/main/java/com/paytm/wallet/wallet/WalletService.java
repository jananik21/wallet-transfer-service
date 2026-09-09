package com.paytm.wallet.wallet;

import com.paytm.wallet.web.NotFoundException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

@Service
public class WalletService {

    private static final Logger log = LoggerFactory.getLogger(WalletService.class);

    private final WalletJdbcRepository walletJdbcRepository;

    public WalletService(WalletJdbcRepository walletJdbcRepository) {
        this.walletJdbcRepository = walletJdbcRepository;
    }

    @Transactional
    public GetOrCreateWalletResult getOrCreate(String userId) {
        UUID candidateId = UUID.randomUUID();
        boolean created = walletJdbcRepository.insertIgnoreConflict(candidateId, userId);

        WalletEntity wallet = walletJdbcRepository.findByUserId(userId)
                .orElseThrow(() -> new IllegalStateException(
                        "Wallet missing after get-or-create for user_id=" + userId));

        if (created) {
            log.info("event=wallet_created walletId={} userId={}", wallet.getId(), userId);
        } else {
            log.info("event=wallet_existing_returned walletId={} userId={}", wallet.getId(), userId);
        }

        return new GetOrCreateWalletResult(WalletResponse.from(wallet), created);
    }

    @Transactional(readOnly = true)
    public WalletResponse getById(UUID walletId) {
        WalletEntity wallet = walletJdbcRepository.findById(walletId)
                .orElseThrow(() -> new NotFoundException("Wallet not found: " + walletId));
        return WalletResponse.from(wallet);
    }
}
