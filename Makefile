.PHONY: all clean

all:
	./scripts/build_macos.sh

clean:
	rm -rf dist
