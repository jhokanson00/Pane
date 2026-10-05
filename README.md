# Pane

A private Mac screen recorder for making tutorial videos. Record your screen with your
camera in a corner, and Pane finds and blurs emails, phone numbers, passwords and keys
for you before you share. A teleprompter follows your voice as you read your script,
and the sentences you say again are cut for you. Pointer highlights, click sounds, zoom
toward clicks, keyboard shortcut badges and captions are all added at export, so they
can be changed after you record. Native Swift, runs entirely on your Mac, free and open
source.

## Download

**[Download the latest Pane](https://github.com/jhokanson00/Pane/releases/latest)**:
open the `.dmg` and drag Pane to Applications. Pane checks for updates once a day after
asking you, or choose **Pane ▸ Check for Updates…**.

- macOS 15 or later; captions need macOS 26. Apple silicon and Intel.
- Signed with Developer ID and notarized by Apple.

New to Pane? [HOWTO.md](HOWTO.md) is a short guide. The same guide opens in the app from
**Help ▸ Pane Help** (⌘?).

## Privacy

Everything happens on your Mac: recording, reading text on screen, blurring and
captions all use Apple's on-device frameworks. Pane never uploads your recordings and
has no accounts, analytics or tracking. Its only network request is the update check,
which downloads a small file from this repo's GitHub releases. Recordings are saved to
`~/Movies/Pane`.

**Permissions.** On first use macOS asks for **Screen & System Audio Recording**,
**Camera** and **Microphone**. After granting Screen Recording, quit and reopen Pane.
Captions ask for **Speech Recognition**, and keyboard shortcut badges for **Input
Monitoring**, only when you turn them on.

## Report a bug

Choose **Help ▸ Report a Bug…** in Pane. It opens a GitHub issue with your Pane and macOS
versions filled in. Or [open an issue](https://github.com/jhokanson00/Pane/issues/new/choose)
directly. Please don't attach recordings that show private information.

## Recording

- Record any display to MP4 (H.264, up to 4K, 30 fps), or just one window. A window
  recording keeps capturing that window even when other windows pass in front of it.
- Camera circle drawn into a chosen corner of the video: three sizes, mirror, colored
  border, and a background replacement (blur, solid color or your own image) using
  on-device person detection
- A matching bubble on screen while recording so you can see yourself. It's never
  captured, and clicks pass through it.
- Microphone and optional system audio
- 3-2-1 countdown
- **Never record** list: windows from chosen apps (1Password, Messages, etc.) are left
  out of the recording entirely. Pane's own windows are always excluded.

**No distractions in full-screen recordings.** Notification banners are always left out,
including ones that pop up mid-recording; desktop widgets stay. Turn on "Hide desktop
icons" in the Record settings to leave the icons on your desktop out too: they stay on
your real desktop, and Finder windows and the wallpaper are still recorded. While
recording, Pane rebuilds what it leaves out every half second, and within about a tenth
of a second when a left-out app opens a window. So a "Never record" app opened after
recording starts is now left out too, after its first few frames
(`DistractionGuard`, rules in `PaneKit/CaptureExclusion.swift`). Window
recordings only ever show their one window, so they need neither.

## Auto-blur

When a recording stops, Pane reads its on-screen text about 3 times a second (Apple's
Vision framework, on-device) and finds emails, phone numbers, keys, tokens and passwords,
card and ID numbers, and words from your own list. It then follows each one on every
frame, so the blur stays on the text as you scroll, including just before it was first
read and as it leaves the screen. The blur snaps to the real edges of the text so
neighboring words stay readable, and gives it a frosted-glass look that can't be read
back. The review window previews exactly what the export will look like.

The review window shows every item as a **blur layer** you can turn on or off. You can
add your own layers: **Blur Text** (click any word to blur it everywhere it appears) or
**Draw Box** (blur any area for the whole video, or narrow it by dragging its ends in the timeline). **Export
Video** saves an edited copy, with the blur and pointer effects, next to the original.

To review any existing video, use "Blur an Existing Video…" in the main window, drop the
file on Pane's Dock icon, or choose Open With → Pane in Finder.

## Pointer effects

While recording, Pane logs where the pointer goes, its shape, and every click. It
draws nothing on the recording itself, so the effects can be changed later. The log is
stored inside the video file's extended attributes, so it moves with the file. On export
(and in the review window's preview):

- A soft circle follows the pointer while it moves and fades out about a second after
  it stops.
- Over a link or button (whenever the pointer is the pointing hand), the circle tightens
  and its edge strengthens, so viewers see you're about to click.
- Every click sends out a ring. Clicks on links get a bolder ring, and right-clicks get
  two.
- Nothing is drawn behind the camera circle, where the real pointer is hidden.

The **Pointer** tab in the review window sets the color and size, turns each effect on
or off, and lists every click so stray ones can be hidden. The style is remembered for
the next recording. Pointer effects need no extra macOS permission. Clicks on Pane
itself, like the Stop button, aren't logged.

**Zoom toward clicks** (Off, Subtle 1.4×, Strong 1.8×; off until you choose a level)
moves in closer starting just before each click, follows the pointer calmly while
zoomed, and eases back out shortly after the last click. Clicks less than 2.5 seconds
apart share one zoom. The zoom never shows past the edge of the video, the blurs and
pointer effects grow with it, and the camera circle stays where it is at its normal
size. Hidden clicks and clicks outside the video aren't zoomed toward.

**Click sounds** (off by default, in the Pointer tab) add a crisp mouse click at every click
shown in the click list, a little lower for right-clicks. The sound is made in code, so
there's no audio file to ship. Exports mix it into the first audio track (the
microphone), since most web players only play that one, at exactly the click's moment;
the rest of the audio and its timing stay the same. A recording without sound gets a
track with just the clicks. Send to Final Cut doesn't mix them in: each click becomes
its own clip under the screen with the "effects" role, so they can be turned down,
moved or deleted. The review window's preview doesn't play them.

## Pause and resume

While recording, the menu bar panel has **Pause** next to Stop (⌘P while the panel is
open). While paused, the menu bar and the panel say "Paused" and the time stops counting.
Nothing is saved while paused: no screen, camera, microphone, system audio or pointer,
and nothing in the separate Final Cut clips. **Resume** continues the same file with no
gap, so the pointer effects and click times still line up. The camera bubble stays on
screen while paused, and stopping while paused saves the recording as usual. The timing
logic is `PaneKit/RecordingPauses.swift`.

## Teleprompter

Write your script in Pane (**Write Script…** in the main window's Teleprompter section,
or open a .txt or .md file), and while you record it shows at the top of the screen,
just under your Mac's camera: three rows of large text in a narrow strip, so your eyes
barely move as you read. It moves as you speak, with no auto-scroll to keep up with:
Pane listens to the microphone it's already recording and follows your words through
the script with Apple's on-device speech recognition (macOS 26 or later). Words you've
said dim, and the row you're on stays at the top.

- Put stage directions in square brackets, like `[Click Settings]`. They show in orange
  and tick off when you click.
- Skip ahead, ad-lib or go back: the teleprompter finds its place again. Say a sentence
  over and it goes back with you.
- **Control-Option-↑** starts the sentence over, **Control-Option-↓** skips to the next
  one. They work in any app, need no permission, and are never shown as shortcut badges.
- The strip is one of Pane's windows, so it's never recorded. Clicks pass through it,
  and it fades while the pointer is over it.
- **Rehearse** shows it and follows your voice without recording. Text sizes: Small,
  Medium, Large. With the microphone off, it shows the script and the keys move it.

## Keyboard shortcuts

With **Show keyboard shortcuts** on (Pointer settings, off by default), Pane logs the
shortcuts you press while recording and shows each one in exports as a dark badge near
the bottom, such as "⇧ ⌘ R" or "⌥ ←". A new shortcut replaces the badge at once, and
pressing the same one again counts up ("⌘ Z ×3"). Only key presses made with Command or
Control held, and keys that never type (Esc, Return, Tab, Delete, arrows, F-keys), are
logged; ordinary typing, Shift+letter and Option+letter never are, so passwords and
messages stay out of the log. Shortcuts pressed in Pane itself (like ⌘P) or while paused
aren't logged either. It needs macOS's Input Monitoring access, asked for when
you turn the setting on; without it, Pane records without shortcuts and says so. The log
is stored with the video like the pointer's (`com.jacobhokanson.pane.keys`), and the
review window's Pointer tab turns the badges on or off. Try it with
`swift run pane-tool shortcuts-demo build/test/keys.mp4 [--camera]`; `pane-tool shortcuts
<recording>` lists what a recording logged.

## Send to Final Cut

With the camera on, Pane also keeps the screen and the camera circle (on a transparent
background) as separate clips. **Send to Final Cut** in the review window exports the
screen with its blurs and pointer effects, puts it next to the camera clip in a
"(Final Cut)" folder beside the recording, and opens a project in Final Cut Pro: the
screen on the timeline, the camera on its own layer above it, and a marker at every
click. Turn off "Keep the camera as its own clip for Final Cut" in the Camera settings
to save disk space; the screen then goes over with the camera already in it.

## Timeline and trim

Under the player in the review window, a timeline shows the whole recording: the video,
each blur layer, the clicks and the captions, with the playhead running through them.
Click anywhere on it to jump there. Drag either end of the **Video** bar to cut off the
start or end; **Clear Trim** keeps the whole video again, and the text beside it says
what's kept (for example "Keeping 0:03–1:12"). Drag the ends of a blur you drew, or a
word-list blur, to change when it shows; blurs the scan found keep the times it tracked
the text for. **Export Video** saves only that part, with the sound in step and
blurs and pointer effects where they were. **Send to Final Cut** keeps the whole files
and trims the clips in the project instead, so the cut parts can be brought back by
dragging a clip's ends; clicks outside the kept part get no marker. The trim lasts while
the review window is open.

## Retakes

A recording made with the teleprompter keeps its script with the video (in the
`com.jacobhokanson.pane.script` extended attribute). When it opens in the review window,
Pane hears the narration (once; captions reuse it) and follows it through the script the
way the teleprompter did. Wherever you went back and said words again, the first try is
cut: from where it started to where the retake starts, so anything said in between
("sorry, let me redo that") goes too.

Speech recognition times words up to a tenth of a second off, so the cut's edges are
placed by the sound itself (`PaneKit/CutEdges.swift`): the cut starts just before the
flubbed try's first sound, keeping all the quiet before it (the screen may be busy
then), and ends a little before the retake's first sound, keeping some of the quiet
before it as a lead-in. **Pause before retakes** sets how much: Short (0.1 s), Medium
(0.25 s) or Long (0.5 s); only quiet that's there is kept, never added. Where the kept
parts meet, the sound fades out and back in over 10 ms, so a join never clicks.

The timeline's **Retakes** lane shows each cut in red, and the Video bar is shaded
there. Click one to keep it (an outline), and again to cut it; **Keep All Retakes** and
**Cut All Retakes** change them all. The preview plays the kept parts one after
another, with the same fades, so it sounds like the export. **Export
Video** leaves them out with the sound in step, and the .srt and burned-in captions
leave out what was said in them. **Send to Final Cut** puts one screen clip on the
timeline per kept part, so a cut can be brought back by dragging a clip's end. Cuts
work together with the trim.

## Captions

**Make Captions** in the review window turns your narration (the microphone track) into
captions with Apple's speech recognition, entirely on your Mac (macOS 26 or later; the
speech model downloads once if needed). It takes about a second per minute of audio.
Captions are cut into short cues of up to two 42-character lines, one to six seconds
each, broken at sentence ends, commas or pauses, and "um" and "uh" are left out. Export
Video then also saves "<name> (Edited).srt" next to the video; **Burn captions into the
video** draws them as white text on a dark box near the bottom, moved clear of the camera
circle (shortcut badges then sit just above them); and Send to Final Cut adds them to the
project as editable captions. With a trim, the .srt and the Final Cut captions match the
kept part.

## Building from source

```bash
make run
```

This builds `build/Pane.app`, installs it to /Applications and launches it. You need
Xcode 26 or later (accept its license once with `sudo xcodebuild -license accept`).

`./scripts/create-signing-cert.sh` (optional, once) creates a free local signing identity
so macOS remembers Pane's permissions between rebuilds. Without it, macOS asks for Screen
Recording access again after every build.

### Releasing

```bash
scripts/release.sh 1.0.0             # build, notarize, make the .dmg and appcast.xml
scripts/release.sh 1.0.0 --publish   # also create the GitHub release
```

The script sets the version in `Resources/Info.plist`, builds a universal app signed
with the Developer ID certificate in the keychain and the hardened runtime, notarizes
and staples the app and the `.dmg`, and signs the `.dmg` for Sparkle with the EdDSA key
in the keychain (`generate_keys --account Pane`; its public half is `SUPublicEDKey`).
Each release carries its own `appcast.xml`, which the app reads from
`releases/latest/download/appcast.xml`. Without a Developer ID it makes a test build and
won't publish. Notarizing needs a stored profile, made once:

```bash
xcrun notarytool store-credentials pane-notary --apple-id <your Apple ID> --team-id <team ID>
```

### Developer tool

Test the pipeline without the app:

```bash
swift run pane-tool sample build/test/sample.mp4
swift run pane-tool scan build/test/sample.mp4
swift run pane-tool export build/test/sample.mp4 build/test/out.mp4
swift run pane-tool check                      # how closely blurs follow scrolling text
swift run pane-tool pointer-demo build/test/pointer.mp4
swift run pane-tool pointer-frames "<recording>.mp4" build/test/pointer-frames
swift run pane-tool zoom-export "<recording>.mp4" build/test/zoom.mp4 strong  # pointer effects plus zoom toward clicks
swift run pane-tool audit "<recording>.mp4"      # sensitive text the blurs miss, on frames the scan didn't check
swift run pane-tool readings "<recording>.mp4" 30 40  # what the scan read between 30 s and 40 s
swift run pane-tool readable "<recording> (Edited).mp4"  # sensitive text still readable in an export
swift run pane-tool finalcut "<recording>.mp4" build/test/fcp  # what Send to Final Cut writes
swift run pane-tool trim "<recording>.mp4" build/test/trim.mp4 3 72  # export only 3–72 s
swift run pane-tool click-demo build/test/clicks.mp4 [--narration]  # the sample with click sounds
swift run pane-tool click-check "<recording>.mp4" "<export>.mp4"  # click timing, narration level, durations
swift run pane-tool captions "<recording>.mp4" [burned.mp4]   # captions as SRT; optionally burned into a copy
swift run pane-tool follow "<recording>.mp4" script.txt  # how far behind the speaker the teleprompter stays
swift run pane-tool retakes "<recording>.mp4" script.txt [out.mp4] [--pause long]  # the retakes Review would cut, and a copy without them
swift test
```

### Project layout

| File | What it does |
|---|---|
| `Sources/Pane/ScreenRecorder.swift` | Screen capture, camera compositing, MP4 writing |
| `Sources/Pane/CameraEngine.swift` | Camera capture, square crop, background replacement |
| `Sources/Pane/CameraStyle.swift` | Camera circle settings and corner layout math |
| `Sources/Pane/RecorderModel.swift` | App state, start/stop flow, settings |
| `Sources/Pane/MainView.swift` | The main window: preview and settings |
| `Sources/Pane/MenuView.swift` | The menu bar panel (start/stop) |
| `Sources/Pane/CameraBubble.swift` | On-screen camera bubble while recording |
| `Sources/Pane/HiddenAppsView.swift` | "Never record these apps" window |
| `Sources/Pane/CountdownOverlay.swift` | 3-2-1 before recording |
| `Sources/Pane/PointerRecorder.swift` | Logs the pointer and clicks while recording |
| `Sources/Pane/ReviewView.swift` | The review window: blur layers, pointer effects, export |
| `Sources/PaneKit/MotionTracker.swift` | Follows sensitive text on every frame |
| `Sources/PaneKit/RedactionExporter.swift` | The frosted blur and the export |
| `Sources/PaneKit/PointerTrack.swift` | The pointer log, saved with the video |
| `Sources/PaneKit/PointerEffects.swift` | Draws the pointer highlight and click rings |
| `Sources/Pane/Prompter.swift` | The teleprompter strip, its keys and audio |
| `Sources/PaneKit/ScriptFollower.swift` | Follows spoken words through the script |
| `Sources/PaneKit/RetakeFinder.swift` | Finds sentences said again |
| `Sources/PaneKit/CutEdges.swift` | Places cuts in the quiet between words; fades at joins |
| `Sources/PaneKit/VideoEdit.swift` | Trim plus cuts: what's kept, and time in the export |

You can also open `Package.swift` in Xcode to browse and edit the code.

## License

MIT. See [LICENSE](LICENSE).
