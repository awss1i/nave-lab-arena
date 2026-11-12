# Nave's gateway prototype as an image holding one file, for the image size and start races.
FROM scratch
COPY bin/p006-formats /nave-gateway
USER 65532:65532
ENTRYPOINT ["/nave-gateway"]
