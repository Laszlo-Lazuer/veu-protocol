FROM golang:1.22-alpine AS builder
RUN apk add --no-cache gcc musl-dev sqlite-dev
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -o veu-relay .

FROM alpine:3.19
RUN apk add --no-cache sqlite-libs
COPY --from=builder /app/veu-relay /usr/local/bin/
EXPOSE 8080
CMD ["veu-relay"]
