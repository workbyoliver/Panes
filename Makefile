APP := build/Panes.app
# Quit a running copy and wait for it to exit, so `open` launches the new build.
QUIT := pkill -x Panes; while pgrep -x Panes >/dev/null; do sleep 0.1; done

.PHONY: build debug run install zip clean

build:
	./scripts/build.sh

debug:
	CONFIG=debug ./scripts/build.sh

run: build
	$(QUIT)
	open $(APP)

install: build
	$(QUIT)
	rm -rf /Applications/Panes.app
	cp -R $(APP) /Applications/Panes.app
	open /Applications/Panes.app

# dist/Panes.zip to send to someone (see Caveats in README.md)
zip: build
	mkdir -p dist
	rm -f dist/Panes.zip
	ditto -c -k --keepParent $(APP) dist/Panes.zip

clean:
	rm -rf build .build dist
