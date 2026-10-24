# Build from the backend repository root (the build context), with this file passed via -f:
#   docker build -f ../infra/docker/backend/Dockerfile -t gmc-backend .

# --- Build stage: resolve dependencies (cached layer), then package the jar ---
FROM eclipse-temurin:25-jdk-alpine AS build
WORKDIR /app
COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN chmod +x mvnw && ./mvnw -B -q dependency:go-offline
COPY config config
COPY src src
# Lint and tests already ran in CI; this stage only builds the artifact
RUN ./mvnw -B -q package -DskipTests -Dcheckstyle.skip -Djacoco.skip

# --- Runtime stage: JRE only, non-root user ---
FROM eclipse-temurin:25-jre-alpine
RUN addgroup -S app && adduser -S app -G app \
    && mkdir -p /app/uploads && chown app:app /app/uploads
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
USER app
# All configuration comes from environment variables (see .env.example).
# Uploaded images live in /app/uploads: mount a persistent disk/volume there in staging and production.
ENV PORT=8080 \
    UPLOAD_DIR=/app/uploads/ \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75"
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
