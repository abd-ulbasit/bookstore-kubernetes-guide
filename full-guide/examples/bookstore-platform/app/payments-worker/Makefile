.PHONY: build test image clean

SERVICE := payments-worker
IMAGE   := bookstore/$(SERVICE):dev

build:
	go build -o $(SERVICE) .

test:
	go vet ./...
	go build ./...

image:
	docker build -t $(IMAGE) .

clean:
	rm -f $(SERVICE)
