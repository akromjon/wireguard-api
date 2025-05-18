.PHONY: build run test clean

# Build the application
build:
	go build -o wireguard-api main.go

# Run the application
run:
	go run main.go

# Build and run the application
start: build
	./wireguard-api

# Run tests
test:
	go test -v ./...

# Clean build artifacts
clean:
	rm -f wireguard-api
	
# Update dependencies
deps:
	go mod tidy
	go mod verify 