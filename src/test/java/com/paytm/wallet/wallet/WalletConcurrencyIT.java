package com.paytm.wallet.wallet;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@Testcontainers
class WalletConcurrencyIT {

    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("wallet")
            .withUsername("wallet")
            .withPassword("wallet");

    @DynamicPropertySource
    static void datasourceProps(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @Autowired
    TestRestTemplate restTemplate;

    @Autowired
    JdbcTemplate jdbcTemplate;

    @Test
    void getOrCreateIsRaceFreeUnderBurst() throws Exception {
        int concurrency = 50;
        ExecutorService pool = Executors.newFixedThreadPool(concurrency);
        CountDownLatch ready = new CountDownLatch(concurrency);
        CountDownLatch start = new CountDownLatch(1);
        CountDownLatch done = new CountDownLatch(concurrency);

        Set<String> walletIds = ConcurrentHashMap.newKeySet();
        AtomicInteger success = new AtomicInteger();
        AtomicInteger created = new AtomicInteger();

        HttpHeaders headers = new HttpHeaders();
        headers.setBearerAuth("demo-user-1-token");
        HttpEntity<Void> entity = new HttpEntity<>(headers);

        for (int i = 0; i < concurrency; i++) {
            pool.submit(() -> {
                ready.countDown();
                try {
                    start.await(10, TimeUnit.SECONDS);
                    ResponseEntity<Map> response = restTemplate.exchange(
                            "/wallets",
                            HttpMethod.POST,
                            entity,
                            Map.class
                    );
                    if (response.getStatusCode().is2xxSuccessful()) {
                        success.incrementAndGet();
                        if (response.getStatusCode() == HttpStatus.CREATED) {
                            created.incrementAndGet();
                        }
                        Object id = response.getBody().get("id");
                        walletIds.add(String.valueOf(id));
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                } finally {
                    done.countDown();
                }
            });
        }

        assertThat(ready.await(10, TimeUnit.SECONDS)).isTrue();
        start.countDown();
        assertThat(done.await(60, TimeUnit.SECONDS)).isTrue();
        pool.shutdown();

        assertThat(success.get()).isEqualTo(concurrency);
        assertThat(walletIds).hasSize(1);
        assertThat(created.get()).isEqualTo(1);

        Integer count = jdbcTemplate.queryForObject(
                "SELECT COUNT(*) FROM wallets WHERE user_id = ?",
                Integer.class,
                "user-1"
        );
        assertThat(count).isEqualTo(1);
    }

    @Test
    void getWalletByIdReturnsBalance() {
        HttpHeaders headers = new HttpHeaders();
        headers.setBearerAuth("demo-user-2-token");
        HttpEntity<Void> entity = new HttpEntity<>(headers);

        ResponseEntity<Map> create = restTemplate.exchange("/wallets", HttpMethod.POST, entity, Map.class);
        assertThat(create.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        UUID id = UUID.fromString(String.valueOf(create.getBody().get("id")));

        ResponseEntity<Map> get = restTemplate.exchange("/wallets/" + id, HttpMethod.GET, entity, Map.class);
        assertThat(get.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(get.getBody().get("balance_paise")).isEqualTo(0);
        assertThat(get.getBody().get("user_id")).isEqualTo("user-2");
    }

    @Test
    void missingTokenReturns401() {
        ResponseEntity<Map> response = restTemplate.exchange(
                "/wallets",
                HttpMethod.POST,
                HttpEntity.EMPTY,
                Map.class
        );
        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
    }
}
