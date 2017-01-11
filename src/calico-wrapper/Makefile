VERSION ?= latest

.PHONY: build push release

build:
	GOOS=linux CGO_ENABLED=0 go build -a -installsuffix cgo .
	docker build -t sykesm/calico-wrapper:$(VERSION) .

push:
	docker push sykesm/calico-wrapper:$(VERSION)

default: build
