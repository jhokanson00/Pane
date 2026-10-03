.PHONY: app run debug clean

INSTALL_PATH = /Applications/Pane.app
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

app:
	./scripts/build-app.sh release

# Rebuild, install to /Applications (so Spotlight, Launchpad and macOS's
# "Quit & Reopen" can find it), quit any running copy, and launch.
run: app
	-pkill -x Pane
	@while pgrep -x Pane >/dev/null; do sleep 0.2; done
	rm -rf "$(INSTALL_PATH)"
	cp -R build/Pane.app "$(INSTALL_PATH)"
	$(LSREGISTER) -f "$(INSTALL_PATH)"
	open "$(INSTALL_PATH)" || (sleep 1 && open "$(INSTALL_PATH)")

debug:
	./scripts/build-app.sh debug
	-pkill -x Pane
	open build/Pane.app

clean:
	rm -rf .build build
