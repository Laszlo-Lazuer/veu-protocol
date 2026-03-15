FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o veu-voice-relay .

FROM alpine:3.19
COPY --from=builder /app/veu-voice-relay /usr/local/bin/
EXPOSE 8080
CMD ["veu-voice-relay"]
