FROM quay.io/keycloak/keycloak:26.5.1

COPY realm-config /opt/keycloak/data/import

ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

RUN /opt/keycloak/bin/kc.sh build
