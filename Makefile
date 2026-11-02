.PHONY: help build debug app test run clean

help:
	@echo "make build   – compile the app (debug)"
	@echo "make app     – build BUU.app in build/"
	@echo "make test    – run the BUUKit unit tests"
	@echo "make run     – run the app from the terminal"
	@echo "make clean   – remove build artefacts"

build:
	swift build

debug:
	swift build -c debug

app:
	./Scripts/build-app.sh release

test:
	swift test

run:
	swift run BUU

clean:
	rm -rf .build build
