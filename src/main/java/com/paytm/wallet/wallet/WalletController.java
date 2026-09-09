package com.paytm.wallet.wallet;

import com.paytm.wallet.auth.AuthenticatedUser;
import com.paytm.wallet.auth.BearerTokenFilter;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/wallets")
public class WalletController {

    private final WalletService walletService;

    public WalletController(WalletService walletService) {
        this.walletService = walletService;
    }

    @PostMapping
    public ResponseEntity<WalletResponse> getOrCreate(HttpServletRequest request) {
        AuthenticatedUser user = currentUser(request);
        GetOrCreateWalletResult result = walletService.getOrCreate(user.userId());
        HttpStatus status = result.created() ? HttpStatus.CREATED : HttpStatus.OK;
        return ResponseEntity.status(status).body(result.wallet());
    }

    @GetMapping("/{id}")
    public WalletResponse getWallet(@PathVariable("id") UUID id) {
        return walletService.getById(id);
    }

    private static AuthenticatedUser currentUser(HttpServletRequest request) {
        return (AuthenticatedUser) request.getAttribute(BearerTokenFilter.USER_ATTR);
    }
}
