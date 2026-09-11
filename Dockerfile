# syntax=docker/dockerfile:1

# ---- build ----
FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /workspace

COPY pom.xml mvnw ./
COPY .mvn .mvn
COPY src src

RUN chmod +x mvnw \
 && ./mvnw -B -DskipTests package \
 && cp target/wallet-transfer-service-*.jar /workspace/app.jar

# ---- runtime ----
FROM eclipse-temurin:21-jre-alpine

RUN apk add --no-cache curl \
 && addgroup -S wallet \
 && adduser -S -G wallet wallet

WORKDIR /app

COPY --from=build /workspace/app.jar /app/app.jar

USER wallet

EXPOSE 8080

# Railway (and others) inject PORT; Spring binds to ${PORT:8080}.
# Healthcheck must use the same port or the container can flap / 502.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${PORT:-8080}/actuator/health || exit 1

ENV JAVA_OPTS=""
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
