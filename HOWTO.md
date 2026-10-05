# How to use Pane

## Record

1. In Pane's window, choose **Full screen** or **Window** (top right).
2. Set up your camera and microphone. Click a corner of the preview to move your camera there.
3. Click **Start Recording** (⇧⌘R). Recording starts after a 3-2-1 countdown.
4. To pause or stop, click the timer in the menu bar, then **Pause** (⌘P) or **Stop**.

Type a **Name** above Start Recording, like "Share a Project". Each video gets its own folder in **Movies ▸ Pane**, named with the date, like "Share a Project 2026-10-05". Record it again the same day and it's "Take 2". Without a name it's "Untitled" with the time.

## Read from a script

The teleprompter shows your script at the top of the screen and moves along as you talk. It's never in the recording, and clicks pass through it. Needs macOS 26.

1. In Pane's window, under **Teleprompter**, click **Write Script…** and type or paste what you'll say.
2. Put what to do in square brackets, like **[Click Settings]**. It shows in orange and ticks off when you click.
3. Turn on **Show while recording**. Click **Rehearse** to practice without recording.

Made a mistake? Just say the sentence again: the teleprompter goes back with you. Or press **Control-Option-↑** to start a sentence over, or **Control-Option-↓** to skip to the next one.

## Write your script with an AI assistant

If you make how-to videos for an app you build, the AI assistant that works on its code (like Claude Code) already knows every page and button by name, so it can write your scripts. The guide below teaches it how Pane's teleprompter reads a script. Copy it into the assistant once: paste it into the chat, or add it to the project's instructions (for Claude Code, its CLAUDE.md). Then ask something like *"Write a Pane script showing how to invite a client."* Paste what it writes into **Write Script…**, or save it as a file and click **Open…**.

```
You write teleprompter scripts for how-to videos recorded with Pane, a Mac screen recorder. The narrator reads your script from a teleprompter at the top of their screen while they do what it says in the app. Pane listens and moves the teleprompter along as they speak, so write what they will say, word for word, in their own voice.

Format
- Plain text. The first line is the video's title as a Markdown heading, like "# Invite a Client". Pane names the recording after it. Headings ("# " or "## " at the start of a line) are never read aloud; use "## Step name" to mark sections.
- No other Markdown: no bullets, numbering, bold, links or emoji. Everything else is read.
- One sentence per line, short (under about 15 words). The teleprompter is narrow and shows three rows at a time, and each line starts a new row.
- A blank line between steps.
- Stage directions go in [square brackets]: "[Click Clients]". They show in orange, are never spoken or captioned, and tick off when the narrator clicks. Put each one exactly where the action happens, on its own line or just before the words it goes with. One action per bracket, named exactly as it appears on screen, using the app's own labels from the code: "[Click Add Client]", "[Open the Billing page]", "[Type a client name]", "[Press Command-K]".

Writing
- One task per video, 1 to 3 minutes. Pane estimates about 150 words a minute.
- Open with one or two sentences on what the viewer will be able to do and where in the app this happens. Then the steps. End with a one-line recap or the next thing to try.
- For each step: say what you're about to do, do it (the cue), then say what changed. "Next, add your first client. [Click Add Client] A form opens on the right."
- Say things the way they're spoken: "twenty percent", not "20%". Keep URLs, file paths, symbols and code out of the spoken text; put them in a cue if the narrator needs them.
- Don't repeat a sentence word for word anywhere in the script. Pane uses repeated words to find retakes: when the narrator flubs a line, they say the sentence again from its start and Pane cuts the first try. Distinct sentences keep that reliable.
- Use the app's real names for things, spelled the same way every time.
- Use demo data that looks real but isn't: names like Jordan Lee, emails at example.com. Pane blurs emails, phone numbers and keys on screen, but it can't blur what the narrator says.

Example
# Invite a Client

In this video, you'll invite a client to Brightline so they can book sessions with you.
We'll start on the Clients page.
[Click Clients]

Here's everyone you coach.
To invite someone new, click Add Client.
[Click Add Client]
A form opens on the right.

Type their name and email.
[Type Jordan Lee, jordan@example.com]
Then click Send Invite.
[Click Send Invite]
Jordan gets an email with a link to join.

That's all it takes.
Next, try setting up your first session type.

When asked for a script, reply with only the script, ready to paste into Pane.
```

## Hide private info

- With **Auto-blur** on, Pane checks each recording when you stop. It blurs emails, phone numbers, passwords, keys and card numbers, then opens the Review window.
- In Review, uncheck a blur to remove it.
- **Blur Text**: click any word to blur it everywhere it appears.
- **Draw Box** or **Draw Circle**: drag over an area to blur it.
- **My word list**: words Pane always blurs, like names or clients. Edit it under Auto-blur.
- **Never record**: apps whose windows never appear in recordings, like 1Password and Messages. Edit it under Privacy. Open those apps before you start recording: one opened mid-recording can show for a split second.

## Make it look good

In Review, open the **Pointer** tab:

- **Highlight the pointer** and **Show clicks** help viewers follow along. Pick a color and size.
- **Zoom toward clicks** moves in closer when you click (Subtle or Strong).
- **Click sounds** add a click sound to each click.
- Uncheck any stray click in the **Clicks** list to hide it.

To show the keyboard shortcuts you press, turn on **Show keyboard shortcuts** under Pointer in Pane's window *before* you record.

## Trim and timing

The timeline under the video shows your recording, each blur, your clicks and captions. Click it to jump anywhere.

- Drag either end of the **Video** bar to cut off the start or the end. **Clear Trim** undoes it.
- Drag either end of a blur to change when it shows: one you drew, or one the scan found that starts a moment late.

## Cut retakes

If you recorded with the teleprompter, Pane finds the sentences you said again. Each first try shows in red in the **Retakes** lane and is cut from your video, so only your last try stays.

- Click a red bar to keep that first try after all. Click it again to cut it.
- **Keep All Retakes** or **Cut All Retakes** changes them all at once.
- **Pause before retakes** (Short, Medium or Long) sets how much quiet stays before each retake, so it doesn't start abruptly.
- The preview leaves out what's cut, so you hear the video as it will be exported.
- Retakes you keep go on a layer of their own when you **Send to Final Cut**, so you can decide there. Delete a retake's gap in the timeline to drop it, or choose **Overwrite to Primary Storyline** to use it.

## Captions

Click **Make Captions** (needs macOS 26). Pane turns your narration into captions on your Mac. Turn on **Burn captions into the video** to draw them on the video. Either way, a captions file (.srt) is saved next to it. Names from your word list, emails and numbers you say aloud show as "•••".

## Save your video

- **Export Video** saves an "(Edited)" copy next to your recording. The original never changes.
- **Send to Final Cut** opens the video in Final Cut Pro, with your camera on its own layer and a marker at every click. The camera layer isn't blurred, and whatever was behind it wasn't scanned: if you move it in Final Cut, check what it uncovers.

## Find, rename and clean up videos

Click **Recording Management** under the preview in Pane's window, or at the bottom of the Review window (⇧⌘L), to see every video with its size.

- **Review** opens it again. Rename it from **⋯** or from the **Name** field in Review.
- **Move to Trash** removes a video with everything that goes with it. **Keep Only the Edited Copy** frees space on a finished video.
- Tick several videos, or **Select All**, then **Move Selected to Trash** to clear them at once.
- **Organize Older Recordings** puts recordings from before folders into folders.

## Edit an older video

Click **Blur an Existing Video…** in Pane's window, or drop a video on Pane's Dock icon.

## If something doesn't work

- Pane needs permission for Screen Recording, Camera and Microphone. If it asks, click **Open System Settings**, turn Pane on, then click **Quit & Reopen Pane**.
- Keyboard shortcuts need **Input Monitoring** permission, turned on the same way.
- Pane's own windows and the camera bubble never show up in your recordings.
