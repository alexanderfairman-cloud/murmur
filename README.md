# Murmur

Hold a key, talk, let go: your words are typed wherever your cursor is. Everything runs on your Mac. No account, no subscription, and your voice never leaves the computer.

It replaces Wispr Flow. It is a native Mac app (not a website in a wrapper), so it starts fast and stays small.

## How it works

1. **Hold Fn** and talk. A dark pill with a live waveform appears at the bottom of the screen.
2. **Let go.** The speech model (NVIDIA Parakeet, running on the Mac's own chip) turns your voice into text in about a third of a second.
3. The text is cleaned up (um and uh removed), your dictionary fixes names it tends to mishear, and it is typed at your cursor in any app.

Pauses become punctuation. Murmur measures the silences in your recording. A pause of 0.8 seconds or more ends a sentence (full stop, capital letter). A pause of 1.8 seconds or more starts a new paragraph. A pause right after a word like "to" or "the" is treated as thinking, not as an ending. These lengths are first guesses, so if they feel wrong, change `sentencePause` and `paragraphPause` in `settings.json` (or set `pauseBreaks` to `false`). Dictations without a long pause are not touched.

Extra keys, same as Wispr Flow:

| Keys | What happens |
|---|---|
| Hold Fn | Talk while held, type on release |
| Hold Fn, tap Space | Hands-free: keeps listening after you let go. Press Fn once to finish |
| Esc while listening | Throw the recording away |
| Command + Control + V | Type your last dictation again |

## The window

Click the Murmur icon in the menu bar, then "Open Murmur". It opens by itself the first time.

- **History:** every dictation, one line each, newest first. Click one to open it: full text, how long it took, and which words were fixed. Copy or delete from there, or press **Fix a word**: tap the word Murmur got wrong (tap a neighbour to include it), type the right word, and Save. The wrong spelling goes under that word in Words, so the next dictation gets it right, and the saved text is corrected. Murmur cannot change text already typed in another app, so use "Copy fixed text" for that. Fixing an everyday word like "her" warns you first, because the rule would apply to every "her" you say. The search box finds text, what the model heard, or the app.
- **Words:** type a word and press Return to add it. Type to search instead. Each word lists the wrong spellings the model tends to produce, edited right there. The number is how often the word fixed a dictation. Tick several words to delete them together.
- **Settings:** the dictation key, sounds, a space after each dictation, removing "um" and "uh", the pause lengths, and opening Murmur at login.
- **First run:** a checklist (three permissions, the Globe key, the speech model with its real percentage) shows on top of History until everything is in place.

While the window is open Murmur also shows in the Dock. Close it and Murmur goes back to living only in the menu bar.

## Install

```bash
Scripts/make-signing-cert.sh
Scripts/build-app.sh
open build/Murmur.app
```

The first line creates a certificate once, in your login keychain only. With it, macOS remembers Murmur's permissions across rebuilds. Without it, every rebuild looks like a new app and you must allow the permissions again.

The first launch downloads the speech model (about 0.6 GB) and then works offline.

macOS will ask for three permissions. The menu bar icon turns into a warning sign until all three are on, and the menu has a button for each:

- **Microphone**: to hear you.
- **Accessibility**: to type the text for you.
- **Input Monitoring**: to notice when you hold the Fn key.

If a permission is switched on in System Settings but Murmur still says "Allow":

- **Accessibility and Input Monitoring** are only noticed by a freshly started app: a running copy keeps its earlier "no". Click "Restart Murmur" on the setup card.
- **Still stuck after the restart:** macOS keeps a leftover Murmur row from an older build, and switching it on does nothing. In System Settings, Privacy and Security, select Murmur in that list, click the minus button, then click Allow on the card again.

**Microphone:** if your Mac's chosen microphone is a Bluetooth headset (AirPods), Murmur uses the Mac's built-in microphone instead, because a Bluetooth microphone can deliver no sound at all and switches the earbuds to a poor-quality mode while you dictate. Set `preferBuiltInMicrophone` to `false` in `settings.json` to use the headset. If you hold Fn and the floating bar says "No sound from ...", the microphone it names is not delivering. To test which microphone Murmur uses and whether sound arrives (it records two seconds, keeps nothing, and is not part of the automatic checks):

```bash
open -n --stdout /tmp/mic.json build/Murmur.app --args --mic-test 2 && sleep 4 && cat /tmp/mic.json
```

One System Settings change is needed for Fn: **System Settings > Keyboard > "Press 🌐 key to" > Do Nothing**. Otherwise macOS opens the emoji picker every time you let go of Fn. Quit Wispr Flow first, or both apps will react to the same key.

## Your files

Everything lives in `~/Library/Application Support/Murmur/`:

- `dictionary.json`: words to spell your way. `heardAs` lists the wrong spellings the model produces.
- `history.jsonl`: every dictation, one per line.
- `settings.json`: `hotkey` (`fn`, `rightOption`, `rightCommand`, `rightControl`), `sounds`, `trailingSpace`, `removeFillers`, `pauseBreaks`, `sentencePause`, `paragraphPause`.

## Checks

`Scripts/check.sh` runs the unit tests, draws the floating bar, every window screen and the Dock icon to pictures, tests what the window's buttons do, and runs two speech tests (the Mac reads sentences aloud, the real model transcribes them, including recordings with exact pauses). Run `Scripts/install-hooks.sh` once and git runs it before every commit.

Not covered by any check: the microphone, the Fn key, typing into other apps, clicking in the real window, and a real voice. Those need a person.

## A note about this Mac's Swift tools

The Command Line Tools on this Mac contain leftover files from an older install that break every Swift build. `Scripts/toolchain-fix.sh` works around it without touching system folders, and every script loads it. Reinstalling the Command Line Tools (`sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install`) fixes the cause; the script then does nothing.
