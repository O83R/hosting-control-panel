FROM golang:1.27.2-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
COPY web ./web
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/panel .

FROM alpine:3.22
RUN apk add --no-cache sqlite \
 && addgroup -S panel \
 && adduser -S -G panel -u 10001 panel \
 && install -d -m 0750 -o panel -g panel /var/lib/panel
WORKDIR /app
COPY --from=build /out/panel /app/panel
USER panel
EXPOSE 8080
ENTRYPOINT ["/app/panel"]
