.PHONY: app run debug clean

INSTALL_PATH = /Applications/Pane.app
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

app:
	./scripts/build-app.sh release

# Pane writing a recording: a file in Movies/Pane open for writing. Quitting it then
# would lose the recording, so run and debug stop instead.
RECORDING_CHECK = lsof -c Pane -F an 2>/dev/null | awk '/^a/ { mode = substr($$0, 2) } \
	/^n/ { if (mode ~ /[wu]/ && $$0 ~ /\/Movies\/Pane\//) found = 1 } END { exit !found }'
NOT_WHILE_RECORDING = if $(RECORDING_CHECK); then \
	echo "Pane is recording. Stop the recording first, then try again."; exit 1; fi

# Rebuild, install to /Applications (so Spotlight, Launchpad and macOS's
# "Quit & Reopen" can find it), quit any running copy, and launch.
run: app
	@$(NOT_WHILE_RECORDING)
	-pkill -x Pane
	@while pgrep -x Pane >/dev/null; do sleep 0.2; done
	rm -rf "$(INSTALL_PATH)"
	cp -R build/Pane.app "$(INSTALL_PATH)"
	$(LSREGISTER) -f "$(INSTALL_PATH)"
	open "$(INSTALL_PATH)" || (sleep 1 && open "$(INSTALL_PATH)")

debug:
	./scripts/build-app.sh debug
	@$(NOT_WHILE_RECORDING)
	-pkill -x Pane
	open build/Pane.app

clean:
	rm -rf .build build
