package com.paytm.wallet.transfer;

import com.paytm.wallet.auth.AuthenticatedUser;
import com.paytm.wallet.auth.BearerTokenFilter;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

@RestController
@RequestMapping("/transfers")
public class TransferController {

    private final TransferService transferService;

    public TransferController(TransferService transferService) {
        this.transferService = transferService;
    }

    @PostMapping
    public ResponseEntity<TransferResponse> create(@Valid @RequestBody TransferRequest request,
                                                   HttpServletRequest httpRequest) {
        AuthenticatedUser user = (AuthenticatedUser) httpRequest.getAttribute(BearerTokenFilter.USER_ATTR);
        TransferService.TransferApiResult result = transferService.create(user.userId(), request);

        HttpStatus status = result.replay()
                ? HttpStatus.OK
                : switch (result.status()) {
                    case COMPLETED -> HttpStatus.CREATED;
                    case DECLINED_INSUFFICIENT_FUNDS -> HttpStatus.UNPROCESSABLE_ENTITY;
                    case PENDING -> throw new IllegalStateException(
                            "PENDING transfer must not escape the transaction boundary");
                };

        return ResponseEntity.status(status).body(result.response());
    }

    @GetMapping("/{id}")
    public TransferResponse get(@PathVariable("id") UUID id) {
        return transferService.getById(id);
    }
}
