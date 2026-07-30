FROM golang:1.24-alpine AS build

WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/update-api ./cmd/server

FROM alpine:3.22

RUN addgroup -S filenest && \
    adduser -S -G filenest filenest && \
    mkdir -p /data && \
    chown filenest:filenest /data

COPY --from=build /out/update-api /usr/local/bin/update-api

USER filenest
EXPOSE 8080

ENV FILENEST_UPDATE_ADDR=0.0.0.0:8080
ENV FILENEST_UPDATE_DATA_FILE=/data/releases.json

ENTRYPOINT ["/usr/local/bin/update-api"]
