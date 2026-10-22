# Practice

Practice helps you keep the phrases you saved. It turns your
[phrasebook](phrasebook.md) collections and your favorites into
flashcards, schedules them with a proven spaced-repetition algorithm
(FSRS, the one Anki uses) and asks you a few at a time. Everything runs on
your phone or in your browser: there is no account, nothing is sent
anywhere, and there are no streaks to keep up.

Open it from the translate screen's **More tools** menu (**Practice**,
with the number of cards due for review), with **Practice** (the school
cap) on a phrasebook collection to practise that collection alone, or from
the settings (search for "practice", "flashcards" or "Anki").

## Cards

- Every phrase of the collections you practise becomes one card per
  direction you pick:
  - **Recognize:** you see the phrase in the language you're learning and
    recall what it means;
  - **Produce:** you see your own language and say or type the phrase.
- Under **Collections**, tick the ones to practise (all of them by
  default, Favorites included; collections you create later are included
  too while all are ticked). Starter phrasebooks can be practised like
  any other collection.
- **Which side is yours.** A phrase is saved as a text and its
  translation. Practice takes your language to be the app's language when
  at least half of your phrases have it on one side, and otherwise the
  language most of your phrases share (you save phrases between your
  language and the ones you learn). The other side of each phrase is the
  one you learn, so a sign you translated from Portuguese and a sentence
  you translated into Portuguese both teach Portuguese.
- Cards read their text from the phrase every time, so editing a phrase
  or its note changes its cards. When a phrase is deleted, its cards and
  their progress go too (a favorite's when it is no longer a favorite).
  While the history can't be read (locked or still loading), favorites'
  cards are kept; cards of a starter phrasebook you uninstalled are kept
  in case you install it again.
- A card is only stored once you have reviewed it: phrases you never
  practise cost nothing.

## Sessions

1. The overview says how many cards are due for review and how many new
   cards you can learn today (**New cards per day**, 10 by default, at most
   one new card per phrase a day). **Start** begins a session.
2. A session holds the cards due when it starts: cards still being
   learned first, then the reviews (the longest overdue first), then the
   new cards, at most 50 at a time (**Keep going** starts another one
   when more are due).
3. Each card shows its front. Think of the answer, then **Show answer**
   (or Space, or Enter). **Listen** reads the phrase you're learning aloud
   with the read-aloud voice; a long press reads it slowly.
4. Rate how well you remembered: **Again** (forgot), **Hard**, **Good** or
   **Easy** (or the keys 1 to 4). Each button says when the card comes back
   ("10 min", "4 days", "3 months"), and that is exactly what it schedules.
5. Cards you are still learning come back within the session; the rest
   come back on the day shown. **Undo last rating** (or Z) takes the last
   rating back and shows the card again; **End session** stops early (your
   ratings so far are kept).
6. The summary says how many cards you reviewed and remembered, how many
   were new, and when the next cards are due. Nothing is held against you
   for missing a day: due cards simply wait.

Screen readers announce each card, its answer and what each rating
schedules; every control has a label, and everything works with a
keyboard. With **Remove animations** (Android) or reduced motion, the
answer appears without animation.

## Speaking practice

On a produce card, say the phrase instead of just thinking it:

- **Hold the microphone** and speak; let go to check. Or tap it to start,
  and tap again to stop (also with Enter or Space, and with a screen
  reader's double tap). Recording stops on its own after a two-second
  pause or 30 seconds.
- What you said is transcribed **on the phone** by Whisper (the
  [offline speech model](voice-input.md#offline-whisper)) in the card's
  language, then compared with the phrase: each word is marked right,
  nearly right (a letter or two off) or missed, and words you added are
  listed. The comparison ignores case, punctuation and accents, and reads
  number words as digits in English, Spanish, French, German, Italian,
  Portuguese and Dutch ("two" matches "2"). Chinese, Japanese and Thai are
  compared character by character.
- It **suggests** a rating (Good when every word was right, Hard when most
  were, Again otherwise); you still choose the rating.
- The recording stays in memory only while it is transcribed. It is never
  stored and never leaves the phone.

Speaking practice needs the Android app with an offline speech model
(**Settings > Read aloud & voice > Voice input > Offline speech models**;
the overview offers **Voice settings** when none is installed) and a
language Whisper knows. Elsewhere (the web app, phones where Whisper can't
run) the microphone is hidden and the overview says why.

## Typing practice

Turn on **Type answers** to get an answer field on produce cards. Type the
phrase and press Enter (or **Check**): the answer shows with the same
word-by-word comparison and a suggested rating.

## Settings

All on the practice overview:

- **Collections** and **Cards** (the directions), see above.
- **New cards per day**: 0 to 100 (0 reviews what you already learned).
- **Desired retention**: how likely you are to remember a card when it is
  due, from 70 % to 97 % (90 % by default). Higher means shorter intervals
  and more reviews; lower means fewer reviews and more forgetting.
- **Type answers**, and whether **Speaking practice** can run here.

## The scheduler

Practice implements **FSRS-5** (the Free Spaced Repetition Scheduler by
Jarrett Ye and the Open Spaced Repetition project, used by Anki since
23.10) in pure Dart (`lib/practice/data/fsrs.dart`). It follows the
reference implementation
[py-fsrs](https://github.com/open-spaced-repetition/py-fsrs) v5.1.3 (MIT
License, Copyright (c) 2022 Open Spaced Repetition) and the published
[algorithm](https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-Algorithm);
no GPL code is used. Its tests check the reference implementation's
published sequences.

- Each card has a **stability** (the days after which you would still
  remember it with 90 % probability) and a **difficulty** (1 to 10), set
  by your first rating and updated by every review with FSRS-5's 19
  default weights.
- New cards go through two **learning steps** (1 minute, then 10
  minutes): Again starts them over, Hard repeats the step (halfway to the
  next one on the first step), Good moves on and Easy finishes learning at
  once. A card you forget later goes through one **relearning step** (10
  minutes).
- After that, the interval is the time until the probability of
  remembering falls to your desired retention, in whole days, at least one
  day and at most 100 years. From three days on it gets a little random
  **fuzz** (±5 to 15 %, as in Anki), so cards learned together don't stay
  due together.
- Reviews on the same day as the last one use FSRS's short-term formula.

The weights are FSRS's defaults; Practice does not optimise them for you
(that needs a long review history, and Anki can do it from an export).

## Export to Anki

**Export to Anki** (at the end of the overview) writes a text file Anki
imports: pick one collection or **All collections**, then **Save file** (a
download in the web app) or **Share file**.

- One note per phrase: the front is the phrase in the language you learn,
  the back your language (with the pronunciation and your note on lines of
  their own, when there are any).
- Tags: `Mozhi::<collection name>` for every exported collection the
  phrase is in (spaces become `_`) and the language pair, such as `en-pt`.
- The file is UTF-8, tab-separated, with the header lines Anki reads:

  ```
  #separator:tab
  #html:false
  #tags column:3
  Onde fica a estação?	Where is the station?	Mozhi::Trip_to_Lisbon en-pt
  ```

  Fields with a tab, a line break or a double quote are quoted.
- In Anki: **File > Import**, pick the file, and choose the note type
  **Basic** (or **Basic (and reversed card)** to practise both ways) and a
  deck. The progress you made in Mozhi is not exported (Anki starts the
  cards as new).
- The file isn't encrypted, and it stays on the device unless you share
  it.

## Your data

- The progress (each reviewed card's FSRS state, review count and dates)
  and the practice settings are stored on the device like the history:
  encrypted with AES-256-GCM under their own random key, which is kept in
  secure storage (Android Keystore; in the web app the browser's storage,
  see [Privacy](privacy.md#on-your-device)). If that key is lost (for
  example after the app's storage was reset), Practice says so and offers
  **Start over**; your phrases are not affected.
- Encrypted [backups](backup.md), sync and device pairing carry it as the
  `practice` section: in a merge, each card's newer copy wins and a
  deletion on either side wins over an older copy.
- **Settings > Privacy & data > Delete all local data** deletes it, with
  its key.
