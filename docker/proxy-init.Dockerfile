ARG BASEIMAGE=k8s.gcr.io/build-image/debian-iptables:bullseye-v1.5.1

FROM --platform=${TARGETPLATFORM:-linux/amd64} ${BASEIMAGE}

RUN clean-install ca-certificates
COPY ./init/init-iptables.sh /bin/
RUN chmod +x /bin/init-iptables.sh
# Kubernetes runAsNonRoot requires USER to be numeric
USER 65532:65532

ENTRYPOINT ["./bin/init-iptables.sh"]
