package com.paytm.wallet.auth;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.paytm.wallet.web.ApiError;
import com.paytm.wallet.web.CorrelationIdFilter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.MDC;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.time.Instant;

@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 20)
public class BearerTokenFilter extends OncePerRequestFilter {

    public static final String USER_ATTR = "authenticatedUser";

    private final TokenRepository tokenRepository;
    private final ObjectMapper objectMapper;

    public BearerTokenFilter(TokenRepository tokenRepository, ObjectMapper objectMapper) {
        this.tokenRepository = tokenRepository;
        this.objectMapper = objectMapper;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        return !(path.startsWith("/wallets") || path.startsWith("/transfers"));
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {
        String header = request.getHeader("Authorization");
        if (header == null || !header.regionMatches(true, 0, "Bearer ", 0, 7)) {
            writeUnauthorized(request, response, "Missing or invalid Authorization header");
            return;
        }

        String rawToken = header.substring(7).trim();
        if (rawToken.isEmpty()) {
            writeUnauthorized(request, response, "Missing bearer token");
            return;
        }

        String tokenHash = TokenHasher.sha256Hex(rawToken);
        var userId = tokenRepository.findUserIdByTokenHash(tokenHash);
        if (userId.isEmpty()) {
            writeUnauthorized(request, response, "Invalid bearer token");
            return;
        }

        request.setAttribute(USER_ATTR, new AuthenticatedUser(userId.get()));
        MDC.put("userId", userId.get());
        try {
            filterChain.doFilter(request, response);
        } finally {
            MDC.remove("userId");
        }
    }

    private void writeUnauthorized(HttpServletRequest request, HttpServletResponse response, String message)
            throws IOException {
        response.setStatus(HttpStatus.UNAUTHORIZED.value());
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        ApiError body = new ApiError(
                Instant.now(),
                HttpStatus.UNAUTHORIZED.value(),
                HttpStatus.UNAUTHORIZED.getReasonPhrase(),
                message,
                request.getRequestURI(),
                MDC.get(CorrelationIdFilter.MDC_KEY)
        );
        objectMapper.writeValue(response.getOutputStream(), body);
    }
}
