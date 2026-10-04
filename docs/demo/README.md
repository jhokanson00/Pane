# Recording Pane's demo video

`index.html` is a made-up CRM ("Brightline") to record on. Every name, email, phone
number, card, ID and key in it is fake, so the recording can be shared as is. It's also a
safe page for trying Auto-blur yourself.

The video has two parts: **A**, recorded with Pane, shows what Pane makes; **B**,
recorded with macOS's own recorder (⇧⌘5), shows Pane's windows, which Pane always leaves
out of its own recordings.

## Before recording

1. Open `index.html` in Safari or Chrome. Make the window full screen and zoom the page to
   about 125% (⌘+) so text reads well in the video.
2. Close or hide everything else. Pane leaves notifications out on its own.
3. In Pane's main window:
   - **Camera** on, bottom-right corner, medium size. **Microphone** on.
   - **Auto-blur** on, all kinds checked. Add **Juniper Labs** to *My word list*.
   - **Pointer effects** on, and **Show keyboard shortcuts** on (macOS asks for Input
     Monitoring once).
   - **Hide desktop icons** on. **Record**: the display, not a window.

Zoom and click sounds aren't set here: they're added at export, in Part B.

## Part A: the demo (about 75 seconds, recorded with Pane)

Speak naturally and leave a second or two between steps. Mistakes are fine: say the line
again and keep going; the extra bits get trimmed.

| # | Do | Say |
|---|---|---|
| 1 | Start on **Customers**. Move the pointer slowly across the numbers at the top. | "This is Pane, a free screen recorder for Mac that makes tutorial videos safe to share." |
| 2 | Scroll slowly down the customer list, then back up. | "Everything here is private: names, emails, phone numbers. Pane finds them and blurs them for me, even while I scroll." |
| 3 | Click **Priya Duarte**. Wait two seconds on the panel. | "Card numbers and ID numbers too." |
| 4 | Press **Esc**. Press **⌘K**, then **Return**. | "Keyboard shortcuts show up on screen, so viewers can follow along." |
| 5 | Click **Settings** in the sidebar. Move over the API keys, then click **Copy** next to the live key. | "Even API keys and passwords. Every click gets a ring and a sound, and Pane zooms in so it's easy to see." |
| 6 | Click **Customers**. Press **⌘F** and type **Juniper**. | "And anything on my own word list, like a client's name." |
| 7 | Stop from the menu bar. | "When I stop, Pane checks the recording and lets me review every blur before I export." |

## Part B: Pane's windows (recorded with ⇧⌘5)

Press **⇧⌘5**, choose **Record Selected Portion**, drag it around the window, and click
**Record**. Stop with the ⏹ button in the menu bar. No narration needed. Keep each clip
short.

1. **Main window** (10 s): click two corners of the camera preview to move the camera,
   then scroll the settings.
2. **Review window** (30–40 s), after Part A's scan opens it:
   - Turn one blur layer off and on again in the list.
   - In the timeline, drag the end of the **Video** bar in a little (trim), then drag it back.
   - Open the **Pointer** tab: change the color, set **Zoom toward clicks** to
     **Subtle**, turn on **Click sounds**, and scroll the click list.
   - Click **Make Captions** and wait for the captions lane to fill.
   - Click **Export Video**.

## Hand over

Send these (they stay on your Mac until you choose where they go):

- The recording and its **(Edited)** export from `~/Movies/Pane`, plus the **(Edited).srt**
- The ⇧⌘5 clips (saved to the Desktop)

From those, the finished video gets title cards, a before/after split of the raw
recording next to the blurred export, and two versions: a short silent loop for the
README and the full narrated video for the release page.
