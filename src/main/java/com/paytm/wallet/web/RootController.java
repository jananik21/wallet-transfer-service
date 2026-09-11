package com.paytm.wallet.web;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Browser-friendly landing for the live URL (API-only service, no UI).
 */
@RestController
public class RootController {

    @GetMapping("/")
    public Map<String, Object> root() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("service", "wallet-transfer-service");
        body.put("status", "ok");
        body.put("message", "Backend API only — no web UI. Money movement is concurrency-safe and idempotent.");
        body.put("invariants", List.of(
                "Race-free wallet get-or-create (one wallet per user)",
                "Conservation of money under concurrent transfers",
                "No overdraft (conditional debit + CHECK constraint)",
                "Exactly-once transfers via DB-unique idempotency keys"
        ));
        body.put("health", "/actuator/health");
        body.put("metrics", "/actuator/prometheus");
        body.put("try_it", Map.of(
                "create_wallet", "curl -s -X POST /wallets -H 'Authorization: Bearer demo-user-1-token'",
                "transfer", "curl -s -X POST /transfers -H 'Authorization: Bearer demo-user-1-token' -H 'Content-Type: application/json' -d '{...}'"
        ));
        body.put("endpoints", Map.of(
                "create_or_get_wallet", "POST /wallets",
                "get_wallet", "GET /wallets/{id}",
                "create_transfer", "POST /transfers",
                "get_transfer", "GET /transfers/{id}"
        ));
        body.put("demo_tokens", List.of(
                "demo-user-1-token",
                "demo-user-2-token",
                "demo-user-3-token"
        ));
        body.put("auth_header", "Authorization: Bearer <demo-token>");
        body.put("docs", "https://github.com/jananik21/wallet-transfer-service");
        body.put("design", "https://github.com/jananik21/wallet-transfer-service/blob/main/DESIGN.md");
        return body;
    }
}
